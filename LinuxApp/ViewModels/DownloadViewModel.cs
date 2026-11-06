using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;

namespace JuiceDownloader.ViewModels;

public sealed record FailureVm(string Name, string Reason);

/// <summary>From the Download button to the end of the run: the questions first, then the overlay.</summary>
public sealed partial class DownloadViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly Library _library;
    private readonly LyricsViewModel _lyrics;
    private readonly SettingsViewModel _settings;
    private readonly IDialogService _dialogs;
    private readonly Action _selectionChanged;
    private CancellationTokenSource? _cts;
    private DownloadProgress _last = new();
    private DownloadReport? _report;
    private string? _lyricsNote;
    private bool _lyricsRan;
    private IReadOnlyList<DownloadFile>? _chosen;
    private string? _runFolder;

    public DownloadViewModel(Library library, LyricsViewModel lyrics, SettingsViewModel settings, IDialogService dialogs, Action selectionChanged)
    {
        _library = library;
        _lyrics = lyrics;
        _settings = settings;
        _dialogs = dialogs;
        _selectionChanged = selectionChanged;
    }

    /// <summary>Everything arrived and something was new: the view throws its confetti.</summary>
    public event Action? Celebrate;

    [ObservableProperty] private bool _isOpen;
    [ObservableProperty] private bool _isRunning;
    [ObservableProperty] private bool _isOver;
    [ObservableProperty] private bool _isStopping;
    [ObservableProperty] private bool _isGettingLyrics;

    public ObservableCollection<string> Active { get; } = [];
    public RangeCollection<FailureVm> Failures { get; } = [];

    public bool HasFailures => Failures.Count > 0;
    public bool CanStop => IsRunning && !IsStopping;
    public bool WasStopped => _report?.Stopped == true;
    public bool IsClean => IsOver && !WasStopped && !HasFailures;
    public bool IsTroubled => IsOver && !IsClean;

    public double Fraction => _last.Fraction;
    public double RingAngle => IsOver && !WasStopped ? 360 : 360 * _last.Fraction;
    public string PercentText => ((int)Math.Floor((IsOver && !WasStopped ? 1 : _last.Fraction) * 100)).ToString() + "%";
    public string TitleText => IsOver ? Loc[WasStopped ? "download.stoppedTitle" : "download.doneTitle"]
        : IsGettingLyrics ? Loc["download.gettingLyrics"] : Loc["download.title"];
    public string BytesText => Loc.Format("download.progress", ByteFormatter.Format(_last.DoneBytes), ByteFormatter.Format(_last.TotalBytes));
    public string FilesText => Loc.Format("download.files", ByteFormatter.FormatCount(_last.Finished), ByteFormatter.FormatCount(_last.TotalFiles));
    public string SpeedText => _last.BytesPerSecond > 0 ? Loc.Format("download.speed", ByteFormatter.Format(_last.BytesPerSecond)) : "";
    public string RemainingText
    {
        get
        {
            if (_last.BytesPerSecond < 1 || _last.TotalBytes <= _last.DoneBytes) return "";
            return Loc.Format("download.remaining", TimeText((_last.TotalBytes - _last.DoneBytes) / _last.BytesPerSecond));
        }
    }
    public string StopText => Loc[IsStopping ? "download.stopping" : "download.stop"];

    public string SummaryText
    {
        get
        {
            if (_report is not { } r) return "";
            var text = Loc.Format("download.summary", ByteFormatter.FormatCount(r.Downloaded), ByteFormatter.FormatCount(r.AlreadyThere), ByteFormatter.FormatCount(r.Failures.Count));
            if (r.Stopped) text = Loc["download.stoppedBody"] + "\n" + text;
            if (_lyricsRan)
            {
                var (same, other, none) = _library.LastLyrics;
                text += "\n" + Loc.Format("download.lyricsSummary", ByteFormatter.FormatCount(same), ByteFormatter.FormatCount(other), ByteFormatter.FormatCount(none));
            }
            return _lyricsNote is null ? text : text + "\n" + _lyricsNote;
        }
    }

    private static string TimeText(double seconds)
    {
        if (seconds < 60) return Loc.Format("time.seconds", (int)Math.Ceiling(seconds));
        if (seconds < 3600) return Loc.Format("time.minutes", (int)Math.Ceiling(seconds / 60));
        var total = (int)Math.Ceiling(seconds / 60);
        return Loc.Format("time.hours", total / 60, total % 60);
    }

    partial void OnIsRunningChanged(bool value) => OnPropertyChanged(nameof(CanStop));
    partial void OnIsStoppingChanged(bool value)
    {
        OnPropertyChanged(nameof(CanStop));
        OnPropertyChanged(nameof(StopText));
    }
    partial void OnIsGettingLyricsChanged(bool value) => OnPropertyChanged(nameof(TitleText));

    /// <summary>The Download button: what will not fit is asked about, then the run, if the settings want it, is confirmed.</summary>
    public Task StartAsync()
    {
        if (IsOpen || _library.Catalog is not { SelectedFiles: > 0 } catalog) return Task.CompletedTask;
        var files = catalog.SelectedFilesList().Select(f => new DownloadFile(f.Path, f.Size)).ToList();
        return AskAndRunAsync(files, catalog.SelectedBytes, fromSelection: true);
    }

    /// <summary>A run of chosen files rather than the selection, with the same questions: the By Rules page.</summary>
    public Task StartAsync(IReadOnlyList<DownloadFile> files, long bytes) =>
        IsOpen || files.Count == 0 ? Task.CompletedTask : AskAndRunAsync(files, bytes, fromSelection: false);

    /// <summary>A whole folder of the catalog into a folder the user picks, under its own name. A copy in the download folder is no reason to skip a track.</summary>
    public async Task StartAlbumAsync(CatalogNode album)
    {
        if (IsOpen || await _dialogs.PickFolderAsync(Loc["download.pickAlbumFolder"]) is not { Length: > 0 } folder) return;
        await AskAndRunAsync(Library.AlbumFiles(album), album.Size, fromSelection: false, folder);
    }

    /// <summary>Set by the window's model: a short message that needs no answer (icon, text).</summary>
    public Action<string, string>? Toast { get; set; }

    private async Task AskAndRunAsync(IReadOnlyList<DownloadFile> wanted, long wantedBytes, bool fromSelection, string? folder = null)
    {
        var destination = folder ?? _settings.Destination;
        // Looked at afresh: only what is not in the folder yet is offered.
        var files = wanted;
        var bytes = wantedBytes;
        if (folder is not null)
        {
            files = await Task.Run(() => wanted.Where(f => LocalPath.Resolve(folder, f.Target ?? f.ApiPath) is not { } path || !DownloadEngine.IsComplete(path, f.Size)).ToList());
            bytes = files.Sum(f => f.Size);
            if (files.Count == 0)
            {
                Toast?.Invoke("CheckCircleOutline", Loc["download.allThere"]);
                return;
            }
        }
        else if (_library.Catalog is { } catalog)
        {
            var state = await Task.Run(() => DiskState.Scan(catalog, destination));
            DiskState.Current = state;
            files = wanted.Where(f => !state.Has(f.ApiPath)).ToList();
            bytes = files.Sum(f => f.Size);
            if (files.Count == 0)
            {
                Toast?.Invoke("CheckCircleOutline", Loc["download.allThere"]);
                return;
            }
        }
        var (needed, free) = await Task.Run(() => (StillNeeded(destination, files), FreeSpace(destination)));

        if (free is { } room && room < needed)
        {
            var go = await _dialogs.ConfirmAsync(Loc["download.noSpaceTitle"],
                Loc.Format("download.noSpaceBody", ByteFormatter.Format(needed), ByteFormatter.Format(room)), Loc["download.anyway"], danger: true);
            if (!go) return;
        }
        else if (_settings.ConfirmDownloads && files.Count > 1) // one file off its row needs no second click
        {
            var body = Loc.Format("download.confirmBody", ByteFormatter.FormatCount(files.Count), destination);
            if (_lyrics.Enabled) body += " " + Loc["download.confirmLyrics"];
            var go = await _dialogs.ConfirmAsync(Loc.Format("download.confirmTitle", ByteFormatter.Format(bytes)), body, Loc["download.start"], danger: false);
            if (!go) return;
        }

        _chosen = fromSelection ? null : files;
        _runFolder = folder;
        await RunAsync();
    }

    private static long StillNeeded(string destination, IReadOnlyList<DownloadFile> files)
    {
        long needed = 0;
        foreach (var file in files)
        {
            var size = file.Size;
            if (LocalPath.Resolve(destination, file.Target ?? file.ApiPath) is not { } local) continue;
            try
            {
                if (DownloadEngine.IsComplete(local, size)) continue;
                needed += new FileInfo(local + ".part") is { Exists: true } part ? Math.Max(0, size - part.Length) : size;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                needed += size;
            }
        }
        return needed;
    }

    /// <summary>The free space where the files will go, from the nearest folder that exists; null when the system will not say.</summary>
    private static long? FreeSpace(string destination)
    {
        try
        {
            var folder = new DirectoryInfo(destination);
            while (folder is { Exists: false }) folder = folder.Parent;
            return folder is null ? null : new DriveInfo(folder.FullName).AvailableFreeSpace;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }

    private async Task RunAsync()
    {
        _cts = new CancellationTokenSource();
        _report = null;
        _lyricsNote = null;
        _lyricsRan = false;
        Failures.ReplaceAll([]);
        Active.Clear();
        IsOver = false;
        IsStopping = false;
        IsRunning = true;
        Show(new DownloadProgress
        {
            TotalFiles = _chosen?.Count ?? _library.Catalog?.SelectedFiles ?? 0,
            TotalBytes = _chosen?.Sum(f => f.Size) ?? _library.Catalog?.SelectedBytes ?? 0,
        });
        IsOpen = true;

        var progress = new Progress<DownloadProgress>(Show);
        DownloadReport report;
        try
        {
            LyricsOptions? options = null;
            if (_lyrics.Enabled)
            {
                IsGettingLyrics = _library.Lyrics is null;
                await _lyrics.LoadAsync(false).WaitAsync(_cts.Token);
                IsGettingLyrics = false;
                // Music without words beats no music: a run goes on when the words cannot be had.
                if (_library.Lyrics is not null) { options = _lyrics.Options; _lyricsRan = true; }
                else _lyricsNote = _lyrics.Failure;
            }
            report = _chosen is { } chosen
                ? await _library.DownloadAsync(chosen, _runFolder ?? _settings.Destination, _settings.Parallel, options, progress, _cts.Token)
                : await _library.DownloadSelectedAsync(_settings.Destination, _settings.Parallel, options, progress, _cts.Token);
        }
        catch (OperationCanceledException)
        {
            report = new DownloadReport(0, 0, [], true, 0);
        }

        _cts.Dispose();
        _cts = null;
        _report = report;
        IsGettingLyrics = false;
        IsRunning = false;
        IsStopping = false;
        Active.Clear();
        Failures.ReplaceAll(report.Failures.Select(f => new FailureVm(Path.GetFileName(f.ApiPath), f.Reason)));
        OnPropertyChanged(nameof(HasFailures));
        IsOver = true;
        OnPropertyChanged(string.Empty);

        // A stopped run stays selected, so downloading again continues it; otherwise what is left is what failed.
        if (_chosen is { } ran)
        {
            // Retrying a chosen run takes what failed of it; the selection was never part of it.
            var failed = report.Failures.Select(f => f.ApiPath).ToHashSet(StringComparer.Ordinal);
            if (!report.Stopped) _chosen = ran.Where(f => failed.Contains(f.ApiPath)).ToList();
        }
        else
        {
            if (!report.Stopped) _library.KeepOnlySelected(report.Failures.Select(f => f.ApiPath));
            _selectionChanged();
        }

        if (!report.Stopped && report.Failures.Count == 0 && report.Downloaded > 0) Celebrate?.Invoke();
    }

    private void Show(DownloadProgress p)
    {
        _last = p;
        OnPropertyChanged(nameof(Fraction));
        OnPropertyChanged(nameof(RingAngle));
        OnPropertyChanged(nameof(PercentText));
        OnPropertyChanged(nameof(BytesText));
        OnPropertyChanged(nameof(FilesText));
        OnPropertyChanged(nameof(SpeedText));
        OnPropertyChanged(nameof(RemainingText));

        if (Active.SequenceEqual(p.Active.Select(Path.GetFileName))) return;
        Active.Clear();
        foreach (var path in p.Active) Active.Add(Path.GetFileName(path));
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
        if (!IsRunning) IsOpen = false;
    }

    [RelayCommand]
    private void ShowFolder()
    {
        var folder = _runFolder ?? _settings.Destination;
        _ = Task.Run(() =>
        {
            try { Directory.CreateDirectory(folder); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
            Platform.Open(folder);
        });
    }

    [RelayCommand]
    private Task Retry() => RunAsync();

    /// <summary>Esc: stops a run, closes a finished one.</summary>
    public void Escape()
    {
        if (IsRunning) Stop();
        else if (IsOpen) Close();
    }

    public void OnLanguageChanged() => OnPropertyChanged(string.Empty);
}
