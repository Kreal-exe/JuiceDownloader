using System.IO;
using System.Windows.Threading;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

/// <summary>The order of the sidebar. The names of the catalog pages match <see cref="Catalog.SectionTable"/>'s ids.</summary>
public enum AppPage { Overview, Albums, Unreleased, Compilations, SessionEdits, Originals, Studio, Instrumentals, Remixes, Snippets, Media, Rules, Lyrics, Gaps, Settings, About }

public sealed partial class MainViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly AppSettings _settings;
    private readonly Library _library;
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;

    private Task _selectionTail = Task.CompletedTask;
    private int _selectionRefreshQueued;
    private volatile CatalogRelations? _relations;

    public MainViewModel(AppSettings settings, IDialogService dialogs)
    {
        _settings = settings;

        var http = ApiClient.CreateHttp(Version);
        var cache = new CatalogCache(SettingsStore.CacheDirectory);
        _library = new Library(new ApiClient(http), new DownloadEngine(http), cache);

        Settings = new SettingsViewModel(settings, SaveSettings, dialogs);
        Lyrics = new LyricsViewModel(_library, cache, settings, SaveSettings, dialogs);
        Download = new DownloadViewModel(_library, Settings, Lyrics, dialogs, this);
        Gaps = new GapsViewModel(_library, http, Settings, Lyrics, dialogs);
        Player = new PlayerViewModel(http, Settings, settings, SaveSettings, Toast);
        Sections = Catalog.SectionTable.Select(s => new SectionViewModel(s.Id, this)).ToList();
        Search = new SectionViewModel("everything", this);
        Rules = new RulesViewModel(_library, settings, SaveSettings, Download, Player);
        LyricsSheet = new LyricsSheetViewModel(_library, Lyrics);
        Player.ShowLyrics = node => _ = LyricsSheet.ShowAsync(node);
        Player.DownloadFile = node => Download.StartFilesAsync([new DownloadFile(node.Path, node.Size)]);
        Preview = new PreviewViewModel(http, Settings, Player, dialogs, this);
        Settings.ResetRequested += Rules.ResetToDefaults;
        Player.NowPlayingChanged += () =>
        {
            foreach (var section in Sections) section.RefreshPlaying();
            Search.RefreshPlaying();
            Rules.RefreshPlaying();
        };

        Settings.ResetRequested += Lyrics.ResetToDefaults;
        DiskState.Changed += OnDiskChanged;
        Settings.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(SettingsViewModel.Destination)) _ = RefreshDiskAsync(); };
        Download.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(DownloadViewModel.IsDone) && Download.IsDone) _ = RefreshDiskAsync(); };
        Loc.LanguageChanged += (_, _) => OnPropertyChanged(string.Empty);
        Controls.ThemeManager.Changed += () => OnPropertyChanged(nameof(IsDarkTheme));
    }

    public SettingsViewModel Settings { get; }
    public LyricsViewModel Lyrics { get; }
    public DownloadViewModel Download { get; }
    public GapsViewModel Gaps { get; }
    public PlayerViewModel Player { get; }
    public RulesViewModel Rules { get; }
    public LyricsSheetViewModel LyricsSheet { get; }
    public PreviewViewModel Preview { get; }
    public IReadOnlyList<SectionViewModel> Sections { get; }
    /// <summary>The Overview's search, through the whole catalog.</summary>
    public SectionViewModel Search { get; }

    /// <summary>Raised when a short, non-blocking message should appear (glyph, text).</summary>
    public event Action<string, string>? ToastRequested;

    public bool IsDarkTheme => Controls.ThemeManager.IsDark;
    public string Version => typeof(MainViewModel).Assembly.GetName().Version?.ToString(3) ?? "1.0.0";
    public string SettingsFolder => SettingsStore.Directory;
    public string CatalogFilesText => Loc.Format("overview.selectedLine", ByteFormatter.FormatCount(CatalogFiles));

    // ── navigation ──
    [ObservableProperty] private AppPage _currentPage = AppPage.Overview;

    // ── the catalog ──
    [ObservableProperty] private bool _isLoading = true;
    [ObservableProperty] private bool _isRefreshing;
    [ObservableProperty] private bool _isFailed;
    [ObservableProperty] private bool _isOffline;
    [ObservableProperty] private string _failureReason = string.Empty;
    [ObservableProperty] private long _catalogBytes;
    [ObservableProperty] private int _catalogFiles;

    // ── the selection ──
    [ObservableProperty] private long _selectedBytes;
    [ObservableProperty] private int _selectedFiles;
    [ObservableProperty] private double _ringAngle;

    public bool CanDownload => SelectedFiles > 0;
    public bool HasNothingSelected => SelectedFiles == 0 && !IsFailed;
    public bool HasCatalog => CatalogFiles > 0;
    /// <summary>A section page has nothing to list: the catalog is on its way, or it could not be had.</summary>
    public bool HasNoCatalogYet => !HasCatalog;
    public string RefreshText => Loc[IsRefreshing ? "catalog.refreshing" : "catalog.refresh"];
    public string CatalogLine => Loc.Format("overview.catalogLine", ByteFormatter.FormatCount(CatalogFiles), ByteFormatter.Format(CatalogBytes));
    public string SelectedFilesText => Loc.Format("overview.selectedLine", ByteFormatter.FormatCount(SelectedFiles));
    /// <summary>With nothing ticked the ring says what is already in the folder.</summary>
    public long RingBytes => SelectedFiles > 0 ? SelectedBytes : DiskState.Current?.Bytes ?? 0;
    public string RingCaption => Loc[SelectedFiles > 0 ? "overview.selected" : "overview.downloaded"];
    public string RingFilesText => Loc.Format("overview.selectedLine", ByteFormatter.FormatCount(SelectedFiles > 0 ? SelectedFiles : DiskState.Current?.Files ?? 0));
    public string DownloadButtonText
    {
        get
        {
            if (!CanDownload) return Loc["download.none"];
            var missing = _library.Catalog?.SelectedFilesList().Where(f => DiskState.Current?.Has(f.Path) != true).Sum(f => f.Size) ?? 0;
            return missing > 0 ? Loc.Format("download.buttonSize", ByteFormatter.Format(missing)) : Loc["download.alreadyThere"];
        }
    }
    public string FailureText => Loc.Format("catalog.failed.desc", FailureReason);
    public string NoCatalogText => IsFailed ? FailureText : Loc["catalog.loading"];
    public string UpdatedText => _library.UpdatedAt is { } time ? Loc.Format("overview.updated", time.ToLocalTime().ToString("g")) : string.Empty;

    partial void OnCurrentPageChanged(AppPage value)
    {
        LastClicked = null;
        if (value == AppPage.Rules) Rules.PageOpened();
    }

    partial void OnIsRefreshingChanged(bool value) => OnPropertyChanged(nameof(RefreshText));
    partial void OnIsFailedChanged(bool value)
    {
        OnPropertyChanged(nameof(HasNothingSelected));
        OnPropertyChanged(nameof(NoCatalogText));
    }
    partial void OnFailureReasonChanged(string value)
    {
        OnPropertyChanged(nameof(FailureText));
        OnPropertyChanged(nameof(NoCatalogText));
    }
    partial void OnCatalogBytesChanged(long value)
    {
        OnPropertyChanged(nameof(CatalogLine));
        OnPropertyChanged(nameof(CatalogFilesText));
    }
    partial void OnCatalogFilesChanged(int value)
    {
        OnPropertyChanged(nameof(CatalogLine));
        OnPropertyChanged(nameof(HasCatalog));
        OnPropertyChanged(nameof(HasNoCatalogYet));
    }
    partial void OnSelectedBytesChanged(long value)
    {
        OnPropertyChanged(nameof(DownloadButtonText));
        OnPropertyChanged(nameof(RingBytes));
    }
    partial void OnSelectedFilesChanged(int value)
    {
        OnPropertyChanged(nameof(CanDownload));
        OnPropertyChanged(nameof(HasNothingSelected));
        OnPropertyChanged(nameof(SelectedFilesText));
        OnPropertyChanged(nameof(DownloadButtonText));
        OnPropertyChanged(nameof(RingBytes));
        OnPropertyChanged(nameof(RingCaption));
        OnPropertyChanged(nameof(RingFilesText));
    }

    /// <summary>Looks at the download folder again: on launch, after a run, and when the folder changes.</summary>
    public async Task RefreshDiskAsync()
    {
        if (_library.Catalog is not { } catalog || Download.IsRunning) return;
        var destination = _settings.Destination;
        DiskState.Current = await Task.Run(() =>
        {
            _library.KnownLyrics();   // the rows show lengths from it
            return DiskState.Scan(catalog, destination);
        });
    }

    private void OnDiskChanged()
    {
        OnPropertyChanged(nameof(RingBytes));
        OnPropertyChanged(nameof(RingCaption));
        OnPropertyChanged(nameof(RingFilesText));
        OnPropertyChanged(nameof(DownloadButtonText));
        var catalog = _library.Catalog;
        var ringBytes = RingBytes;
        RingAngle = catalog is { TotalBytes: > 0 } && ringBytes > 0 ? Math.Max(4, 360.0 * ringBytes / catalog.TotalBytes) : 0;
        foreach (var section in Sections) section.OnDiskChanged();
        Rules.OnDiskChanged();
    }

    /// <summary>The last catalog at once, then the network if it is old or missing. Each slow step stays off the window's thread.</summary>
    public async Task StartAsync()
    {
        var cached = await Task.Run(() => _library.LoadCached());
        if (cached)
        {
            AttachCatalog();
            IsLoading = false;
            _ = RefreshDiskAsync();
        }

        Lyrics.Start();

        if (!cached || (_settings.RefreshOnLaunch && _library.CatalogIsStale))
            await RefreshCatalogCommand.ExecuteAsync(null);
    }

    [RelayCommand]
    private async Task RefreshCatalogAsync()
    {
        if (IsRefreshing || Download.IsRunning) return;

        IsRefreshing = true;
        IsFailed = false;
        try
        {
            await SelectionSettled();
            // Task.Run: building the tree and writing the cache run on after the network's await, which must not bring them back here.
            await Task.Run(() => _library.RefreshAsync(CancellationToken.None));
            AttachCatalog();
            _ = RefreshDiskAsync();
            IsOffline = false;
        }
        catch (Exception e)
        {
            // Anything from a dropped connection to a server answering nonsense: the catalog we have stays.
            if (_library.Catalog is null)
            {
                FailureReason = e.Message;
                IsFailed = true;
            }
            else
            {
                IsOffline = true;
            }
        }
        finally
        {
            IsLoading = false;
            IsRefreshing = false;
        }
    }

    private void AttachCatalog()
    {
        if (_library.Catalog is not { } catalog) return;
        foreach (var section in Sections) section.Attach(catalog.Section(section.Id));
        Search.Attach(catalog.Everything());
        CatalogBytes = catalog.TotalBytes;
        CatalogFiles = catalog.TotalFiles;
        OnPropertyChanged(nameof(UpdatedText));
        ApplySelection();
        Rules.CatalogChanged();
        _relations = null;
        _ = Task.Run(() => _relations = new CatalogRelations(catalog));
    }

    /// <summary>The file row last clicked on this page: what Space looks at when the pointer is over no row.</summary>
    internal CatalogNode? LastClicked { get; set; }

    // ── what a row's menu asks of the app ──

    internal SectionViewModel? SectionOf(CatalogNode node) => Sections.FirstOrDefault(s => s.Holds(node));

    /// <summary>The same song elsewhere. Worked out in the background once per catalog; until then, nowhere.</summary>
    internal IReadOnlyList<CatalogNode> RelationsOf(CatalogNode node) => _relations?.Of(node) ?? [];

    internal void SelectNode(CatalogNode node, bool on) => ChangeSelection(() => Catalog.Select(node, on));

    internal void Reveal(CatalogNode node)
    {
        if (SectionOf(node) is not { } section) return;
        CurrentPage = section.Page;
        section.Reveal(node);
    }

    internal void FindVersions(CatalogNode node)
    {
        if (SectionOf(node) is not { } section) return;
        CurrentPage = section.Page;
        section.Query = WebLyrics.Bare(node.Name);
    }

    // ── selection: changed on the pool one change at a time, shown here at most once per dispatcher turn ──

    /// <summary>
    /// Selecting a folder walks all its files and their parents. The nodes' trees never change shape, so reading the
    /// counts here meanwhile is safe; the refresh queued after each change shows the settled numbers.
    /// </summary>
    internal void ChangeSelection(Action change)
    {
        _selectionTail = _selectionTail.ContinueWith(_ =>
        {
            change();
            QueueSelectionRefresh();
        }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
    }

    internal Task SelectionSettled() => _selectionTail;

    private void QueueSelectionRefresh()
    {
        if (Interlocked.Exchange(ref _selectionRefreshQueued, 1) == 1) return;
        _dispatcher.InvokeAsync(() =>
        {
            Interlocked.Exchange(ref _selectionRefreshQueued, 0);
            ApplySelection();
        });
    }

    private IEnumerable<SectionViewModel> UnreleasedVms => Sections.Where(s => Catalog.UnreleasedSections.Contains(s.Id));
    public bool? UnreleasedState => LibraryRowVm.StateOf(UnreleasedVms.Sum(s => s.SelectedFiles), UnreleasedVms.Sum(s => s.FileCount));
    public string UnreleasedSize => ByteFormatter.Format(UnreleasedVms.Sum(s => s.Size));

    [RelayCommand]
    private void ToggleUnreleased()
    {
        if (_library.Catalog is not { } catalog) return;
        ChangeSelection(() =>
        {
            var parts = Catalog.UnreleasedSections.Select(catalog.Section).ToList();
            var on = parts.Sum(s => s.SelectedFiles) < parts.Sum(s => s.FileCount);
            foreach (var row in parts.SelectMany(s => s.Rows)) Catalog.Select(row, on);
        });
    }

    private void ApplySelection()
    {
        var catalog = _library.Catalog;
        SelectedBytes = catalog?.SelectedBytes ?? 0;
        SelectedFiles = catalog?.SelectedFiles ?? 0;
        // A sliver stays visible however small the share.
        RingAngle = catalog is { TotalBytes: > 0 } && RingBytes > 0 ? Math.Max(4, 360.0 * RingBytes / catalog.TotalBytes) : 0;
        foreach (var section in Sections) section.RefreshSelection();
        OnPropertyChanged(nameof(UnreleasedState));
        OnPropertyChanged(nameof(UnreleasedSize));
        Search.RefreshSelection();
    }

    internal void Toast(string glyph, string text) => ToastRequested?.Invoke(glyph, text);

    // ── commands ──

    [RelayCommand]
    private void Navigate(AppPage page) => CurrentPage = page;

    [RelayCommand]
    private void OpenSection(SectionViewModel? section)
    {
        if (section is not null) CurrentPage = section.Page;
    }

    [RelayCommand]
    private void Escape()
    {
        if (LyricsSheet.IsVisible) LyricsSheet.CloseCommand.Execute(null);
        else if (Preview.IsVisible) Preview.CloseCommand.Execute(null);
        else Download.Escape();
    }

    [RelayCommand]
    private void ToggleTheme() => Settings.Theme = Controls.ThemeManager.IsDark ? "light" : "dark";

    [RelayCommand]
    private void OpenFolder(string? path) => Shell.OpenFolder(path);

    [RelayCommand]
    private void OpenUrl(string url) => Shell.OpenUrl(url);

    private void SaveSettings() => SettingsStore.Save(_settings);
}
