using System.Windows.Threading;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

/// <summary>The lyrics page: the add-on's switches, what it knows, and a run over a folder of the user's own.</summary>
public sealed partial class LyricsViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly Library _library;
    private readonly CatalogCache _cache;
    private readonly AppSettings _settings;
    private readonly Action _save;
    private readonly IDialogService _dialogs;
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;

    private Task<bool>? _fetching;
    private CancellationTokenSource? _runCts;

    public LyricsViewModel(Library library, CatalogCache cache, AppSettings settings, Action save, IDialogService dialogs)
    {
        _library = library;
        _cache = cache;
        _settings = settings;
        _save = save;
        _dialogs = dialogs;

        _enabled = settings.LyricsEnabled;
        _embed = settings.LyricsEmbed;
        _sidecar = settings.LyricsSidecar;
        _timed = settings.LyricsTimedInTag;

        Loc.LanguageChanged += (_, _) => OnPropertyChanged(string.Empty);
    }

    [ObservableProperty] private bool _enabled;
    [ObservableProperty] private bool _embed;
    [ObservableProperty] private bool _sidecar;
    [ObservableProperty] private bool _timed;

    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string _loadingText = string.Empty;
    [ObservableProperty] private string _errorText = string.Empty;

    [ObservableProperty] private bool _isRunning;
    [ObservableProperty] private string _runningText = string.Empty;
    [ObservableProperty] private string _summaryText = string.Empty;
    [ObservableProperty] private IReadOnlyList<string> _missing = [];

    public LyricsOptions Options => new(Embed, Sidecar, Timed);

    public string StatusText => IsLoading ? LoadingText
        : _library.Lyrics is { } lyrics ? Loc.Format("lyrics.stats", ByteFormatter.FormatCount(lyrics.SongCount), ByteFormatter.FormatCount(lyrics.WithLyrics))
        : Loc["lyrics.notLoaded"];

    public string UpdatedText => _cache.SongsTime is { } time ? Loc.Format("lyrics.updated", time.ToLocalTime().ToString("g")) : string.Empty;

    public bool HasMissing => Missing.Count > 0;

    partial void OnIsLoadingChanged(bool value) => RaiseStatus();
    partial void OnLoadingTextChanged(string value) => OnPropertyChanged(nameof(StatusText));
    partial void OnMissingChanged(IReadOnlyList<string> value) => OnPropertyChanged(nameof(HasMissing));

    partial void OnEnabledChanged(bool value)
    {
        _settings.LyricsEnabled = value;
        _save();
        if (value) _ = FetchAsync(force: false);
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

    partial void OnTimedChanged(bool value)
    {
        _settings.LyricsTimedInTag = value;
        _save();
    }

    /// <summary>At launch: the songs of the last time, in the background, when the add-on is on.</summary>
    public void Start()
    {
        if (Enabled) _ = FetchAsync(force: false);
        if (_settings.RefreshOnLaunch) _ = UpdateIfChangedAsync();
    }

    /// <summary>The words are kept until the API has something new; only then are they fetched again.</summary>
    private async Task UpdateIfChangedAsync()
    {
        if (await Task.Run(() => _library.LyricsChangedOnServerAsync(CancellationToken.None))) await FetchAsync(force: true);
    }

    public void ResetToDefaults()
    {
        Enabled = false;
        Embed = true;
        Sidecar = true;
        Timed = false;
    }

    /// <summary>Gets the songs; whoever asks while they are on their way waits for the same fetch. False when it failed.</summary>
    public Task<bool> FetchAsync(bool force)
    {
        if (_fetching is { IsCompleted: false } running) return running;
        return _fetching = RunFetchAsync(force);
    }

    private async Task<bool> RunFetchAsync(bool force)
    {
        LoadingText = Loc.Format("lyrics.loading", ByteFormatter.FormatCount(0), "…");
        IsLoading = true;
        ErrorText = string.Empty;
        var progress = new Latest<(int Done, int Total)>(_dispatcher, p =>
        {
            if (IsLoading) LoadingText = Loc.Format("lyrics.loading", ByteFormatter.FormatCount(p.Done), ByteFormatter.FormatCount(p.Total));
        });

        try
        {
            // Off the window's thread altogether: reading the cached songs is 13 MB of JSON before the first await.
            await Task.Run(() => _library.EnsureLyricsAsync(progress, force, CancellationToken.None));
            return true;
        }
        catch (Exception e)
        {
            ErrorText = Loc.Format("lyrics.failed", e.Message);
            return false;
        }
        finally
        {
            IsLoading = false;
            RaiseStatus();
        }
    }

    [RelayCommand]
    private Task Update() => FetchAsync(force: true);

    [RelayCommand]
    private async Task ChooseFolderAsync()
    {
        if (IsRunning || _dialogs.PickFolder(null) is not { Length: > 0 } folder) return;
        await RunFolderAsync(folder);
    }

    [RelayCommand]
    private async Task AddToDownloadFolderAsync()
    {
        if (!IsRunning) await RunFolderAsync(_settings.Destination);
    }

    private async Task RunFolderAsync(string folder)
    {
        IsRunning = true;
        SummaryText = string.Empty;
        ErrorText = string.Empty;
        Missing = [];
        RunningText = string.Empty;
        using var cts = new CancellationTokenSource();
        _runCts = cts;

        var progress = new Latest<LyricsRunProgress>(_dispatcher, p =>
        {
            if (IsRunning) RunningText = Loc.Format("lyrics.folder.running", ByteFormatter.FormatCount(p.Done), ByteFormatter.FormatCount(p.Total), p.Name);
        });

        try
        {
            var options = Options;
            var report = await Task.Run(() => _library.AddLyricsToFolderAsync(folder, options, progress, cts.Token));
            SummaryText = Loc.Format("lyrics.folder.summary", ByteFormatter.FormatCount(report.Written), ByteFormatter.FormatCount(report.AlreadyThere),
                ByteFormatter.FormatCount(report.NotFound), ByteFormatter.FormatCount(report.Failed));
            Missing = report.Missing;
        }
        catch (OperationCanceledException)
        {
            // stopped: what was written stays
        }
        catch (Exception e)
        {
            ErrorText = Loc.Format("lyrics.failed", e.Message);
        }
        finally
        {
            _runCts = null;
            IsRunning = false;
            RaiseStatus();
        }
    }

    [RelayCommand]
    private void Stop() => _runCts?.Cancel();

    public void RefreshStatus() => RaiseStatus();

    private void RaiseStatus()
    {
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(UpdatedText));
    }
}
