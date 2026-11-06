using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;

namespace JuiceDownloader.ViewModels;

/// <summary>The Lyrics page: the add-on's switches, the songs it knows, and words for a folder of music.</summary>
public sealed partial class LyricsViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly AppSettings _settings;
    private readonly Action _save;
    private readonly Library _library;
    private readonly CatalogCache _cache;
    private readonly IDialogService _dialogs;
    private Task? _loading;
    private CancellationTokenSource? _folderCts;
    private LyricsRunReport? _folderReport;
    private (int Done, int Total) _loaded;
    private LyricsRunProgress? _folderProgress;

    public LyricsViewModel(AppSettings settings, Action save, Library library, CatalogCache cache, IDialogService dialogs)
    {
        _settings = settings;
        _save = save;
        _library = library;
        _cache = cache;
        _dialogs = dialogs;
        _enabled = settings.LyricsEnabled;
        _embed = settings.LyricsEmbed;
        _sidecar = settings.LyricsSidecar;
        _timedInTag = settings.LyricsTimedInTag;
    }

    [ObservableProperty] private bool _enabled;
    [ObservableProperty] private bool _embed;
    [ObservableProperty] private bool _sidecar;
    [ObservableProperty] private bool _timedInTag;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string? _failure;
    [ObservableProperty] private bool _isFolderRunning;
    [ObservableProperty] private string? _folderSummary;

    public LyricsOptions Options => new(Embed, Sidecar, TimedInTag);
    public RangeCollection<string> Missing { get; } = [];
    public bool HasMissing => Missing.Count > 0;
    public bool HasFailure => !string.IsNullOrEmpty(Failure);
    public bool HasFolderSummary => !string.IsNullOrEmpty(FolderSummary);

    public string LoadingText => Loc.Format("lyrics.loading", ByteFormatter.FormatCount(_loaded.Done), ByteFormatter.FormatCount(_loaded.Total));

    public string StatsText => _library.Lyrics is { } index
        ? Loc.Format("lyrics.stats", ByteFormatter.FormatCount(index.SongCount), ByteFormatter.FormatCount(index.WithLyrics))
        : Loc["lyrics.notLoaded"];

    public string UpdatedText => _library.Lyrics is not null && _cache.SongsTime is { } time
        ? Loc.Format("lyrics.updated", time.ToLocalTime().ToString("g"))
        : "";

    public string FolderRunningText => _folderProgress is { } p
        ? Loc.Format("lyrics.folder.running", ByteFormatter.FormatCount(p.Done), ByteFormatter.FormatCount(p.Total), p.Name)
        : "";

    partial void OnEnabledChanged(bool value)
    {
        _settings.LyricsEnabled = value;
        _save();
        if (value) _ = LoadAsync(false);
    }

    partial void OnEmbedChanged(bool value)
    {
        _settings.LyricsEmbed = value;
        _save();
    }

    partial void OnSidecarChanged(bool value)
    {
        _settings.LyricsSidecar = value;
        _save();
    }

    partial void OnTimedInTagChanged(bool value)
    {
        _settings.LyricsTimedInTag = value;
        _save();
    }

    partial void OnFailureChanged(string? value) => OnPropertyChanged(nameof(HasFailure));
    partial void OnFolderSummaryChanged(string? value) => OnPropertyChanged(nameof(HasFolderSummary));

    /// <summary>Gets the songs once, however many ask for them at the same time; never throws, <see cref="Failure"/> says what went wrong.</summary>
    public Task LoadAsync(bool force)
    {
        if (_loading is { IsCompleted: false }) return _loading;
        return _loading = RunLoadAsync(force);
    }

    private async Task RunLoadAsync(bool force)
    {
        IsLoading = true;
        Failure = null;
        _loaded = (0, 0);
        OnPropertyChanged(nameof(LoadingText));
        var progress = new Progress<(int Done, int Total)>(p =>
        {
            _loaded = p;
            OnPropertyChanged(nameof(LoadingText));
        });
        try
        {
            await Task.Run(() => _library.EnsureLyricsAsync(progress, force, CancellationToken.None));
        }
        catch (Exception e) when (e is HttpRequestException or IOException or JsonException or InvalidDataException or OperationCanceledException)
        {
            Failure = Loc.Format("lyrics.failed", e.Message);
        }
        IsLoading = false;
        OnPropertyChanged(nameof(StatsText));
        OnPropertyChanged(nameof(UpdatedText));
    }

    [RelayCommand]
    private Task UpdateLyrics() => LoadAsync(true);

    [RelayCommand]
    private async Task ChooseFolder()
    {
        if (IsFolderRunning) return;
        var folder = await _dialogs.PickFolderAsync(Loc["lyrics.folder.choose"]);
        if (string.IsNullOrEmpty(folder)) return;
        await RunFolder(folder);
    }

    [RelayCommand]
    private async Task AddToDownloadFolder()
    {
        if (!IsFolderRunning) await RunFolder(_settings.Destination);
    }

    private async Task RunFolder(string folder)
    {
        IsFolderRunning = true;
        FolderSummary = null;
        Missing.ReplaceAll([]);
        OnPropertyChanged(nameof(HasMissing));
        _folderProgress = null;
        OnPropertyChanged(nameof(FolderRunningText));
        _folderCts = new CancellationTokenSource();
        var progress = new Progress<LyricsRunProgress>(p =>
        {
            _folderProgress = p;
            OnPropertyChanged(nameof(FolderRunningText));
        });

        await LoadAsync(false);
        if (_library.Lyrics is not null)
        {
            try
            {
                _folderReport = await Task.Run(() => _library.AddLyricsToFolderAsync(folder, Options, progress, _folderCts.Token));
                ShowFolderReport();
            }
            catch (OperationCanceledException)
            {
                _folderReport = null;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Failure = Loc.Format("lyrics.failed", e.Message);
            }
        }

        _folderCts.Dispose();
        _folderCts = null;
        IsFolderRunning = false;
    }

    [RelayCommand]
    private void StopFolder() => _folderCts?.Cancel();

    private void ShowFolderReport()
    {
        if (_folderReport is not { } r) return;
        FolderSummary = Loc.Format("lyrics.folder.summary", ByteFormatter.FormatCount(r.Written), ByteFormatter.FormatCount(r.AlreadyThere), ByteFormatter.FormatCount(r.NotFound), ByteFormatter.FormatCount(r.Failed));
        Missing.ReplaceAll(r.Missing);
        OnPropertyChanged(nameof(HasMissing));
    }

    public void Reset()
    {
        Enabled = false;
        Embed = true;
        Sidecar = true;
        TimedInTag = false;
    }

    public void OnLanguageChanged()
    {
        OnPropertyChanged(nameof(LoadingText));
        OnPropertyChanged(nameof(StatsText));
        OnPropertyChanged(nameof(UpdatedText));
        OnPropertyChanged(nameof(FolderRunningText));
        ShowFolderReport();
    }
}
