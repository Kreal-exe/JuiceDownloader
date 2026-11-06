using System.Net;
using System.Net.Http.Headers;

namespace JuiceDownloader.Core;

public enum DownloadOutcome { Downloaded, AlreadyThere, Failed }

public sealed record DownloadFile(string ApiPath, long Size)
{
    /// <summary>Where it goes under the download folder, when not at the catalog's own path.</summary>
    public string? Target { get; init; }
}

public sealed record DownloadFailure(string ApiPath, string Reason);

public sealed class DownloadOptions
{
    public const int MaxParallel = 32;

    public required string Destination { get; init; }
    public int Parallel { get; init; } = 8;
    public int MaxAttempts { get; init; } = 5;
    public TimeSpan RetryDelay { get; init; } = TimeSpan.FromSeconds(2);
    /// <summary>Runs on each file that is on disk when its transfer is over, whether it was just fetched or already there.</summary>
    public Func<string, string, CancellationToken, Task>? AfterFile { get; init; }
}

public sealed record DownloadProgress
{
    public int TotalFiles { get; init; }
    public long TotalBytes { get; init; }
    public int Downloaded { get; init; }
    public int AlreadyThere { get; init; }
    public int Failed { get; init; }
    public long DoneBytes { get; init; }
    public double BytesPerSecond { get; init; }
    public IReadOnlyList<string> Active { get; init; } = [];
    public int Finished => Downloaded + AlreadyThere + Failed;
    public double Fraction => TotalBytes > 0 ? Math.Clamp((double)DoneBytes / TotalBytes, 0, 1) : (TotalFiles > 0 ? (double)Finished / TotalFiles : 1);
}

public sealed record DownloadReport(int Downloaded, int AlreadyThere, IReadOnlyList<DownloadFailure> Failures, bool Stopped, long Bytes);

/// <summary>
/// Fetches files side by side. A file is written to "name.part" and only takes its real name when every byte is there,
/// so whatever has the real name is complete: a stopped or crashed run resumes where it was, by HTTP range.
/// </summary>
public sealed class DownloadEngine(HttpClient http)
{
    private sealed class Permanent(string message) : Exception(message);

    /// <summary>
    /// Whether a file on disk needs no fetching: it has the catalog's size, or differs from it because of the words the
    /// lyrics add-on wrote into its tag. Without the second case every tagged MP3 would be fetched again on each run.
    /// </summary>
    public static bool IsComplete(string file, long size)
    {
        var info = new FileInfo(file);
        if (!info.Exists) return false;
        if (info.Length == size) return true;
        if (!string.Equals(info.Extension, ".mp3", StringComparison.OrdinalIgnoreCase)) return false;
        try
        {
            return Id3Lyrics.Has(file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            return false;
        }
    }

    public async Task<DownloadReport> RunAsync(IReadOnlyList<DownloadFile> files, DownloadOptions options, IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        var state = new RunState(files);
        using var ticker = new CancellationTokenSource();
        var ticks = progress is null ? Task.CompletedTask : TickAsync(state, progress, ticker.Token);

        var queue = new Queue<DownloadFile>(files);
        async Task Worker()
        {
            while (!ct.IsCancellationRequested)
            {
                DownloadFile file;
                lock (queue)
                {
                    if (queue.Count == 0) return;
                    file = queue.Dequeue();
                }
                await OneAsync(file, options, state, ct);
            }
        }

        await Task.WhenAll(Enumerable.Range(0, Math.Clamp(options.Parallel, 1, DownloadOptions.MaxParallel)).Select(_ => Task.Run(Worker, CancellationToken.None)));
        ticker.Cancel();
        await ticks;
        progress?.Report(state.Snapshot(0));
        return state.Report(ct.IsCancellationRequested);
    }

    private static async Task TickAsync(RunState state, IProgress<DownloadProgress> progress, CancellationToken ct)
    {
        var last = (Bytes: state.TransferredBytes, Time: Environment.TickCount64);
        var speed = 0d;
        try
        {
            while (true)
            {
                await Task.Delay(250, ct);
                var now = Environment.TickCount64;
                var bytes = state.TransferredBytes;
                var seconds = Math.Max(0.001, (now - last.Time) / 1000.0);
                var current = (bytes - last.Bytes) / seconds;
                speed = speed <= 0 ? current : speed * 0.8 + current * 0.2;
                last = (bytes, now);
                progress.Report(state.Snapshot(speed));
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    private async Task OneAsync(DownloadFile file, DownloadOptions options, RunState state, CancellationToken ct)
    {
        state.Begin(file.ApiPath);
        var counted = 0L;
        try
        {
            var target = LocalPath.Resolve(options.Destination, file.Target ?? file.ApiPath) ?? throw new Permanent("unsafe path");
            var outcome = DownloadOutcome.AlreadyThere;
            if (!IsComplete(target, file.Size))
            {
                outcome = DownloadOutcome.Downloaded;
                await TransferAsync(file, target, options, delta => { counted += delta; state.Add(delta); }, ct);
            }
            state.Add(file.Size - counted);
            counted = file.Size;
            if (options.AfterFile is not null) await options.AfterFile(file.ApiPath, target, ct);
            state.Finish(file, outcome);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            state.Add(-counted);
            state.Abandon(file.ApiPath);
        }
        catch (Exception e)
        {
            // a failed file stays in the sum, so the bar still reaches the end
            state.Add(file.Size - counted);
            state.Fail(file, e is TaskCanceledException ? "timed out" : e.Message);
        }
    }

    private async Task TransferAsync(DownloadFile file, string target, DownloadOptions options, Action<long> onBytes, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        var part = target + ".part";
        var reported = 0L;

        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await AttemptAsync(file, part, have => { onBytes(have - reported); reported = have; }, ct);
                File.Move(part, target, overwrite: true);
                return;
            }
            catch (Exception e) when (e is not Permanent && !ct.IsCancellationRequested && attempt < options.MaxAttempts
                                      && e is HttpRequestException or IOException or TaskCanceledException or RetryAfter)
            {
                var wait = e is RetryAfter { Delay: { } asked } ? asked : options.RetryDelay * (1 << (attempt - 1));
                await Task.Delay(wait, ct);
            }
        }
    }

    private sealed class RetryAfter(TimeSpan? delay, string message) : Exception(message)
    {
        public TimeSpan? Delay { get; } = delay;
    }

    private async Task AttemptAsync(DownloadFile file, string part, Action<long> onHave, CancellationToken ct)
    {
        var have = File.Exists(part) ? new FileInfo(part).Length : 0;
        if (have > file.Size && file.Size > 0) { File.Delete(part); have = 0; }

        using var request = new HttpRequestMessage(HttpMethod.Get, ApiClient.DownloadUrl(file.ApiPath));
        if (have > 0) request.Headers.Range = new RangeHeaderValue(have, null);

        // A stream that stops sending must not hang the worker for ever: no bytes for a minute counts as a dropped connection.
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(ct);
        stall.CancelAfter(TimeSpan.FromSeconds(60));
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, stall.Token);

        if (response.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable)
        {
            File.Delete(part);
            throw new RetryAfter(TimeSpan.Zero, "range");
        }
        if ((int)response.StatusCode == 429 || (int)response.StatusCode >= 500)
            throw new RetryAfter(response.Headers.RetryAfter?.Delta, $"HTTP {(int)response.StatusCode}");
        if (!response.IsSuccessStatusCode)
            throw new Permanent($"HTTP {(int)response.StatusCode}");

        // Bytes from another offset would end up in the wrong place: start the file over rather than keep them.
        if (response.StatusCode == HttpStatusCode.PartialContent && response.Content.Headers.ContentRange?.From != have)
        {
            File.Delete(part);
            throw new RetryAfter(TimeSpan.Zero, "wrong range");
        }

        var resumed = response.StatusCode == HttpStatusCode.PartialContent;
        if (!resumed) have = 0;
        var expected = response.Content.Headers.ContentRange?.Length ?? response.Content.Headers.ContentLength + have ?? file.Size;

        onHave(have);
        await using (var output = new FileStream(part, resumed ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
        await using (var input = await response.Content.ReadAsStreamAsync(stall.Token))
        {
            var buffer = new byte[1 << 16];
            while (true)
            {
                stall.CancelAfter(TimeSpan.FromSeconds(60));
                var read = await input.ReadAsync(buffer, stall.Token);
                if (read == 0) break;
                await output.WriteAsync(buffer.AsMemory(0, read), stall.Token);
                have += read;
                onHave(have);
            }
        }

        if (have != expected) throw new IOException($"connection closed at {have} of {expected} bytes");
    }

    private sealed class RunState(IReadOnlyList<DownloadFile> files)
    {
        private readonly object _gate = new();
        private readonly List<string> _active = [];
        private readonly List<DownloadFailure> _failures = [];
        private readonly long _total = files.Sum(f => f.Size);
        private long _done, _transferred, _downloadedBytes;
        private int _downloaded, _there;

        public long TransferredBytes { get { lock (_gate) return _transferred; } }

        public void Begin(string path) { lock (_gate) _active.Add(path); }
        public void Abandon(string path) { lock (_gate) _active.Remove(path); }

        public void Add(long delta)
        {
            lock (_gate)
            {
                _done += delta;
                if (delta > 0) _transferred += delta;
            }
        }

        public void Finish(DownloadFile file, DownloadOutcome outcome)
        {
            lock (_gate)
            {
                _active.Remove(file.ApiPath);
                if (outcome == DownloadOutcome.Downloaded) { _downloaded++; _downloadedBytes += file.Size; }
                else _there++;
            }
        }

        public void Fail(DownloadFile file, string reason)
        {
            lock (_gate)
            {
                _active.Remove(file.ApiPath);
                _failures.Add(new DownloadFailure(file.ApiPath, reason));
            }
        }

        public DownloadProgress Snapshot(double speed)
        {
            lock (_gate)
            {
                return new DownloadProgress
                {
                    TotalFiles = files.Count,
                    TotalBytes = _total,
                    Downloaded = _downloaded,
                    AlreadyThere = _there,
                    Failed = _failures.Count,
                    DoneBytes = _done,
                    BytesPerSecond = speed,
                    Active = _active.ToArray(),
                };
            }
        }

        public DownloadReport Report(bool stopped)
        {
            lock (_gate) return new DownloadReport(_downloaded, _there, _failures.ToArray(), stopped, _downloadedBytes);
        }
    }
}
