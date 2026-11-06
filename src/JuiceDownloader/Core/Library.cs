namespace JuiceDownloader.Core;

public sealed record LyricsRunReport(int Written, int AlreadyThere, int NotFound, int Failed, IReadOnlyList<string> Missing);

public sealed record LyricsRunProgress(int Done, int Total, string Name);

/// <summary>How a file can be looked at before it is downloaded.</summary>
public enum PreviewKind { None, Image, Video, Text }

public enum LyricsGapKind { NoWords, OtherRecording }

/// <summary>A file with no words, or a session file with only the finished song's.</summary>
public sealed record LyricsGap(string File, string Relative, LyricsGapKind Kind, string? HasWordsOf);

public sealed record LyricsGapScan(int Files, int Fine, IReadOnlyList<LyricsGap> Gaps);

public sealed record LyricsGapResult(LyricsGap Gap, WebLyricsResult Found, LyricsResult Written);

/// <summary>
/// The app's work, for the view models of the Windows and Linux apps: what the catalog holds, what the lyrics add-on
/// knows, and the runs that turn a selection into files. Nothing here touches a window.
/// </summary>
public sealed class Library(ApiClient api, DownloadEngine engine, CatalogCache cache)
{
    public static readonly string[] AudioExtensions = [".mp3", ".m4a", ".flac", ".wav", ".aif", ".aiff", ".ogg", ".caf"];
    public static readonly TimeSpan CatalogAge = TimeSpan.FromHours(6);

    public Catalog? Catalog { get; private set; }
    private LyricsIndex? _lyrics;
    public LyricsIndex? Lyrics
    {
        get => _lyrics;
        private set { _lyrics = value; LyricsIndex.Current = value; }
    }
    public DateTime? UpdatedAt => cache.TreeTime;
    /// <summary>The last download went ahead without the lyrics the add-on asked for, because they could not be fetched.</summary>
    public bool LyricsSkipped { get; private set; }

    /// <summary>Shows the last catalog at once. True when there was one.</summary>
    public bool LoadCached()
    {
        if (cache.LoadTree() is { Count: > 0 } items) Catalog = Catalog.Build(items);
        return Catalog is not null;
    }

    public bool CatalogIsStale => cache.TreeTime is not { } t || DateTime.UtcNow - t > CatalogAge;

    /// <summary>A new Catalog starts with nothing selected; the caller carries the selection over with <see cref="CarrySelection"/>.</summary>
    public async Task RefreshAsync(CancellationToken ct)
    {
        var items = await api.FetchTreeAsync(ct);
        cache.SaveTree(items);
        var fresh = Catalog.Build(items);
        CarrySelection(Catalog, fresh);
        Catalog = fresh;
    }

    public static void CarrySelection(Catalog? from, Catalog to)
    {
        if (from is null || from.SelectedFiles == 0) return;
        var selected = from.SelectedFilesList().Select(f => f.Path).ToHashSet(StringComparer.Ordinal);
        foreach (var file in to.Root.Files())
            if (selected.Contains(file.Path)) Catalog.Select(file, true);
    }

    /// <summary>The songs and their words: from the cache when it is recent, else about thirty polite requests.</summary>
    /// <summary>The songs known now, however old, without going to the API. Null when there are none yet.</summary>
    public LyricsIndex? KnownLyrics()
    {
        if (Lyrics is not null) return Lyrics;
        return cache.LoadSongs() is { Count: > 0 } cached ? Lyrics = new LyricsIndex(cached) : null;
    }

    /// <summary>One small request: does the API now hold a different number of songs than the kept copy? False when it cannot tell.</summary>
    public async Task<bool> LyricsChangedOnServerAsync(CancellationToken ct)
    {
        if (KnownLyrics() is not { } known) return false;
        try
        {
            var count = await api.FetchSongCountAsync(ct);
            return count > 0 && count != known.SongCount;
        }
        catch (Exception e) when (e is HttpRequestException or IOException or TaskCanceledException or System.Text.Json.JsonException)
        {
            return false;
        }
    }

    public async Task<LyricsIndex> EnsureLyricsAsync(IProgress<(int Done, int Total)>? progress, bool force, CancellationToken ct)
    {
        if (!force && KnownLyrics() is { } known) return known;
        try
        {
            var songs = await api.FetchSongsAsync(progress, ct);
            cache.SaveSongs(songs);
            return Lyrics = new LyricsIndex(songs);
        }
        catch (Exception e) when (!ct.IsCancellationRequested && e is HttpRequestException or IOException or TaskCanceledException or System.Text.Json.JsonException && cache.LoadSongs() is { Count: > 0 })
        {
            // Offline with an old copy: old words are better than a failed run.
            return Lyrics = new LyricsIndex(cache.LoadSongs()!);
        }
    }

    /// <summary>Downloads what is selected. With lyrics options, each audio file gets its words as soon as it is on disk.</summary>
    public Task<DownloadReport> DownloadSelectedAsync(string destination, int parallel, LyricsOptions? lyrics, IProgress<DownloadProgress>? progress, CancellationToken ct) =>
        DownloadAsync(Catalog?.SelectedFilesList().Select(f => new DownloadFile(f.Path, f.Size)).ToList() ?? [], destination, parallel, lyrics, progress, ct);

    /// <summary>The songs a set of rules keeps. Needs the songs, so it fetches them when they are not known yet.</summary>
    public async Task<RuleResult> ApplyRulesAsync(RuleOptions options, CancellationToken ct)
    {
        await EnsureLyricsAsync(null, false, ct);
        var songs = cache.LoadSongs() ?? [];
        // A cache from before the rules has no leak types: it says nothing about which take is finished.
        if (songs.Count > 0 && songs.All(s => string.IsNullOrEmpty(s.LeakType)))
        {
            await EnsureLyricsAsync(null, true, ct);
            songs = cache.LoadSongs() ?? [];
        }
        if (Catalog is null) return new RuleResult([], 0, 0, 0, 0);
        var result = SongRules.Apply(Catalog, songs, options);
        if (Lyrics is null) return result;
        var known = cache.LoadSameAudio();
        var cleaned = await AudioCopies.RemoveAsync(result, Lyrics, api, known, ct);
        cache.SaveSameAudio(known);
        return cleaned;
    }

    public async Task<DownloadReport> DownloadAsync(IReadOnlyList<DownloadFile> files, string destination, int parallel, LyricsOptions? lyrics, IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        LyricsIndex? index = null;
        LyricsSkipped = false;
        _same = _other = _none = 0;
        if (lyrics is not null)
        {
            // The music matters more than its words: with no lyrics to be had, say so afterwards and download anyway.
            try { index = await EnsureLyricsAsync(null, false, ct); }
            catch (Exception e) when (!ct.IsCancellationRequested && e is HttpRequestException or IOException or TaskCanceledException or InvalidDataException or System.Text.Json.JsonException)
            {
                LyricsSkipped = true;
            }
        }
        var options = new DownloadOptions
        {
            Destination = destination,
            Parallel = parallel,
            AfterFile = index is null ? null : (api, local, _) => { ApplyLyrics(index, api, local, lyrics!); return Task.CompletedTask; },
        };
        return await engine.RunAsync(files, options, progress, ct);
    }

    /// <summary>Retries only what failed, which stays selected until it has come through.</summary>
    public void KeepOnlySelected(IEnumerable<string> paths)
    {
        if (Catalog is null) return;
        var keep = paths.ToHashSet(StringComparer.Ordinal);
        foreach (var file in Catalog.SelectedFilesList().ToList())
            if (!keep.Contains(file.Path)) Catalog.Select(file, false);
    }

    /// <summary>How the last download's lyrics went: the recording's own words, the nearest the API has, and none.</summary>
    public (int Same, int Other, int None) LastLyrics => (_same, _other, _none);
    private int _same, _other, _none;

    private LyricsResult ApplyLyrics(LyricsIndex index, string apiPath, string local, LyricsOptions options)
    {
        if (!WantsLyrics(apiPath) || apiPath.Contains("nstrumental", StringComparison.Ordinal)) return LyricsResult.None;
        var match = index.Find(apiPath);
        if (match is null) Interlocked.Increment(ref _none);
        else if (match.Fit == LyricsFit.SameRecording) Interlocked.Increment(ref _same);
        else Interlocked.Increment(ref _other);
        return match is null ? LyricsResult.None : LyricsWriter.Apply(local, match.Song, options);
    }

    /// <summary>Every file of a catalog folder, laid out under one folder named after it.</summary>
    public static List<DownloadFile> AlbumFiles(CatalogNode album) =>
        album.Files().Select(f => new DownloadFile(f.Path, f.Size) { Target = album.DisplayName + "/" + f.Path[(album.Path.Length + 1)..] }).ToList();

    /// <summary>A place to play a file from: the downloaded copy if there is one of the right size, else null (stream it).</summary>
    public static string? LocalCopy(string destination, CatalogNode file) =>
        LocalPath.Resolve(destination, file.Path) is { } path && DownloadEngine.IsComplete(path, file.Size) ? path : DiskState.Current?.LocalPathOf(file.Path);

    /// <summary>What goes in the player bar. A video opens in the preview, with its picture.</summary>
    public static bool IsPlayable(string name) => IsAudio(name);

    public static PreviewKind PreviewOf(string name) => Path.GetExtension(name).ToLowerInvariant() switch
    {
        ".jpg" or ".jpeg" or ".png" or ".webp" or ".gif" or ".tif" or ".tiff" or ".bmp" => PreviewKind.Image,
        ".mp4" or ".mov" or ".m4v" or ".webm" or ".mkv" => PreviewKind.Video,
        ".txt" or ".ini" or ".lrc" => PreviewKind.Text,
        _ => PreviewKind.None,
    };

    /// <summary>What lyrics can go with: audio, and a studio session's archive, which gets them beside it.</summary>
    public static bool WantsLyrics(string path) =>
        IsAudio(path) || (path.Replace('\\', '/').StartsWith("Studio Sessions/", StringComparison.Ordinal) && path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase));

    public static bool IsAudio(string name) => AudioExtensions.Contains(Path.GetExtension(name).ToLowerInvariant());

    /// <summary>Everything in a folder whose words are missing or are not of its recording, with the API consulted first.</summary>
    public async Task<LyricsGapScan> ScanForGapsAsync(string folder, LyricsOptions options, IProgress<LyricsRunProgress>? progress, CancellationToken ct)
    {
        var index = await EnsureLyricsAsync(null, false, ct);
        return await Task.Run(() =>
        {
            var files = Directory.EnumerateFiles(folder, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true })
                .Where(f => WantsLyrics(Path.GetRelativePath(folder, f))).OrderBy(f => f, StringComparer.Ordinal).ToList();
            var gaps = new List<LyricsGap>();
            int done = 0, ok = 0;
            foreach (var file in files)
            {
                ct.ThrowIfCancellationRequested();
                var relative = Path.GetRelativePath(folder, file).Replace('\\', '/');
                progress?.Report(new LyricsRunProgress(++done, files.Count, Path.GetFileName(file)));
                if (NoWordsExpected(relative)) { ok++; continue; }
                var match = index.Find(relative);
                if (match is not null) LyricsWriter.Apply(file, match.Song, options);
                if (match is { Fit: LyricsFit.SameRecording }) { ok++; continue; }
                if (match is null && LyricsWriter.Has(file)) { ok++; continue; }
                gaps.Add(new LyricsGap(file, relative, match is null ? LyricsGapKind.NoWords : LyricsGapKind.OtherRecording, match?.Song.Name));
            }
            return new LyricsGapScan(files.Count, ok, gaps);
        }, ct);
    }

    /// <summary>Instrumentals are not gaps, and neither is a stem of one channel.</summary>
    private static bool NoWordsExpected(string relative) =>
        relative.StartsWith("Instrumentals/", StringComparison.Ordinal) || relative.Contains("/Instrumental/", StringComparison.Ordinal)
        || relative.Contains("instrumental", StringComparison.OrdinalIgnoreCase);

    /// <summary>Asks the sites about each gap. A session file that has the song's words only gives them up for a session's.</summary>
    public async Task<List<LyricsGapResult>> SearchWebAsync(IReadOnlyList<LyricsGap> gaps, WebLyrics web, LyricsOptions options, IProgress<LyricsGapResult>? progress, CancellationToken ct)
    {
        var results = new List<LyricsGapResult>();
        using var slots = new SemaphoreSlim(3);
        await Task.WhenAll(gaps.Select(async gap =>
        {
            await slots.WaitAsync(ct);
            try
            {
                var found = await web.FindAsync(gap.Relative, ct);
                var result = new LyricsGapResult(gap, found, LyricsResult.None);
                var word = found.Match;
                if (word is not null && (gap.Kind == LyricsGapKind.NoWords || word.Fit == LyricsFit.SameRecording))
                    result = result with { Written = LyricsWriter.Apply(gap.File, word.Lyrics, word.Synced, options, replace: gap.Kind == LyricsGapKind.OtherRecording) };
                lock (results) results.Add(result);
                progress?.Report(result);
            }
            finally
            {
                slots.Release();
            }
        }));
        return results;
    }

    /// <summary>The add-on on its own: words for the audio files of any folder, found by their path below it.</summary>
    public async Task<LyricsRunReport> AddLyricsToFolderAsync(string folder, LyricsOptions options, IProgress<LyricsRunProgress>? progress, CancellationToken ct)
    {
        var index = await EnsureLyricsAsync(null, false, ct);
        return await Task.Run(() =>
        {
            var files = Directory.EnumerateFiles(folder, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true })
                .Where(f => WantsLyrics(Path.GetRelativePath(folder, f))).OrderBy(f => f, StringComparer.Ordinal).ToList();
            int written = 0, there = 0, failed = 0, done = 0;
            var missing = new List<string>();
            foreach (var file in files)
            {
                ct.ThrowIfCancellationRequested();
                var relative = Path.GetRelativePath(folder, file).Replace('\\', '/');
                progress?.Report(new LyricsRunProgress(++done, files.Count, Path.GetFileName(file)));
                if (index.FindOnDisk(relative) is not { } match) { missing.Add(relative); continue; }
                switch (LyricsWriter.Apply(file, match.Song, options))
                {
                    case LyricsResult.Written: written++; break;
                    case LyricsResult.AlreadyThere: there++; break;
                    case LyricsResult.Failed: failed++; break;
                    default: missing.Add(relative); break;
                }
            }
            return new LyricsRunReport(written, there, missing.Count, failed, missing);
        }, ct);
    }
}
