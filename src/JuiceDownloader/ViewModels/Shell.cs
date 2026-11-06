using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Windows.Threading;

namespace JuiceDownloader.ViewModels;

/// <summary>What is handed to Windows itself: folders to Explorer, links to the browser.</summary>
internal static class Shell
{
    public static void OpenFolder(string? path)
    {
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo("explorer.exe", "\"" + path + "\"") { UseShellExecute = true });
        }
        catch
        {
            // explorer missing or blocked, or a folder that cannot be made; nothing sensible to do
        }
    }

    public static void RevealFile(string file)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + file + "\"") { UseShellExecute = true }); }
        catch { /* explorer missing or blocked; nothing sensible to do */ }
    }

    public static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { /* no browser; nothing sensible to do */ }
    }
}

/// <summary>Temporary media files: fetched with the app's User-Agent, for the players that cannot send one.</summary>
internal static class MediaFetch
{
    public static Task ToFileAsync(HttpClient http, string url, string file, IProgress<long>? progress, CancellationToken ct) => Task.Run(async () =>
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        // A stream that stops sending must not leave anyone waiting for ever.
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(ct);
        stall.CancelAfter(TimeSpan.FromSeconds(60));
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, stall.Token);
        response.EnsureSuccessStatusCode();
        await using var input = await response.Content.ReadAsStreamAsync(stall.Token);
        await using var output = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16, useAsync: true);
        var buffer = new byte[1 << 16];
        long done = 0;
        while (true)
        {
            stall.CancelAfter(TimeSpan.FromSeconds(60));
            var read = await input.ReadAsync(buffer, stall.Token);
            if (read == 0) break;
            await output.WriteAsync(buffer.AsMemory(0, read), stall.Token);
            done += read;
            progress?.Report(done);
        }
    }, ct);

    public static void TryDelete(string file)
    {
        try { File.Delete(file); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public static void Sweep(string folder)
    {
        try
        {
            if (!Directory.Exists(folder)) return;
            foreach (var file in Directory.EnumerateFiles(folder)) TryDelete(file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>Progress that shows only the newest report: a worker can report far faster than the window can draw.</summary>
internal sealed class Latest<T>(Dispatcher dispatcher, Action<T> apply) : IProgress<T>
{
    private readonly object _gate = new();
    private T _value = default!;
    private bool _queued;

    public void Report(T value)
    {
        lock (_gate)
        {
            _value = value;
            if (_queued) return;
            _queued = true;
        }
        dispatcher.InvokeAsync(() =>
        {
            T newest;
            lock (_gate)
            {
                newest = _value;
                _queued = false;
            }
            apply(newest);
        }, DispatcherPriority.Background);
    }
}
