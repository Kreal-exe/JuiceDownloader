using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

/// <summary>A row a right click can ask about.</summary>
public interface IRowNode
{
    CatalogNode Node { get; }
}

/// <summary>One line of a section page. The list is virtualized, so only the lines on screen have anyone listening.</summary>
public sealed class LibraryRowVm : ObservableObject, IRowNode
{
    private static readonly HashSet<string> Video = [".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v", ".wmv"];
    private static readonly HashSet<string> Image = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".tif", ".tiff", ".bmp", ".svg"];
    private static readonly HashSet<string> Archive = [".zip", ".rar", ".7z", ".tar", ".gz", ".ptx"];

    private static readonly RowLook FolderLook = new("", Color.FromRgb(0x7C, 0x6C, 0xFF));
    private static readonly RowLook AudioLook = new("", Color.FromRgb(0x22, 0xD3, 0xEE));
    private static readonly RowLook VideoLook = new("", Color.FromRgb(0xF4, 0x72, 0xB6));
    private static readonly RowLook ImageLook = new("", Color.FromRgb(0x34, 0xD3, 0x99));
    private static readonly RowLook ArchiveLook = new("", Color.FromRgb(0xF5, 0x9E, 0x0B));
    private static readonly RowLook OtherLook = new("", Color.FromRgb(0x8E, 0x96, 0xAB));

    private readonly RowLook _look;
    private readonly PlayerViewModel _player;
    private bool? _checkState;
    private bool _isCurrent;
    private bool _isPlaying;
    private bool _isFlashing;
    private readonly bool _showPlace;

    public LibraryRowVm(LibraryRow row, PlayerViewModel player, bool showPlace)
    {
        _showPlace = showPlace;
        Node = row.Node;
        Depth = row.Depth;
        IsExpanded = row.Expanded;
        _player = player;
        IsPlayable = !row.Node.IsDirectory && Library.IsPlayable(row.Node.Name);
        CanPreview = !row.Node.IsDirectory && Library.PreviewOf(row.Node.Name) != PreviewKind.None;
        _isCurrent = IsPlayable && row.Node.Path == player.CurrentPath;
        _isPlaying = _isCurrent && player.IsPlaying;
        _look = LookOf(row.Node);
        _checkState = StateOf(row.Node);
    }

    public CatalogNode Node { get; }
    public int Depth { get; }
    public bool IsExpanded { get; }
    public bool IsTop => Depth == 0;
    public bool IsFolder => Node.IsDirectory;
    public bool IsPlayable { get; }
    public bool CanPreview { get; }
    /// <summary>The round button of the row: play for audio, an eye for what can be looked at.</summary>
    public bool HasAction => IsPlayable || CanPreview;
    public string ActionTip => LocalizationManager.Instance[CanPreview ? "preview.open" : "player.playable"];
    /// <summary>The track in the player, playing or paused. Goes by path: a refreshed catalog has new nodes for the same files.</summary>
    public bool IsCurrent => _isCurrent;
    public string PlayGlyph => CanPreview ? "\uE7B3" : _isPlaying ? "\uE769" : "\uE768";
    public string Name => !Node.IsDirectory && LyricsIndex.Current?.LengthOf(Node.Path) is { } length ? $"{Node.DisplayName}  ·  {length}" : Node.DisplayName;
    public string Path => Node.Path;
    public string SizeText => (DiskState.Current?.Has(Node.Path) == true ? "✓ " : "") + ByteFormatter.Format(Node.Size);
    public string Line
    {
        get
        {
            var files = Node.IsDirectory ? LocalizationManager.Instance.Format("library.folderLine", ByteFormatter.FormatCount(Node.FileCount)) : string.Empty;
            if (!_showPlace) return files;
            var place = CatalogRelations.Place(Node);
            return files.Length > 0 ? files + " · " + place : place;
        }
    }

    /// <summary>Set for a moment when "Show in its folder" lands on this row.</summary>
    public bool IsFlashing => _isFlashing;

    public async void Flash()
    {
        _isFlashing = true;
        OnPropertyChanged(nameof(IsFlashing));
        await Task.Delay(1500);
        _isFlashing = false;
        OnPropertyChanged(nameof(IsFlashing));
    }
    public string Glyph => _look.Glyph;
    public Brush KindBrush => _look.Brush;
    public Brush KindSoftBrush => _look.SoftBrush;
    public string ChevronGlyph => IsExpanded ? "" : "";
    public Thickness Indent => new(Depth * 24, 0, 0, 0);

    /// <summary>Ticked when all its files are selected, empty when none are, in between when some are.</summary>
    public bool? CheckState => _checkState;

    public void RefreshSelection()
    {
        var state = StateOf(Node);
        if (state == _checkState) return;
        _checkState = state;
        OnPropertyChanged(nameof(CheckState));
    }

    public void RefreshPlaying()
    {
        if (!IsPlayable) return;
        var current = Node.Path == _player.CurrentPath;
        var playing = current && _player.IsPlaying;
        if (current != _isCurrent)
        {
            _isCurrent = current;
            OnPropertyChanged(nameof(IsCurrent));
        }
        if (playing != _isPlaying)
        {
            _isPlaying = playing;
            OnPropertyChanged(nameof(PlayGlyph));
        }
    }

    public static bool? StateOf(int selected, int total) => selected == 0 ? false : selected >= total ? true : null;

    private static bool? StateOf(CatalogNode node) => StateOf(node.SelectedFiles, node.FileCount);

    private static RowLook LookOf(CatalogNode node)
    {
        if (node.IsDirectory) return FolderLook;
        var extension = System.IO.Path.GetExtension(node.Name).ToLowerInvariant();
        if (Library.IsAudio(node.Name)) return AudioLook;
        if (Video.Contains(extension)) return VideoLook;
        if (Image.Contains(extension)) return ImageLook;
        return Archive.Contains(extension) ? ArchiveLook : OtherLook;
    }

    private sealed class RowLook
    {
        public RowLook(string glyph, Color color)
        {
            Glyph = glyph;
            Brush = Frozen(color, 1);
            SoftBrush = Frozen(color, 0.16);
        }

        public string Glyph { get; }
        public Brush Brush { get; }
        public Brush SoftBrush { get; }

        private static Brush Frozen(Color color, double opacity)
        {
            var brush = new SolidColorBrush(color) { Opacity = opacity };
            brush.Freeze();
            return brush;
        }
    }
}

/// <summary>A catalog section: its line on the Overview and its page. It outlives the catalog, which a refresh replaces.</summary>
public sealed partial class SectionViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly HashSet<string> _open = new(StringComparer.Ordinal);
    private readonly DispatcherTimer _searchDelay;
    private CatalogSection? _section;
    private LibraryRows? _source;

    public SectionViewModel(string id, MainViewModel owner)
    {
        Id = id;
        Owner = owner;
        Page = Enum.TryParse<AppPage>(id, ignoreCase: true, out var page) ? page : AppPage.Overview;

        _searchDelay = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
        _searchDelay.Tick += (_, _) =>
        {
            _searchDelay.Stop();
            Rebuild(keepScroll: false);
        };

        Loc.LanguageChanged += (_, _) =>
        {
            Rebuild(keepScroll: true);
            OnPropertyChanged(string.Empty);
        };
    }

    public string Id { get; }
    public AppPage Page { get; }
    public MainViewModel Owner { get; }

    public string Title => Loc["nav." + Id];
    public string Description => Loc["section." + Id + ".desc"];
    public string Glyph => GlyphOf(Id);
    public Brush Brush => Application.Current?.TryFindResource("Brush.Cat." + Id) as Brush ?? Brushes.Gray;
    public Brush SoftBrush => Application.Current?.TryFindResource("Brush.Cat." + Id + ".Soft") as Brush ?? Brushes.Transparent;

    [ObservableProperty] private string _query = string.Empty;
    [ObservableProperty] private IReadOnlyList<LibraryRowVm> _rows = [];
    [ObservableProperty] private long _size;
    [ObservableProperty] private int _fileCount;
    [ObservableProperty] private long _selectedBytes;
    [ObservableProperty] private int _selectedFiles;
    [ObservableProperty] private bool? _checkState = false;

    /// <summary>Read by the view when <see cref="Rows"/> is replaced: a folder opening keeps the list where it is, a new search starts at the top.</summary>
    public bool KeepScroll { get; private set; }

    private int Have => DiskState.Current?.FilesInSection(Id) ?? 0;
    public string FilesText => Have > 0
        ? Loc.Format("overview.sectionHave", ByteFormatter.FormatCount(FileCount), ByteFormatter.FormatCount(Have))
        : Loc.Format("library.folderLine", ByteFormatter.FormatCount(FileCount));
    public string Subtitle
    {
        get
        {
            var text = Loc.Format("library.subtitle", ByteFormatter.FormatCount(FileCount), ByteFormatter.Format(Size), ByteFormatter.Format(SelectedBytes));
            return Have > 0 ? $"{text} · {Loc.Format("library.have", ByteFormatter.FormatCount(Have))}" : text;
        }
    }

    public void OnDiskChanged()
    {
        OnPropertyChanged(nameof(FilesText));
        OnPropertyChanged(nameof(Subtitle));
    }

    public bool ShowNoResults => Rows.Count == 0 && Query.Trim().Length > 0;
    /// <summary>What the Overview's search says above its list.</summary>
    public string ResultsText => Loc.Format("overview.search.results", ByteFormatter.FormatCount(Rows.Count(r => r.Depth == 0)));

    partial void OnQueryChanged(string value)
    {
        OnPropertyChanged(nameof(IsSearching));
        _searchDelay.Stop();
        _searchDelay.Start();
    }

    partial void OnRowsChanged(IReadOnlyList<LibraryRowVm> value)
    {
        OnPropertyChanged(nameof(ShowNoResults));
        OnPropertyChanged(nameof(ResultsText));
    }
    partial void OnSizeChanged(long value) => OnPropertyChanged(nameof(Subtitle));
    partial void OnSelectedBytesChanged(long value) => OnPropertyChanged(nameof(Subtitle));
    partial void OnFileCountChanged(int value)
    {
        OnPropertyChanged(nameof(Subtitle));
        OnPropertyChanged(nameof(FilesText));
    }

    /// <summary>Takes up a section of a new catalog, with the same folders open.</summary>
    public void Attach(CatalogSection section)
    {
        _section = section;
        _source = new LibraryRows(section);
        foreach (var row in section.Rows) Reopen(row);
        Size = section.Size;
        FileCount = section.FileCount;
        Rebuild(keepScroll: true);
        RefreshSelection();
    }

    private void Reopen(CatalogNode node)
    {
        if (!node.IsDirectory || !_open.Contains(node.Path)) return;
        _source!.Toggle(node);
        foreach (var child in node.Children) Reopen(child);
    }

    /// <summary>Asks the view to scroll to a row, after "Show in its folder".</summary>
    public event Action<LibraryRowVm>? RevealRequested;

    public bool IsSearching => Query.Trim().Length > 0;

    public bool Holds(CatalogNode node)
    {
        if (_section is not { } section) return false;
        for (var n = node; n is not null; n = n.Parent)
            if (section.Rows.Any(r => r.Path == n.Path)) return true;
        return false;
    }

    /// <summary>Clears the search, opens the folders down to the node, and points at it.</summary>
    public void Reveal(CatalogNode node)
    {
        if (_source is not { } source) return;
        source.Reveal(node);
        for (var n = node.Parent; n is { Name.Length: > 0 }; n = n.Parent) _open.Add(n.Path);
        Query = string.Empty;
        _searchDelay.Stop();
        Rebuild(keepScroll: true);
        if (Rows.FirstOrDefault(r => r.Path == node.Path) is not { } row) return;
        row.Flash();
        RevealRequested?.Invoke(row);
    }

    public void RefreshSelection()
    {
        if (_section is not { } section) return;
        SelectedBytes = section.SelectedBytes;
        SelectedFiles = section.SelectedFiles;
        CheckState = LibraryRowVm.StateOf(SelectedFiles, FileCount);
        foreach (var row in Rows) row.RefreshSelection();
    }

    private void Rebuild(bool keepScroll)
    {
        if (_source is not { } source) return;
        source.Query = Query;
        var rows = source.Rows();
        var vms = new List<LibraryRowVm>(rows.Count);
        var searching = Query.Trim().Length > 0;
        foreach (var row in rows) vms.Add(new LibraryRowVm(row, Owner.Player, searching));
        KeepScroll = keepScroll;
        Rows = vms;
    }

    // ── what the Overview's checkbox and the page's buttons do ──

    [RelayCommand]
    private void Toggle()
    {
        if (_section is not { } section) return;
        Owner.ChangeSelection(() =>
        {
            var on = section.SelectedFiles < section.FileCount;
            foreach (var row in section.Rows) Catalog.Select(row, on);
        });
    }

    [RelayCommand]
    private void SelectAll() => SelectListed(true);

    [RelayCommand]
    private void SelectNone() => SelectListed(false);

    /// <summary>A search narrows what All and None apply to, to what it lists.</summary>
    private void SelectListed(bool on)
    {
        if (_section is not { } section) return;
        var nodes = Query.Trim().Length > 0 ? Rows.Where(r => r.Depth == 0).Select(r => r.Node).ToList() : section.Rows;
        Owner.ChangeSelection(() =>
        {
            foreach (var node in nodes) Catalog.Select(node, on);
        });
    }

    // The parameters are plain objects: a recycled container may hand over something else for a moment, and a typed
    // command would throw for it.

    [RelayCommand]
    private void ToggleRow(object? parameter)
    {
        if (parameter is not LibraryRowVm row) return;
        var node = row.Node;
        Owner.ChangeSelection(() => Catalog.Select(node, node.SelectedFiles < node.FileCount));
    }

    [RelayCommand]
    private void OpenRow(object? parameter)
    {
        if (parameter is not LibraryRowVm { IsFolder: true } row || _source is not { } source) return;
        if (!_open.Add(row.Path)) _open.Remove(row.Path);
        source.Toggle(row.Node);
        Rebuild(keepScroll: true);
    }

    /// <summary>A click on the body of a row opens a folder. A file only reacts to a double click, which plays it.</summary>
    [RelayCommand]
    private void ClickRow(object? parameter)
    {
        if (parameter is LibraryRowVm { IsFolder: true }) OpenRow(parameter);
        else if (parameter is LibraryRowVm row) Owner.LastClicked = row.Node;
    }

    [RelayCommand]
    private void PlayRow(object? parameter)
    {
        if (parameter is LibraryRowVm { CanPreview: true } look) _ = Owner.Preview.OpenAsync(look.Node);
        else if (parameter is LibraryRowVm { IsPlayable: true } row) Owner.Player.PlayOrToggle(row.Node);
    }

    /// <summary>The note on a row does what the round button does. A folder's icon stays part of the row.</summary>
    [RelayCommand]
    private void MarkRow(object? parameter)
    {
        if (parameter is LibraryRowVm { HasAction: true }) PlayRow(parameter);
        else ClickRow(parameter);
    }

    /// <summary>The second click of a double click on the note: it must not undo the first.</summary>
    [RelayCommand]
    private void IgnoreRow(object? parameter) { }

    /// <summary>One file off its row. The selection is left alone.</summary>
    [RelayCommand]
    private Task DownloadRow(object? parameter) =>
        parameter is LibraryRowVm { IsFolder: false } row
            ? Owner.Download.StartFilesAsync([new DownloadFile(row.Node.Path, row.Node.Size)])
            : Task.CompletedTask;

    public void RefreshPlaying()
    {
        foreach (var row in Rows) row.RefreshPlaying();
    }

    private static string GlyphOf(string id) => id switch
    {
        "albums" => "",
        "unreleased" => "",
        "compilations" => "",
        "sessionEdits" => "",
        "originals" => "",
        "studio" => "",
        "instrumentals" => "",
        "remixes" => "",
        "snippets" => "",
        _ => "",
    };
}
