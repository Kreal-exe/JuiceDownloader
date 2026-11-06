using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace JuiceDownloader.Core;

/// <summary>A clip in an mpv window of its own, with mpv's controls. It goes when it is stopped, or when this app goes.</summary>
public sealed class MpvVideo(string userAgent, string executable = "mpv")
{
    private readonly object _gate = new();
    private Process? _process;

    /// <summary>False when mpv is not installed.</summary>
    public bool Play(string source, string title)
    {
        lock (_gate)
        {
            Stop();
            try
            {
                var info = new ProcessStartInfo("/bin/sh")
                {
                    UseShellExecute = false,
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                foreach (var arg in new[] { "-c", MpvPlayer.WatchScript, executable, "--force-window=yes", "--no-terminal", $"--user-agent={userAgent}", $"--title={title}", "--", source })
                    info.ArgumentList.Add(arg);
                _process = Process.Start(info);
                if (_process is null) return false;
                _process.OutputDataReceived += (_, _) => { };
                _process.ErrorDataReceived += (_, _) => { };
                _process.BeginOutputReadLine();
                _process.BeginErrorReadLine();
                // The shell ends at once, with 127, when there is no mpv to start.
                return !(_process.WaitForExit(300) && _process.ExitCode == 127);
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
            {
                return false;
            }
        }
    }

    public void Stop()
    {
        lock (_gate)
        {
            try
            {
                if (_process is { HasExited: false } process)
                {
                    process.StandardInput.Close();
                    if (!process.WaitForExit(1000)) process.Kill();
                }
            }
            catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
            {
                // already gone
            }
            _process?.Dispose();
            _process = null;
        }
    }
}

/// <summary>
/// Playback through an mpv process, spoken to over its JSON IPC socket. Everything here runs off the window's thread;
/// the events come from the reader thread.
/// </summary>
public sealed class MpvPlayer(string userAgent, string executable = "mpv") : IDisposable
{
    internal const string WatchScript = """command -v "$0" >/dev/null || exit 127; "$0" "$@" </dev/null & m=$!; cat >/dev/null; kill $m""";

    private readonly object _gate = new();
    private readonly string _socketPath = Path.Combine(Path.GetTempPath(), $"juicedownloader-mpv-{Environment.ProcessId}.sock");
    private Process? _process;
    private Socket? _socket;
    private double _lastTime = -1;

    public event Action<double>? TimeChanged;
    public event Action<double>? DurationChanged;
    public event Action<bool>? PauseChanged;
    public event Action? Loaded;
    public event Action? Ended;
    public event Action<string>? Failed;

    /// <summary>Starts mpv if it is not running. False when it is not installed or will not start.</summary>
    public bool EnsureStarted()
    {
        lock (_gate)
        {
            if (_socket is { Connected: true } && _process is { HasExited: false }) return true;
            Stop();
            try
            {
                // Through a small shell that holds our end of a pipe: however this app goes, even killed, the pipe closes
                // and mpv goes with it. A missing mpv ends the shell at once, which is how it is noticed below.
                var info = new ProcessStartInfo("/bin/sh")
                {
                    UseShellExecute = false,
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                foreach (var arg in new[] { "-c", WatchScript, executable, "--no-video", "--idle=yes", "--no-terminal", $"--input-ipc-server={_socketPath}", $"--user-agent={userAgent}" })
                    info.ArgumentList.Add(arg);
                _process = Process.Start(info);
                if (_process is null) return false;
                _process.OutputDataReceived += (_, _) => { };
                _process.ErrorDataReceived += (_, _) => { };
                _process.BeginOutputReadLine();
                _process.BeginErrorReadLine();
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
            {
                return false;
            }

            // mpv makes the socket a moment after it starts.
            var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    socket.Connect(new UnixDomainSocketEndPoint(_socketPath));
                    break;
                }
                catch (SocketException) when (attempt < 50 && !_process.HasExited)
                {
                    Thread.Sleep(100);
                }
                catch (SocketException)
                {
                    socket.Dispose();
                    Stop();
                    return false;
                }
            }
            _socket = socket;
            new Thread(() => ReadLoop(socket)) { IsBackground = true, Name = "mpv ipc" }.Start();
            Send("observe_property", 1, "time-pos");
            Send("observe_property", 2, "duration");
            Send("observe_property", 3, "pause");
            return true;
        }
    }

    public void Load(string source)
    {
        _lastTime = -1;
        Send("loadfile", source, "replace");
        SetPause(false);
    }

    public void SetPause(bool paused) => Send("set_property", "pause", paused);
    public void Seek(double seconds) => Send("seek", seconds, "absolute");
    public void SetVolume(double volume) => Send("set_property", "volume", Math.Clamp(volume, 0, 1) * 100);
    public void Unload() => Send("stop");

    private void Send(params object[] command)
    {
        var line = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object[]> { ["command"] = command });
        lock (_gate)
        {
            try
            {
                if (_socket is null) return;
                _socket.Send(line);
                _socket.Send("\n"u8);
            }
            catch (Exception e) when (e is SocketException or ObjectDisposedException)
            {
                // the reader notices a dead player too
            }
        }
    }

    private void ReadLoop(Socket socket)
    {
        var pending = new List<byte>();
        var buffer = new byte[8192];
        try
        {
            while (true)
            {
                var read = socket.Receive(buffer);
                if (read == 0) break;
                for (var i = 0; i < read; i++)
                {
                    if (buffer[i] != (byte)'\n') { pending.Add(buffer[i]); continue; }
                    Handle(Encoding.UTF8.GetString(pending.ToArray()));
                    pending.Clear();
                }
            }
        }
        catch (Exception e) when (e is SocketException or ObjectDisposedException)
        {
            // closed: Stop was called, or mpv went away
        }
        if (!ReferenceEquals(socket, _socket)) return;
        lock (_gate) Stop();
        Failed?.Invoke("mpv stopped");
    }

    private void Handle(string line)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(line); }
        catch (JsonException) { return; }
        using (doc)
        {
            var root = doc.RootElement;
            if (!root.TryGetProperty("event", out var name)) return;
            switch (name.GetString())
            {
                case "property-change":
                    Property(root);
                    break;
                case "file-loaded":
                    Loaded?.Invoke();
                    break;
                case "end-file":
                    var reason = root.TryGetProperty("reason", out var r) ? r.GetString() : null;
                    if (reason == "eof") Ended?.Invoke();
                    else if (reason == "error") Failed?.Invoke(root.TryGetProperty("file_error", out var f) ? f.GetString() ?? "error" : "error");
                    break;
            }
        }
    }

    private void Property(JsonElement root)
    {
        if (!root.TryGetProperty("name", out var property) || !root.TryGetProperty("data", out var data)) return;
        switch (property.GetString())
        {
            case "time-pos" when data.ValueKind == JsonValueKind.Number:
                var time = data.GetDouble();
                // Often enough for a slider and a clock; mpv reports every frame of audio it decodes.
                if (Math.Abs(time - _lastTime) < 0.25) return;
                _lastTime = time;
                TimeChanged?.Invoke(time);
                break;
            case "duration" when data.ValueKind == JsonValueKind.Number:
                DurationChanged?.Invoke(data.GetDouble());
                break;
            case "pause" when data.ValueKind is JsonValueKind.True or JsonValueKind.False:
                PauseChanged?.Invoke(data.GetBoolean());
                break;
        }
    }

    private void Stop()
    {
        var socket = _socket;
        _socket = null;
        socket?.Dispose();
        try
        {
            if (_process is { HasExited: false } process)
            {
                process.StandardInput.Close();
                if (!process.WaitForExit(1000)) process.Kill();
            }
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        {
            // already gone
        }
        _process?.Dispose();
        _process = null;
        try { File.Delete(_socketPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        lock (_gate) Stop();
    }
}
