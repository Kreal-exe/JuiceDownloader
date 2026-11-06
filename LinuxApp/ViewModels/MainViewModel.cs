using System.Collections.ObjectModel;
using System.Text.Json;
using Avalonia.Media;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;
using Material.Icons;

namespace JuiceDownloader.ViewModels;

public enum AppPage { Overview, Albums, Unreleased, Compilations, SessionEdits, Originals, Studio, Instrumentals, Remixes, Snippets, Media, Rules, Lyrics, Gaps, Settings, About }

public sealed partial class MainViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    // The category colours, in turn, and a glyph for each entry of Catalog.SectionTable.
    private static readonly Color[] SectionColors =
        new[] { "#60A5FA", "#F59E0B", "#A78BFA", "#34D399", "#F472B6", "#22D3EE" }.Select(Color.Parse).ToArray();

    private static readonly Dictionary<string, MaterialIconKind> SectionGlyphs = new()
    {
        ["albums"] = MaterialIconKind.Album,
        ["unofficial"] = MaterialIconKind.CloudOutline,
        ["unreleased"] = MaterialIconKind.MusicNoteOutline,
        ["compilations"] = MaterialIconKind.PlaylistMusicOutline,
        ["sessionEdits"] = MaterialIconKind.ContentCut,
        ["originals"] = MaterialIconKind.FileMusicOutline,
        ["studio"] = MaterialIconKind.MicrophoneOutline,
        ["instrumentals"] = MaterialIconKind.Piano,
        ["remixes"] = MaterialIconKind.TuneVariant,
        ["snippets"] = MaterialIconKind.MovieOpenOutline,
        ["media"] = MaterialIconKind.ImageMultipleOutline,
    };

    private readonly AppSettings _settings;
    private readonly IDialogService _dialogs;
    private readonly Library _library;
    private bool _selectionPending;
    private CancellationTokenSource? _refreshCts;

    public MainViewModel(AppSettings settings, IDialogService dialogs)
    {
        _settings = settings;
        _dialogs = dialogs;

        var http = ApiClient.CreateHttp(Version);
        var cache = new CatalogCache(SettingsStore.CacheDirectory);
        _library = new Library(new ApiClient(http), new DownloadEngine(http), cache);

        Settings = new SettingsViewModel(settings, SaveSettings);
        Lyrics = new LyricsViewModel(settings, SaveSettings, _library, cache, dialogs);
        Download = new DownloadViewModel(_library, Lyrics, Settings, dialogs, NotifySelection);
        Settings.ResetRequested += Lyrics.Reset;
        Gaps = new GapsViewModel(_library, Lyrics, Settings, dialogs, http);
        Player = new PlayerViewModel($"JuiceDownloader/{Version}", settings, Settings, SaveSettings, (icon, text) => ToastRequested?.Invoke(icon, text));
        Player.ShowLyrics = ViewLyrics;
        Download.Toast = (icon, text) => ToastRequested?.Invoke(icon, text);
        DiskState.Changed += OnDiskChanged;
        Settings.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(SettingsViewModel.Destination)) _ = RefreshDiskAsync(); };
        Download.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(DownloadViewModel.IsRunning) && !Download.IsRunning) _ = RefreshDiskAsync(); };
        Player.DownloadFile = node => Download.StartAsync([new DownloadFile(node.Path, node.Size)], node.Size);
        Preview = new PreviewViewModel($"JuiceDownloader/{Version}", Settings, Player, dialogs, http, NotifySelection);
        Rules = new RulesViewModel(_library, Lyrics, settings, SaveSettings, Player, Download);
        Settings.ResetRequested += Rules.Reset;

        var index = 0;
        foreach (var (id, _) in Catalog.SectionTable)
            Sections.Add(new SectionViewModel(id, SectionGlyphs.GetValueOrDefault(id, MaterialIconKind.FolderOutline), SectionColors[index++ % SectionColors.Length], NotifySelection, Player, Preview, DownloadRow));
        Search = new SectionViewModel("everything", MaterialIconKind.Magnify, SectionColors[0], NotifySelection, Player, Preview, DownloadRow);
        _currentSection = Sections[0];
        Player.StateChanged += () =>
        {
            if (IsSectionPage) CurrentSection.RefreshPlaying();
            Search.RefreshPlaying();
        };

        Controls.ThemeManager.Changed += () => OnPropertyChanged(nameof(IsDarkTheme));
        Loc.LanguageChanged += (_, _) =>
        {
            OnPropertyChanged(string.Empty);
            foreach (var section in Sections) section.OnLanguageChanged();
            Search.OnLanguageChanged();
            Lyrics.OnLanguageChanged();
            Download.OnLanguageChanged();
            Gaps.OnLanguageChanged();
            Rules.OnLanguageChanged();
            Preview.OnLanguageChanged();
        };
    }

    public SettingsViewModel Settings { get; }
    public LyricsViewModel Lyrics { get; }
    public DownloadViewModel Download { get; }
    public GapsViewModel Gaps { get; }
    public PlayerViewModel Player { get; }
    public RulesViewModel Rules { get; }
    public PreviewViewModel Preview { get; }
    public LyricsSheetViewModel LyricsSheet { get; } = new();

    /// <summary>A short, non-blocking message (icon, text).</summary>
    public event Action<string, string>? ToastRequested;
    public ObservableCollection<SectionViewModel> Sections { get; } = [];
    /// <summary>The Overview's search, through the whole catalog.</summary>
    public SectionViewModel Search { get; }

    public string Version => typeof(MainViewModel).Assembly.GetName().Version?.ToString(3) ?? "1.0.0";
    public bool IsDarkTheme => Controls.ThemeManager.IsDark;
    public string SettingsFolder => SettingsStore.Directory;
    public string CatalogFilesText => _library.Catalog is { } catalog ? Loc.Format("overview.selectedLine", ByteFormatter.FormatCount(catalog.TotalFiles)) : "";
    public string VersionText => Loc.Format("about.version", Version);

    // ── pages ──
    [ObservableProperty] private AppPage _currentPage = AppPage.Overview;
    [ObservableProperty] private SectionViewModel _currentSection;

    public bool IsOverviewPage => CurrentPage == AppPage.Overview;
    public bool IsSectionPage => CurrentPage is >= AppPage.Albums and <= AppPage.Media;
    public bool IsLyricsPage => CurrentPage == AppPage.Lyrics;
    public bool IsGapsPage => CurrentPage == AppPage.Gaps;
    public bool IsRulesPage => CurrentPage == AppPage.Rules;
    public bool IsSettingsPage => CurrentPage == AppPage.Settings;
    public bool IsAboutPage => CurrentPage == AppPage.About;

    partial void OnCurrentPageChanged(AppPage value)
    {
        if (value is >= AppPage.Albums and <= AppPage.Media)
        {
            CurrentSection = Sections[value - AppPage.Albums];
            CurrentSection.EnsureRows();
            CurrentSection.RefreshPlaying();
        }
        OnPropertyChanged(nameof(IsOverviewPage));
        OnPropertyChanged(nameof(IsSectionPage));
        OnPropertyChanged(nameof(IsLyricsPage));
        OnPropertyChanged(nameof(IsGapsPage));
        OnPropertyChanged(nameof(IsRulesPage));
        if (value == AppPage.Rules) Rules.Open();
        OnPropertyChanged(nameof(IsSettingsPage));
        OnPropertyChanged(nameof(IsAboutPage));
    }

    public void OpenPage(string? name)
    {
        if (Enum.TryParse<AppPage>(name, ignoreCase: true, out var page) && Enum.IsDefined(page)) CurrentPage = page;
    }

    [RelayCommand]
    private void Navigate(AppPage page) => CurrentPage = page;

    [RelayCommand]
    private void OpenSection(SectionViewModel section) => CurrentPage = AppPage.Albums + Sections.IndexOf(section);

    // ── catalog ──
    [ObservableProperty] private bool _hasCatalog;
    [ObservableProperty] private bool _isFailed;
    [ObservableProperty] private bool _isOffline;
    [ObservableProperty] private bool _isRefreshing;
    [ObservableProperty] private string _failedText = "";

    public bool IsLoading => !HasCatalog && !IsFailed;
    public string RefreshText => Loc[IsRefreshing ? "catalog.refreshing" : "catalog.refresh"];
    public long CatalogBytes => _library.Catalog?.TotalBytes ?? 0;
    public string CatalogLine => _library.Catalog is { } c
        ? Loc.Format("overview.catalogLine", ByteFormatter.FormatCount(c.TotalFiles), ByteFormatter.Format(c.TotalBytes))
        : "";
    public string UpdatedText => _library.UpdatedAt is { } time ? Loc.Format("overview.updated", time.ToLocalTime().ToString("g")) : "";

    partial void OnHasCatalogChanged(bool value) => OnPropertyChanged(nameof(IsLoading));
    partial void OnIsFailedChanged(bool value) => OnPropertyChanged(nameof(IsLoading));
    partial void OnIsRefreshingChanged(bool value) => OnPropertyChanged(nameof(RefreshText));

    /// <summary>The last catalog at once, then whatever the network has to add.</summary>
    public async Task StartAsync()
    {
        await Task.Run(() => _library.LoadCached());
        ShowCatalog();
        _ = RefreshDiskAsync();
        if (Settings.RefreshOnLaunch ? _library.CatalogIsStale : _library.Catalog is null) await RefreshCatalogAsync();
        if (Lyrics.Enabled) _ = Lyrics.LoadAsync(false);
        // The words are kept until the API has something new; only then are they fetched again.
        if (Settings.RefreshOnLaunch && await Task.Run(() => _library.LyricsChangedOnServerAsync(CancellationToken.None))) await Lyrics.LoadAsync(true);
    }

    [RelayCommand]
    private async Task RefreshCatalogAsync()
    {
        if (IsRefreshing) return;
        IsRefreshing = true;
        IsFailed = false;
        _refreshCts = new CancellationTokenSource();
        try
        {
            // Off the window's thread: the answer is 10 MB of JSON and 30,000 nodes to build.
            await Task.Run(() => _library.RefreshAsync(_refreshCts.Token));
            IsOffline = false;
            ShowCatalog();
            _ = RefreshDiskAsync();
        }
        catch (Exception e) when (e is HttpRequestException or IOException or JsonException or InvalidDataException or OperationCanceledException)
        {
            IsOffline = _library.Catalog is not null;
            IsFailed = _library.Catalog is null;
            FailedText = Loc.Format("catalog.failed.desc", e.Message);
        }
        _refreshCts.Dispose();
        _refreshCts = null;
        IsRefreshing = false;
    }

    private void ShowCatalog()
    {
        if (_library.Catalog is not { } catalog) return;
        foreach (var section in Sections)
        {
            section.Bind(catalog.Section(section.Id));
            section.OnCatalogChanged();
        }
        Search.Bind(catalog.Everything());
        if (IsSectionPage) CurrentSection.EnsureRows();
        HasCatalog = true;
        Rules.OnCatalogChanged();
        _relations = null;
        _ = Task.Run(() => _relations = new CatalogRelations(catalog));
        OnPropertyChanged(nameof(CatalogBytes));
        OnPropertyChanged(nameof(CatalogLine));
        OnPropertyChanged(nameof(CatalogFilesText));
        OnPropertyChanged(nameof(UpdatedText));
        FlushSelection();
    }

    // ── selection ──
    [ObservableProperty] private long _selectedBytes;
    [ObservableProperty] private int _selectedFiles;
    [ObservableProperty] private double _ringAngle;

    public bool CanDownload => SelectedFiles > 0;
    public bool NothingSelected => SelectedFiles == 0;
    public string SelectedLine => Loc.Format("overview.selectedLine", ByteFormatter.FormatCount(SelectedFiles));
    /// <summary>With nothing ticked the ring says what is already in the folder.</summary>
    public long RingBytes => SelectedFiles > 0 ? SelectedBytes : DiskState.Current?.Bytes ?? 0;
    public string RingCaption => Loc[SelectedFiles > 0 ? "overview.selected" : "overview.downloaded"];
    public string DownloadText
    {
        get
        {
            if (SelectedFiles == 0) return Loc["download.none"];
            var missing = _library.Catalog?.SelectedFilesList().Where(f => DiskState.Current?.Has(f.Path) != true).Sum(f => f.Size) ?? 0;
            return missing > 0 ? Loc.Format("download.buttonSize", ByteFormatter.Format(missing)) : Loc["download.alreadyThere"];
        }
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
        foreach (var section in Sections) section.OnDiskChanged();
        Rules.OnDiskChanged();
        NotifySelection();
    }

    /// <summary>The counters and rows catch up once per turn of the dispatcher, however many ticks that turn held.</summary>
    private void NotifySelection()
    {
        if (_selectionPending) return;
        _selectionPending = true;
        Dispatcher.UIThread.Post(FlushSelection, DispatcherPriority.Normal);
    }

    private void FlushSelection()
    {
        _selectionPending = false;
        var catalog = _library.Catalog;
        SelectedBytes = catalog?.SelectedBytes ?? 0;
        SelectedFiles = catalog?.SelectedFiles ?? 0;
        var share = catalog is { TotalBytes: > 0 } ? 360.0 * RingBytes / catalog.TotalBytes : 0;
        // Never so thin that a selected album does not show.
        RingAngle = RingBytes > 0 ? Math.Max(share, 4) : 0;

        OnPropertyChanged(nameof(RingBytes));
        OnPropertyChanged(nameof(RingCaption));
        OnPropertyChanged(nameof(CanDownload));
        OnPropertyChanged(nameof(NothingSelected));
        OnPropertyChanged(nameof(SelectedLine));
        OnPropertyChanged(nameof(DownloadText));
        foreach (var section in Sections) section.Refresh();
        OnPropertyChanged(nameof(UnreleasedState));
        OnPropertyChanged(nameof(UnreleasedSize));
        if (IsSectionPage) CurrentSection.RefreshRows();
        if (Search.IsSearching) Search.RefreshRows();
        Preview.OnSelectionChanged();
    }

    private IEnumerable<SectionViewModel> UnreleasedVms => Sections.Where(s => Catalog.UnreleasedSections.Contains(s.Id));
    public bool? UnreleasedState
    {
        get
        {
            int selected = UnreleasedVms.Sum(s => s.SelectedFiles), total = UnreleasedVms.Sum(s => s.FileCount);
            return selected == 0 ? false : selected >= total ? true : null;
        }
    }
    public string UnreleasedSize => _library.Catalog is { } catalog ? ByteFormatter.Format(Catalog.UnreleasedSections.Sum(id => catalog.Section(id).Size)) : "";

    [RelayCommand]
    private void ToggleUnreleased()
    {
        var on = UnreleasedVms.Sum(s => s.SelectedFiles) < UnreleasedVms.Sum(s => s.FileCount);
        foreach (var section in UnreleasedVms) section.SetAll(on);
    }

    [RelayCommand]
    private void SelectAll()
    {
        foreach (var section in Sections) section.SetAll(true);
    }

    [RelayCommand]
    private void SelectNone()
    {
        _library.Catalog?.ClearSelection();
        NotifySelection();
    }

    // ── commands ──
    [RelayCommand]
    private Task StartDownload() => Download.StartAsync();

    [RelayCommand]
    private async Task ChangeFolder()
    {
        if (await _dialogs.PickFolderAsync(Loc["download.pickFolder"]) is { Length: > 0 } folder) Settings.Destination = folder;
    }

    [RelayCommand]
    private void ToggleTheme() => Settings.Theme = Controls.ThemeManager.IsDark ? "light" : "dark";

    [RelayCommand]
    private void Escape()
    {
        if (Player.IsQueueOpen) Player.IsQueueOpen = false;
        else if (LyricsSheet.IsOpen) LyricsSheet.Close();
        else if (Preview.IsOpen) Preview.Close();
        else Download.Escape();
    }

    /// <summary>
    /// Space, as in Quick Look: closes an open preview; opens the row under the pointer, or with the pointer on no row the
    /// one last clicked; on a row with nothing to preview it is the player's. False when it means nothing here.
    /// </summary>
    public bool OnSpace()
    {
        if (Preview.IsOpen) { Preview.Close(); return true; }
        if (Download.IsOpen || LyricsSheet.IsOpen) return false;
        var row = IsSectionPage ? CurrentSection.HoveredRow ?? CurrentSection.LastRow
            : IsOverviewPage && Search.IsSearching ? Search.HoveredRow ?? Search.LastRow : null;
        if (row is { HasPreview: true }) { row.ShowPreview(); return true; }
        if (!Player.IsOpen) return false;
        Player.PlayPauseCommand.Execute(null);
        return true;
    }

    // ── what a row's menu does ──
    private CatalogRelations? _relations;

    public IReadOnlyList<CatalogNode> RelationsOf(CatalogNode node)
    {
        if (_library.Catalog is not { } catalog) return [];
        return (_relations ??= new CatalogRelations(catalog)).Of(node);
    }

    /// <summary>The section a node is listed in, found from the top rows of each.</summary>
    public SectionViewModel? SectionOf(CatalogNode node)
    {
        if (_library.Catalog is not { } catalog) return null;
        for (var n = node; n is not null; n = n.Parent)
            foreach (var section in catalog.Sections)
                if (section.Rows.Contains(n)) return Sections.FirstOrDefault(s => s.Id == section.Id);
        return null;
    }

    private void OpenSectionOf(SectionViewModel section)
    {
        CurrentPage = AppPage.Albums + Sections.IndexOf(section);
        section.EnsureRows();
    }

    public void Reveal(CatalogNode node)
    {
        if (SectionOf(node) is not { } section) return;
        OpenSectionOf(section);
        section.Reveal(node);
    }

    public void FindVersions(CatalogNode node)
    {
        if (SectionOf(node) is not { } section) return;
        OpenSectionOf(section);
        section.Query = WebLyrics.Bare(node.Name);
    }

    /// <summary>One file off its row. The selection is left alone.</summary>
    private void DownloadRow(RowVm row) =>
        _ = Download.StartAsync([new DownloadFile(row.Node.Path, row.Node.Size)], row.Node.Size);

    public void SetSelected(CatalogNode node, bool selected)
    {
        Catalog.Select(node, selected);
        NotifySelection();
    }

    public void CopyText(string text) => _ = _dialogs.CopyTextAsync(text);

    private int _lyricsRequest;

    public async void ViewLyrics(CatalogNode node)
    {
        var sheet = LyricsSheet;
        var request = ++_lyricsRequest;
        sheet.Title = node.DisplayName;
        sheet.Note = "";
        sheet.Words = "";
        sheet.IsLoading = true;
        sheet.IsOpen = true;
        // An old copy now beats a minute of waiting; only the very first time is there nothing to show.
        var index = await Task.Run(_library.KnownLyrics);
        if (request != _lyricsRequest) return;
        if (index is null)
        {
            void OnProgress(object? _, System.ComponentModel.PropertyChangedEventArgs e)
            {
                if (e.PropertyName == nameof(LyricsViewModel.LoadingText) && request == _lyricsRequest) sheet.Note = Lyrics.LoadingText;
            }
            Lyrics.PropertyChanged += OnProgress;
            try { await Lyrics.LoadAsync(false); }
            finally { Lyrics.PropertyChanged -= OnProgress; }
            if (request != _lyricsRequest) return;
            index = _library.Lyrics;
        }
        var match = index is null ? null : await Task.Run(() => index.Find(node.Path));
        if (request != _lyricsRequest) return;
        sheet.IsLoading = false;
        sheet.Note = "";
        if (match is null)
        {
            sheet.Note = Lyrics.Failure ?? Loc["lyrics.view.none"];
            return;
        }
        var words = string.IsNullOrWhiteSpace(match.Song.Lyrics) ? match.Song.SyncedLyrics : match.Song.Lyrics;
        if (string.IsNullOrWhiteSpace(words)) sheet.Note = Loc["lyrics.view.none"];
        else
        {
            if (match.Fit == LyricsFit.OtherRecording) sheet.Note = Loc["lyrics.view.other"];
            sheet.Words = words;
        }
    }

    [RelayCommand]
    private void OpenUrl(string url) => _ = Task.Run(() => Platform.Open(url));

    [RelayCommand]
    private void OpenFolder(string path) => _ = Task.Run(() =>
    {
        try { Directory.CreateDirectory(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
        Platform.Open(path);
    });

    private void SaveSettings() => SettingsStore.Save(_settings);
}
