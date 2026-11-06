using System.IO;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

public sealed record FailureRow(string Name, string Reason);

/// <summary>From the Download button to the end of the run: the questions asked first, then what the overlay shows.</summary>
public sealed partial class DownloadViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly Library _library;
    private readonly SettingsViewModel _settings;
    private readonly LyricsViewModel _lyrics;
    private readonly IDialogService _dialogs;
    private readonly MainViewModel _owner;

    private CancellationTokenSource? _cts;
    private IReadOnlyList<string> _failedPaths = [];
    private IReadOnlyList<DownloadFile> _files = [];
    private bool _fromSelection;
    private string? _runFolder;
    private string? _albumParent;

    public DownloadViewModel(Library library, SettingsViewModel settings, LyricsViewModel lyrics, IDialogService dialogs, MainViewModel owner)
    {
        _library = library;
        _settings = settings;
        _lyrics = lyrics;
        _dialogs = dialogs;
        _owner = owner;
    }

    /// <summary>The run ended with at least one new file and nothing failed.</summary>
    public event Action? Celebrate;

    [ObservableProperty] private bool _isOverlayVisible;
    [ObservableProperty] private bool _isRunning;
    [ObservableProperty] private bool _isDone;
    [ObservableProperty] private bool _isStopping;
    [ObservableProperty] private bool _isGettingLyrics;
    [ObservableProperty] private bool _wasStopped;
    [ObservableProperty] private bool _endedClean;

    [ObservableProperty] private double _ringAngle;
    [ObservableProperty] private string _percentText = "0%";
    [ObservableProperty] private string _progressText = string.Empty;
    [ObservableProperty] private string _filesText = string.Empty;
    [ObservableProperty] private string _speedText = string.Empty;
    [ObservableProperty] private string _remainingText = string.Empty;
    [ObservableProperty] private IReadOnlyList<string> _activeFiles = [];
    [ObservableProperty] private string _summaryText = string.Empty;
    [ObservableProperty] private string _lyricsSummaryText = string.Empty;
    [ObservableProperty] private IReadOnlyList<FailureRow> _failures = [];

    public string TitleText => IsDone ? Loc[WasStopped ? "download.stoppedTitle" : "download.doneTitle"]
        : IsGettingLyrics ? Loc["download.gettingLyrics"]
        : Loc["download.title"];

    public string StopText => Loc[IsStopping ? "download.stopping" : "download.stop"];
    public bool CanStop => IsRunning && !IsStopping;
    public bool HasFailures => Failures.Count > 0;

    partial void OnIsDoneChanged(bool value) => OnPropertyChanged(nameof(TitleText));
    partial void OnIsGettingLyricsChanged(bool value) => OnPropertyChanged(nameof(TitleText));
    partial void OnWasStoppedChanged(bool value) => OnPropertyChanged(nameof(TitleText));
    partial void OnIsRunningChanged(bool value) => OnPropertyChanged(nameof(CanStop));
    partial void OnFailuresChanged(IReadOnlyList<FailureRow> value) => OnPropertyChanged(nameof(HasFailures));
    partial void OnIsStoppingChanged(bool value)
    {
        OnPropertyChanged(nameof(CanStop));
        OnPropertyChanged(nameof(StopText));
    }

    [RelayCommand]
    private async Task StartAsync()
    {
        if (IsRunning) return;
        await _owner.SelectionSettled();

        var catalog = _library.Catalog;
        if (catalog is null || catalog.SelectedFiles == 0) return;

        var picked = await Task.Run(() => catalog.SelectedFilesList().Select(f => new DownloadFile(f.Path, f.Size)).ToList());
        await AskAndRunAsync(picked, fromSelection: true);
    }

    /// <summary>A list of its own, as the rules page makes: the same questions and overlay, and the selection left alone.</summary>
    public async Task StartFilesAsync(IReadOnlyList<DownloadFile> picked)
    {
        if (!IsRunning && picked.Count > 0) await AskAndRunAsync(picked, fromSelection: false);
    }

    /// <summary>A whole folder of the catalog into a folder the user picks, under its own name. A copy in the download folder is no reason to skip a track.</summary>
    public async Task StartAlbumAsync(CatalogNode album)
    {
        if (IsRunning || _dialogs.PickFolder(_albumParent ?? Path.GetDirectoryName(_settings.Destination)) is not { Length: > 0 } folder) return;
        _albumParent = folder;
        await AskAndRunAsync(Library.AlbumFiles(album), fromSelection: false, folder);
    }

    private async Task AskAndRunAsync(IReadOnlyList<DownloadFile> wanted, bool fromSelection, string? folder = null)
    {
        var destination = folder ?? _settings.Destination;
        // Looked at afresh: only what is not in the folder yet is offered.
        if (folder is not null)
        {
            wanted = await Task.Run(() => wanted.Where(f => LocalPath.Resolve(folder, f.Target ?? f.ApiPath) is not { } path || !DownloadEngine.IsComplete(path, f.Size)).ToList());
            if (wanted.Count == 0)
            {
                _owner.Toast("\uE73E", Loc["download.allThere"]);
                return;
            }
        }
        else if (_library.Catalog is { } catalog)
        {
            var state = await Task.Run(() => DiskState.Scan(catalog, destination));
            DiskState.Current = state;
            wanted = wanted.Where(f => !state.Has(f.ApiPath)).ToList();
            if (wanted.Count == 0)
            {
                _owner.Toast("\uE73E", Loc["download.allThere"]);
                return;
            }
        }
        var picked = wanted;
        var bytes = picked.Sum(f => f.Size);
        var files = picked.Count;
        var (needed, free) = await Task.Run(() => Measure(picked, destination));

        bool go;
        if (free is { } available && available < needed)
        {
            go = await _dialogs.ConfirmAsync(Loc["download.noSpaceTitle"],
                Loc.Format("download.noSpaceBody", ByteFormatter.Format(needed), ByteFormatter.Format(available)),
                Loc["download.anyway"], danger: true);
        }
        else if (_settings.ConfirmDownloads && picked.Count > 1) // one file off its row needs no second click
        {
            var body = Loc.Format("download.confirmBody", ByteFormatter.FormatCount(files), destination);
            if (_lyrics.Enabled) body += " " + Loc["download.confirmLyrics"];
            go = await _dialogs.ConfirmAsync(Loc.Format("download.confirmTitle", ByteFormatter.Format(bytes)), body, Loc["download.start"], danger: false);
        }
        else
        {
            go = true;
        }

        if (!go) return;
        _runFolder = folder;
        _files = picked;
        _fromSelection = fromSelection;
        await RunAsync();
    }

    /// <summary>What still has to come over the network, and what the disk has room for (null when it cannot tell, as on a network share).</summary>
    private static (long Needed, long? Free) Measure(IReadOnlyList<DownloadFile> files, string destination)
    {
        long needed = 0;
        foreach (var file in files) needed += Math.Max(0, file.Size - AlreadyHere(destination, file));
        return (needed, FreeSpace(destination));
    }

    private static long AlreadyHere(string destination, DownloadFile file)
    {
        try
        {
            if (LocalPath.Resolve(destination, file.Target ?? file.ApiPath) is not { } target) return 0;
            if (DownloadEngine.IsComplete(target, file.Size)) return file.Size;
            var part = new FileInfo(target + ".part");
            return part.Exists ? part.Length : 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return 0;
        }
    }

    private static long? FreeSpace(string destination)
    {
        try
        {
            var folder = Path.GetFullPath(destination);
            while (!Directory.Exists(folder))
            {
                if (Path.GetDirectoryName(folder) is not { Length: > 0 } parent) return null;
                folder = parent;
            }
            return Path.GetPathRoot(folder) is { Length: > 0 } root ? new DriveInfo(root).AvailableFreeSpace : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    private async Task RunAsync()
    {
        using var cts = new CancellationTokenSource();
        _cts = cts;
        _failedPaths = [];

        WasStopped = false;
        EndedClean = false;
        IsDone = false;
        IsStopping = false;
        RingAngle = 0;
        PercentText = "0%";
        ProgressText = string.Empty;
        FilesText = string.Empty;
        SpeedText = string.Empty;
        RemainingText = string.Empty;
        ActiveFiles = [];
        SummaryText = string.Empty;
        LyricsSummaryText = string.Empty;
        Failures = [];
        IsRunning = true;
        IsOverlayVisible = true;

        var options = await LyricsOptionsAsync(cts.Token);

        DownloadReport report;
        string? problem = null;
        try
        {
            cts.Token.ThrowIfCancellationRequested();
            var destination = _runFolder ?? _settings.Destination;
            var parallel = _settings.Parallel;
            var progress = new Progress<DownloadProgress>(OnProgress);
            var files = _files;
            report = await Task.Run(() => _library.DownloadAsync(files, destination, parallel, options, progress, cts.Token));
        }
        catch (OperationCanceledException)
        {
            report = new DownloadReport(0, 0, [], true, 0);
        }
        catch (Exception e)
        {
            report = new DownloadReport(0, 0, [], false, 0);
            problem = e.Message;
        }

        _cts = null;
        if (options is not null && problem is null)
        {
            var (same, other, none) = _library.LastLyrics;
            LyricsSummaryText = Loc.Format("download.lyricsSummary", ByteFormatter.FormatCount(same), ByteFormatter.FormatCount(other), ByteFormatter.FormatCount(none));
        }
        Finish(report, problem);
    }

    /// <summary>The words come first, with their own title on the overlay. No words is no reason to stop the music.</summary>
    private async Task<LyricsOptions?> LyricsOptionsAsync(CancellationToken ct)
    {
        if (!_lyrics.Enabled) return null;

        IsGettingLyrics = true;
        var fetch = _lyrics.FetchAsync(force: false);
        await Task.WhenAny(fetch, Task.Delay(Timeout.Infinite, ct));
        IsGettingLyrics = false;

        if (ct.IsCancellationRequested) return null;
        if (await fetch) return _lyrics.Options;
        _owner.Toast("", _lyrics.ErrorText);
        return null;
    }

    private void OnProgress(DownloadProgress p)
    {
        if (!IsRunning) return;

        RingAngle = p.Fraction * 360;
        PercentText = ((int)Math.Floor(p.Fraction * 100)) + "%";
        ProgressText = Loc.Format("download.progress", ByteFormatter.Format(p.DoneBytes), ByteFormatter.Format(p.TotalBytes));
        FilesText = Loc.Format("download.files", ByteFormatter.FormatCount(p.Finished), ByteFormatter.FormatCount(p.TotalFiles));
        SpeedText = p.BytesPerSecond > 0 ? Loc.Format("download.speed", ByteFormatter.Format(p.BytesPerSecond)) : string.Empty;
        RemainingText = p.BytesPerSecond > 1024
            ? Loc.Format("download.remaining", Duration((p.TotalBytes - p.DoneBytes) / p.BytesPerSecond))
            : string.Empty;

        var active = p.Active.Select(Path.GetFileName).Select(n => n ?? string.Empty).ToList();
        if (!active.SequenceEqual(ActiveFiles)) ActiveFiles = active;
    }

    private static string Duration(double seconds)
    {
        var time = TimeSpan.FromSeconds(Math.Max(1, seconds));
        if (time.TotalHours >= 1) return Loc.Format("time.hours", (int)time.TotalHours, time.Minutes);
        return time.TotalMinutes >= 1 ? Loc.Format("time.minutes", (int)Math.Ceiling(time.TotalMinutes)) : Loc.Format("time.seconds", (int)Math.Ceiling(time.TotalSeconds));
    }

    private void Finish(DownloadReport report, string? problem)
    {
        IsRunning = false;
        IsStopping = false;
        ActiveFiles = [];
        SpeedText = string.Empty;
        RemainingText = string.Empty;

        _failedPaths = report.Failures.Select(f => f.ApiPath).ToList();
        Failures = report.Failures.Select(f => new FailureRow(Path.GetFileName(f.ApiPath), f.Reason)).ToList();
        WasStopped = report.Stopped;
        SummaryText = problem ?? Loc.Format("download.summary", ByteFormatter.FormatCount(report.Downloaded), ByteFormatter.FormatCount(report.AlreadyThere), ByteFormatter.FormatCount(report.Failures.Count));

        if (!report.Stopped && problem is null)
        {
            RingAngle = 360;
            PercentText = "100%";
            // What came through is off the list; what failed stays, ready to try again. A stopped run keeps it all,
            // since downloading again is how it continues.
            var failed = _failedPaths;
            if (_fromSelection) _owner.ChangeSelection(() => _library.KeepOnlySelected(failed));
        }

        EndedClean = !report.Stopped && problem is null && report.Failures.Count == 0;
        IsDone = true;
        if (EndedClean && report.Downloaded > 0) Celebrate?.Invoke();
    }

    [RelayCommand]
    private void Stop()
    {
        if (!CanStop) return;
        IsStopping = true;
        _cts?.Cancel();
    }

    [RelayCommand]
    private void Close()
    {
        if (!IsRunning) IsOverlayVisible = false;
    }

    /// <summary>Esc: stops a run, closes the overlay of one that is over.</summary>
    public void Escape()
    {
        if (IsRunning) Stop();
        else if (IsOverlayVisible) Close();
    }

    [RelayCommand]
    private void ShowFolder() => Shell.OpenFolder(_runFolder ?? _settings.Destination);

    [RelayCommand]
    private async Task RetryAsync()
    {
        if (IsRunning || _failedPaths.Count == 0) return;
        var failed = _failedPaths.ToHashSet(StringComparer.Ordinal);
        _files = _files.Where(f => failed.Contains(f.ApiPath)).ToList();
        if (_fromSelection)
        {
            _owner.ChangeSelection(() => _library.KeepOnlySelected(failed));
            await _owner.SelectionSettled();
        }
        await RunAsync();
    }
}
