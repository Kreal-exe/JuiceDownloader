using System.Windows.Input;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using JuiceDownloader.Controls;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using Material.Icons;

namespace JuiceDownloader.ViewModels;

/// <summary>One catalog section: its line on the Overview, and the page with its list of folders and files.</summary>
public sealed partial class SectionViewModel : ObservableObject, ISegment
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly Action _selectionChanged;
    private readonly PlayerViewModel _player;
    private readonly PreviewViewModel _preview;
    private readonly Action<RowVm> _download;
    private readonly DispatcherTimer _searchDelay;
    private CatalogSection? _section;
    private LibraryRows? _library;
    private bool _built;
    private bool _quiet;

    public SectionViewModel(string id, MaterialIconKind glyph, Color color, Action selectionChanged, PlayerViewModel player, PreviewViewModel preview, Action<RowVm> download)
    {
        _download = download;
        Id = id;
        Glyph = glyph;
        Brush = new ImmutableSolidColorBrush(color);
        SoftBrush = new ImmutableSolidColorBrush(color, 0.16);
        _selectionChanged = selectionChanged;
        _player = player;
        _preview = preview;
        _searchDelay = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(160) };
        _searchDelay.Tick += (_, _) =>
        {
            _searchDelay.Stop();
            if (_library is null) return;
            _library.Query = Query;
            RebuildRows();
            Searched?.Invoke();
        };
    }

    /// <summary>A new search has replaced the list: the view goes back to its top.</summary>
    public event Action? Searched;

    /// <summary>A row was asked for from elsewhere: the view scrolls to it and flashes it.</summary>
    public event Action<RowVm>? Revealed;

    public string Id { get; }
    public MaterialIconKind Glyph { get; }
    public IBrush Brush { get; }
    public IBrush SoftBrush { get; }
    public string Title => Loc["nav." + Id];
    public string Description => Loc["section." + Id + ".desc"];

    public RangeCollection<RowVm> Rows { get; } = [];

    /// <summary>The row under the pointer now, and the one last clicked: what Space means, as in Quick Look.</summary>
    public RowVm? HoveredRow { get; set; }
    public RowVm? LastRow { get; private set; }
    public bool IsEmpty => _section is not null && _built && Rows.Count == 0;

    [ObservableProperty] private string _query = "";

    public bool IsSearching => !string.IsNullOrWhiteSpace(Query);
    /// <summary>What the Overview's search says above its list.</summary>
    public string ResultsText => Loc.Format("overview.search.results", ByteFormatter.FormatCount(Rows.Count(r => r.Depth == 0)));

    partial void OnQueryChanged(string value)
    {
        OnPropertyChanged(nameof(IsSearching));
        if (_quiet) return;
        _searchDelay.Stop();
        _searchDelay.Start();
    }

    /// <summary>Selected bytes: what the Overview's segment bar draws.</summary>
    public long Bytes => _section?.SelectedBytes ?? 0;
    public long Size => _section?.Size ?? 0;
    public int FileCount => _section?.FileCount ?? 0;
    public int SelectedFiles => _section?.SelectedFiles ?? 0;
    public bool HasFiles => FileCount > 0;
    public bool? IsChecked => SelectedFiles == 0 ? false : SelectedFiles >= FileCount ? true : null;
    public string SizeText => ByteFormatter.Format(Size);
    private int Have => DiskState.Current?.FilesInSection(Id) ?? 0;
    public string FilesText => Have > 0
        ? Loc.Format("overview.sectionHave", ByteFormatter.FormatCount(FileCount), ByteFormatter.FormatCount(Have))
        : Loc.Format("library.folderLine", ByteFormatter.FormatCount(FileCount));
    public string Subtitle
    {
        get
        {
            var text = Loc.Format("library.subtitle", ByteFormatter.FormatCount(FileCount), ByteFormatter.Format(Size), ByteFormatter.Format(Bytes));
            return Have > 0 ? $"{text} · {Loc.Format("library.have", ByteFormatter.FormatCount(Have))}" : text;
        }
    }

    public void OnDiskChanged()
    {
        OnPropertyChanged(nameof(FilesText));
        OnPropertyChanged(nameof(Subtitle));
    }

    /// <summary>Takes a new catalog's section; what was open stays open.</summary>
    public void Bind(CatalogSection section)
    {
        var open = Rows.Where(r => r.Expanded).Select(r => r.Node.Path).ToHashSet(StringComparer.Ordinal);
        _section = section;
        _library = new LibraryRows(section) { Query = Query };
        for (var changed = open.Count > 0; changed;)
        {
            changed = false;
            foreach (var row in _library.Rows())
                if (!row.Expanded && open.Contains(row.Node.Path))
                {
                    _library.Toggle(row.Node);
                    changed = true;
                }
        }
        if (_built) RebuildRows();
        Refresh();
    }

    /// <summary>The rows are made when the page is first opened: most sessions never see most sections.</summary>
    public void EnsureRows()
    {
        if (!_built && _library is not null) RebuildRows();
        RefreshRows();
    }

    private void RebuildRows()
    {
        _built = true;
        Rows.ReplaceAll(_library!.Rows().Select(Wrap));
        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(ResultsText));
    }

    private RowVm Wrap(LibraryRow row) => new(row, Check, Open, _player, _preview, _download, !string.IsNullOrWhiteSpace(_library?.Query));

    /// <summary>Clears the search, opens the way down to a file or folder and points the view at it.</summary>
    public void Reveal(CatalogNode node)
    {
        if (_library is null) return;
        _searchDelay.Stop();
        _quiet = true;
        Query = "";
        _quiet = false;
        _library.Reveal(node);
        RebuildRows();
        if (Rows.FirstOrDefault(r => ReferenceEquals(r.Node, node)) is { } row) Revealed?.Invoke(row);
    }

    private void Check(RowVm row)
    {
        LastRow = row;
        Catalog.Select(row.Node, row.Node.SelectedFiles < row.Node.FileCount);
        _selectionChanged();
    }

    private void Open(RowVm row)
    {
        LastRow = row;
        if (_library is null || !_library.Toggle(row.Node)) return;
        var index = Rows.IndexOf(row);
        var fresh = _library.Rows();
        var delta = fresh.Count - Rows.Count;
        row.Expanded = !row.Expanded;
        if (delta > 0) Rows.InsertRange(index + 1, fresh.GetRange(index + 1, delta).Select(Wrap).ToList());
        else Rows.RemoveRange(index + 1, -delta);
    }

    /// <summary>A click on a line of the Overview's list: the whole section, in one go.</summary>
    [RelayCommand]
    private void ToggleAll() => SetAll(SelectedFiles < FileCount);

    [RelayCommand]
    private void SelectAll() => SetListed(true);

    [RelayCommand]
    private void SelectNone() => SetListed(false);

    public void SetAll(bool selected)
    {
        if (_section is null) return;
        foreach (var node in _section.Rows) Catalog.Select(node, selected);
        _selectionChanged();
    }

    // While searching, All and None mean what the search lists.
    private void SetListed(bool selected)
    {
        if (string.IsNullOrWhiteSpace(Query)) { SetAll(selected); return; }
        foreach (var row in Rows)
            if (row.Depth == 0) Catalog.Select(row.Node, selected);
        _selectionChanged();
    }

    public void Refresh()
    {
        OnPropertyChanged(nameof(Bytes));
        OnPropertyChanged(nameof(IsChecked));
        OnPropertyChanged(nameof(Subtitle));
    }

    public void RefreshRows()
    {
        // Rows out of view have no listeners, so this costs a comparison each.
        foreach (var row in Rows) row.Refresh();
    }

    /// <summary>Rows out of view have no listeners here either.</summary>
    public void RefreshPlaying()
    {
        foreach (var row in Rows) row.RefreshPlaying();
    }

    public void OnCatalogChanged()
    {
        OnPropertyChanged(nameof(Size));
        OnPropertyChanged(nameof(SizeText));
        OnPropertyChanged(nameof(FileCount));
        OnPropertyChanged(nameof(FilesText));
        OnPropertyChanged(nameof(HasFiles));
        OnPropertyChanged(nameof(IsEmpty));
    }

    public void OnLanguageChanged()
    {
        OnPropertyChanged(string.Empty);
        foreach (var row in Rows) row.OnLanguageChanged();
    }
}

/// <summary>A line of a section's list.</summary>
public sealed class RowVm : ObservableObject
{
    private static readonly string[] Video = [".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v", ".wmv", ".flv", ".mpg", ".mpeg"];
    private static readonly string[] Image = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".svg", ".psd"];
    private static readonly string[] Archive = [".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz"];

    private readonly Action<RowVm> _check;
    private readonly Action<RowVm> _open;
    private ICommand? _checkCommand;
    private ICommand? _openCommand;
    private ICommand? _clickCommand;
    private ICommand? _playCommand;
    private readonly PlayerViewModel _player;
    private readonly PreviewViewModel _preview;
    private readonly Action<RowVm> _download;
    private ICommand? _previewCommand;
    private ICommand? _downloadCommand;
    private bool _isCurrent;
    private bool _isPlaying;
    private int _shownSelected;
    private bool _expanded;

    public RowVm(LibraryRow row, Action<RowVm> check, Action<RowVm> open, PlayerViewModel player, PreviewViewModel preview, Action<RowVm> download, bool inSearch)
    {
        _download = download;
        Node = row.Node;
        Depth = row.Depth;
        _expanded = row.Expanded;
        _check = check;
        _open = open;
        _shownSelected = Node.SelectedFiles;
        _player = player;
        _preview = preview;
        HasPreview = !Node.IsDirectory && Library.PreviewOf(Node.Name) != PreviewKind.None;
        HasPlace = inSearch && row.Depth == 0;
        IsPlayable = !Node.IsDirectory && Library.IsPlayable(Node.Name);
        (_isCurrent, _isPlaying) = PlayingState();
    }

    public bool IsPlayable { get; }
    /// <summary>A search result says where it was found; a row inside an opened folder has its place on the screen.</summary>
    public bool HasPlace { get; }
    public string Place => HasPlace ? CatalogRelations.Place(Node) : "";
    /// <summary>The track in the player, playing or paused: its name is in the accent colour and its button stays.</summary>
    public bool IsCurrent => _isCurrent;
    public bool IsPlayingNow => _isPlaying;
    public bool IsFile => !Node.IsDirectory;
    public ICommand DownloadCommand => _downloadCommand ??= new RelayCommand(() => _download(this));
    public ICommand PlayCommand => _playCommand ??= new RelayCommand(Play);

    public void Play()
    {
        if (IsPlayable) _player.Toggle(Node);
    }

    public bool HasPreview { get; }
    public ICommand PreviewCommand => _previewCommand ??= new RelayCommand(ShowPreview);

    public void ShowPreview()
    {
        if (HasPreview) _preview.Open(Node);
    }

    private (bool Current, bool Playing) PlayingState()
    {
        var current = _player.Current?.Path == Node.Path;
        return (current, current && _player.IsPlaying);
    }

    public void RefreshPlaying()
    {
        var (current, playing) = PlayingState();
        if (current != _isCurrent) { _isCurrent = current; OnPropertyChanged(nameof(IsCurrent)); }
        if (playing != _isPlaying) { _isPlaying = playing; OnPropertyChanged(nameof(IsPlayingNow)); }
    }

    public CatalogNode Node { get; }
    public int Depth { get; }
    public bool IsTop => Depth == 0;
    public bool IsFolder => Node.IsDirectory;
    public string Name => !Node.IsDirectory && LyricsIndex.Current?.LengthOf(Node.Path) is { } length ? $"{Node.DisplayName}  ·  {length}" : Node.DisplayName;
    public Thickness Indent => new(Depth * 24, 0, 0, IsTop ? 10 : 2);
    public string SizeText => (DiskState.Current?.Has(Node.Path) == true ? "✓ " : "") + ByteFormatter.Format(Node.Size);
    public string Line => LocalizationManager.Instance.Format("library.folderLine", ByteFormatter.FormatCount(Node.FileCount));
    public bool HasFiles => Node.FileCount > 0;
    public bool? IsChecked => Node.SelectedFiles == 0 ? false : Node.SelectedFiles >= Node.FileCount ? true : null;

    public bool Expanded
    {
        get => _expanded;
        set => SetProperty(ref _expanded, value);
    }

    public MaterialIconKind Glyph
    {
        get
        {
            if (Node.IsDirectory) return MaterialIconKind.FolderOutline;
            var extension = Path.GetExtension(Node.Name).ToLowerInvariant();
            if (Library.AudioExtensions.Contains(extension)) return MaterialIconKind.MusicNoteOutline;
            if (Video.Contains(extension)) return MaterialIconKind.VideoOutline;
            if (Image.Contains(extension)) return MaterialIconKind.ImageOutline;
            if (Archive.Contains(extension)) return MaterialIconKind.ArchiveOutline;
            return MaterialIconKind.FileOutline;
        }
    }

    public ICommand CheckCommand => _checkCommand ??= new RelayCommand(() => _check(this));
    public ICommand OpenCommand => _openCommand ??= new RelayCommand(() => _open(this));
    /// <summary>The row itself: a folder opens, a file is ticked.</summary>
    public ICommand ClickCommand => _clickCommand ??= new RelayCommand(() => { if (IsFolder) _open(this); else _check(this); });

    public void Refresh()
    {
        if (_shownSelected == Node.SelectedFiles) return;
        _shownSelected = Node.SelectedFiles;
        OnPropertyChanged(nameof(IsChecked));
    }

    public void OnLanguageChanged() => OnPropertyChanged(nameof(Line));
}
