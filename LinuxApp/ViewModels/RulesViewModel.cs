using System.Text.Json;
using System.Windows.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Avalonia.Threading;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;

namespace JuiceDownloader.ViewModels;

public sealed partial class RuleSectionVm(string id, bool isOn, Action changed) : ObservableObject
{
    public string Id { get; } = id;
    public string Title => LocalizationManager.Instance["nav." + Id];
    [ObservableProperty] private bool _isOn = isOn;

    [RelayCommand]
    private void Toggle()
    {
        IsOn = !IsOn;
        changed();
    }

    public void OnLanguageChanged() => OnPropertyChanged(nameof(Title));
}

/// <summary>A line of the rules list: a song, or when it is opened one of its versions.</summary>
public sealed class RuleRowVm : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly PlayerViewModel _player;
    private readonly RulesViewModel _owner;
    private bool _expanded, _isCurrent, _isPlaying;

    public RuleRowVm(SongGroup group, SongVersion? version, RulesViewModel owner, PlayerViewModel player)
    {
        Group = group;
        Version = version;
        _owner = owner;
        _player = player;
        ClickCommand = new RelayCommand(() => { if (IsSong) owner.ToggleOpen(this); else owner.Pick(this); });
        OpenCommand = new RelayCommand(() => owner.ToggleOpen(this));
        PlayCommand = new RelayCommand(() => player.Toggle(Node));
        DownloadCommand = new RelayCommand(() => owner.DownloadOne(this));
        PickCommand = new RelayCommand(() => owner.Pick(this));
        RefreshPlaying();
    }

    public SongGroup Group { get; }
    public SongVersion? Version { get; }
    public bool IsSong => Version is null;
    public bool IsVersion => Version is not null;
    public bool IsTop => IsSong;
    public CatalogNode Node => (Version ?? Group.Picked).File;
    public string Title => IsSong ? Group.Title : Node.Name;
    public string Line => IsSong ? Loc.Format("rules.picked", Node.Name) : Version!.Why;
    public bool HasLine => Line.Length > 0;
    public string SizeText => (DiskState.Current?.Has(Node.Path) == true ? "✓ " : "") + ByteFormatter.Format(Node.Size);
    public void OnDiskChanged() => OnPropertyChanged(nameof(SizeText));
    public bool HasVersions => IsSong && Group.Versions.Count > 1;
    public string VersionsText => Loc.Format("rules.versions", Group.Versions.Count);
    public bool IsPicked => IsVersion && ReferenceEquals(Group.Picked, Version);
    public bool IsCurrent => _isCurrent;
    public bool IsPlayingNow => _isPlaying;
    public Avalonia.Thickness Indent => new(IsSong ? 0 : 24, 0, 0, IsSong ? 10 : 2);

    public bool Expanded
    {
        get => _expanded;
        set => SetProperty(ref _expanded, value);
    }

    public ICommand ClickCommand { get; }
    public ICommand OpenCommand { get; }
    public ICommand PlayCommand { get; }
    public ICommand DownloadCommand { get; }
    public ICommand PickCommand { get; }

    public void RefreshPlaying()
    {
        var current = _player.Current?.Path == Node.Path;
        var playing = current && _player.IsPlaying;
        if (current != _isCurrent) { _isCurrent = current; OnPropertyChanged(nameof(IsCurrent)); }
        if (playing != _isPlaying) { _isPlaying = playing; OnPropertyChanged(nameof(IsPlayingNow)); }
    }

    public void RefreshPicked()
    {
        OnPropertyChanged(nameof(IsPicked));
        OnPropertyChanged(nameof(Line));
        OnPropertyChanged(nameof(SizeText));
        RefreshPlaying();
    }

    public void OnLanguageChanged()
    {
        OnPropertyChanged(nameof(Line));
        OnPropertyChanged(nameof(VersionsText));
    }
}

/// <summary>The By Rules page: what a few rules keep of the catalog, one song to a line.</summary>
public sealed partial class RulesViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly Library _library;
    private readonly LyricsViewModel _lyrics;
    private readonly AppSettings _settings;
    private readonly Action _save;
    private readonly PlayerViewModel _player;
    private readonly DownloadViewModel _download;
    private readonly DispatcherTimer _delay;
    private CancellationTokenSource? _cts;
    private RuleResult? _result;
    private bool _wanted;

    public RulesViewModel(Library library, LyricsViewModel lyrics, AppSettings settings, Action save, PlayerViewModel player, DownloadViewModel download)
    {
        _library = library;
        _lyrics = lyrics;
        _settings = settings;
        _save = save;
        _player = player;
        _download = download;
        _oneVersion = settings.RulesOneVersion;
        _skipReleased = settings.RulesSkipReleased;
        _skipUnfinished = settings.RulesSkipUnfinished;
        _oneFolder = settings.RulesOneFolder;
        Sections = Catalog.RuleSections.Select(id => new RuleSectionVm(id, settings.RulesSections.Contains(id), Changed)).ToList();
        _delay = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        _delay.Tick += (_, _) => { _delay.Stop(); _ = RecomputeAsync(); };
        _player.StateChanged += () => { foreach (var row in Rows) row.RefreshPlaying(); };
    }

    public IReadOnlyList<RuleSectionVm> Sections { get; }

    [RelayCommand]
    private void QuickUnreleased() => Quick(Catalog.UnreleasedSections.Contains);

    [RelayCommand]
    private void QuickReleased() => Quick(s => s == "albums");

    private void Quick(Func<string, bool> wanted)
    {
        foreach (var chip in Sections) chip.IsOn = wanted(chip.Id);
        Changed();
    }
    public RangeCollection<RuleRowVm> Rows { get; } = [];

    [ObservableProperty] private bool _oneVersion;
    [ObservableProperty] private bool _skipReleased;
    [ObservableProperty] private bool _skipUnfinished;
    [ObservableProperty] private bool _oneFolder;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string? _failure;

    partial void OnOneVersionChanged(bool value) { _settings.RulesOneVersion = value; Changed(); }
    partial void OnSkipReleasedChanged(bool value) { _settings.RulesSkipReleased = value; Changed(); }
    partial void OnSkipUnfinishedChanged(bool value) { _settings.RulesSkipUnfinished = value; Changed(); }
    partial void OnOneFolderChanged(bool value) { _settings.RulesOneFolder = value; _save(); }
    partial void OnFailureChanged(string? value) => OnPropertyChanged(nameof(HasFailure));
    partial void OnIsLoadingChanged(bool value) => RaiseResult();

    public bool HasFailure => !string.IsNullOrEmpty(Failure);
    public bool HasResult => _result is not null && !IsLoading;
    private IReadOnlyList<DownloadFile> AllFiles => _result is { } r ? SongRules.Files(r, Options) : [];
    private List<DownloadFile> MissingFiles => AllFiles.Where(f => DiskState.Current?.Has(f.ApiPath) != true).ToList();
    public bool CanDownload => HasResult && MissingFiles.Count > 0;

    public void OnDiskChanged()
    {
        foreach (var name in new[] { nameof(CanDownload), nameof(SummaryText), nameof(DownloadText), nameof(DownloadList), nameof(DownloadListTitle) }) OnPropertyChanged(name);
        foreach (var row in Rows) row.OnDiskChanged();
    }

    public string OneFolderText => Loc.Format("rules.oneFolder.desc", Loc["rules.folderName"]);
    public string SummaryText
    {
        get
        {
            if (_result is not { } r) return "";
            var text = Loc.Format("rules.summary", ByteFormatter.FormatCount(r.Kept.Count), ByteFormatter.Format(r.Bytes), ByteFormatter.FormatCount(r.FilesConsidered));
            var missing = MissingFiles;
            var have = AllFiles.Count - missing.Count;
            return have > 0 ? $"{text} · {Loc.Format("rules.onDisk", ByteFormatter.FormatCount(have), ByteFormatter.FormatCount(missing.Count), ByteFormatter.Format(missing.Sum(f => f.Size)))}" : text;
        }
    }
    public string SkippedText
    {
        get
        {
            if (_result is not { } r) return "";
            var text = Loc.Format("rules.skipped", ByteFormatter.FormatCount(r.SkippedVersions), ByteFormatter.FormatCount(r.SkippedReleased), ByteFormatter.FormatCount(r.SkippedUnfinished));
            return r.SkippedCopies > 0 ? $"{text} · {Loc.Format("rules.copies", ByteFormatter.FormatCount(r.SkippedCopies))}" : text;
        }
    }
    public string? DownloadList => SongRules.ListOf(MissingFiles);
    public string DownloadListTitle => Loc.Format("rules.downloadList", ByteFormatter.FormatCount(MissingFiles.Count), ByteFormatter.Format(MissingFiles.Sum(f => f.Size)));
    public string DownloadText => AllFiles.Count > 0 && MissingFiles.Count == 0 ? Loc["rules.allThere"] : Loc.Format("rules.download", ByteFormatter.FormatCount(MissingFiles.Count));

    private RuleOptions Options => new()
    {
        Sections = Sections.Where(s => s.IsOn).Select(s => s.Id).ToList(),
        OneVersion = OneVersion,
        SkipReleased = SkipReleased,
        SkipUnfinished = SkipUnfinished,
        NeverOffer = _settings.RulesNeverOffer,
        OneFolder = OneFolder,
        FolderName = Loc["rules.folderName"],
    };

    private void RaiseResult()
    {
        foreach (var name in new[] { nameof(HasResult), nameof(CanDownload), nameof(SummaryText), nameof(SkippedText), nameof(DownloadText), nameof(DownloadList), nameof(DownloadListTitle) })
            OnPropertyChanged(name);
    }

    /// <summary>The page was opened: the first look reads the songs, which takes a moment.</summary>
    public void Open()
    {
        if (_wanted) return;
        _wanted = true;
        _ = RecomputeAsync();
    }

    /// <summary>A new catalog: if the page has been seen, what it lists is out of date.</summary>
    public void OnCatalogChanged()
    {
        if (_wanted) _ = RecomputeAsync();
    }

    private void Changed()
    {
        _settings.RulesSections = Sections.Where(s => s.IsOn).Select(s => s.Id).ToList();
        _save();
        if (!_wanted) return;
        _delay.Stop();
        _delay.Start();
    }

    private async Task RecomputeAsync()
    {
        _cts?.Cancel();
        var cts = _cts = new CancellationTokenSource();
        IsLoading = true;
        Failure = null;
        var options = Options;
        try
        {
            // One fetch of the songs, however many ask.
            await _lyrics.LoadAsync(false);
            cts.Token.ThrowIfCancellationRequested();
            var result = await Task.Run(() => _library.ApplyRulesAsync(options, cts.Token));
            if (cts.IsCancellationRequested) return;
            _result = result;
            Rows.ReplaceAll(result.Kept.Select(g => new RuleRowVm(g, null, this, _player)));
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception e) when (e is HttpRequestException or IOException or JsonException or InvalidDataException)
        {
            Failure = Loc.Format("lyrics.failed", e.Message);
        }
        if (ReferenceEquals(cts, _cts)) IsLoading = false;
    }

    public void ToggleOpen(RuleRowVm song)
    {
        if (!song.HasVersions) return;
        var index = Rows.IndexOf(song);
        if (song.Expanded) Rows.RemoveRange(index + 1, song.Group.Versions.Count);
        else Rows.InsertRange(index + 1, song.Group.Versions.Select(v => new RuleRowVm(song.Group, v, this, _player)).ToList());
        song.Expanded = !song.Expanded;
    }

    public void Pick(RuleRowVm version)
    {
        if (version.Version is not { } chosen) return;
        version.Group.Picked = chosen;
        foreach (var row in Rows.Where(r => ReferenceEquals(r.Group, version.Group))) row.RefreshPicked();
        RaiseResult();
    }

    public void DownloadOne(RuleRowVm row)
    {
        var options = Options;
        var target = options.OneFolder ? options.FolderName + "/" + row.Node.Name : null;
        _ = _download.StartAsync([new DownloadFile(row.Node.Path, row.Node.Size) { Target = target }], row.Node.Size);
    }

    [RelayCommand]
    private Task Download() => _result is { } r
        ? _download.StartAsync(SongRules.Files(r, Options), r.Bytes)
        : Task.CompletedTask;

    /// <summary>Back to what the engine's rules default to.</summary>
    public void Reset()
    {
        var defaults = new RuleOptions();
        OneVersion = defaults.OneVersion;
        SkipReleased = defaults.SkipReleased;
        SkipUnfinished = defaults.SkipUnfinished;
        OneFolder = defaults.OneFolder;
        foreach (var section in Sections) section.IsOn = defaults.Sections.Contains(section.Id);
        Changed();
    }

    public void OnLanguageChanged()
    {
        foreach (var s in Sections) s.OnLanguageChanged();
        foreach (var r in Rows) r.OnLanguageChanged();
        RaiseResult();
        OnPropertyChanged(nameof(OneFolderText));
    }
}

/// <summary>The words of one file, in a sheet over the window.</summary>
public sealed partial class LyricsSheetViewModel : ObservableObject
{
    [ObservableProperty] private bool _isOpen;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string _title = "";
    [ObservableProperty] private string _note = "";
    [ObservableProperty] private string _words = "";
    public bool HasNote => Note.Length > 0;
    partial void OnNoteChanged(string value) => OnPropertyChanged(nameof(HasNote));

    [RelayCommand]
    public void Close() => IsOpen = false;
}
