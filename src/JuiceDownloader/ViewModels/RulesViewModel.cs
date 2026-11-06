using System.Windows;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

public sealed partial class RuleSectionChip : ObservableObject
{
    private readonly Action _changed;

    public RuleSectionChip(string id, bool isOn, Action changed)
    {
        Id = id;
        _isOn = isOn;
        _changed = changed;
    }

    public string Id { get; }
    public string Title => LocalizationManager.Instance["nav." + Id];

    [ObservableProperty] private bool _isOn;

    partial void OnIsOnChanged(bool value) => _changed();

    public void RefreshLanguage() => OnPropertyChanged(nameof(Title));
}

/// <summary>A line of the rules list: a song, or one of the takes of an opened song.</summary>
public sealed class RuleRowVm : ObservableObject, IRowNode
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly PlayerViewModel _player;
    private bool _isCurrent;
    private bool _isPlaying;

    public RuleRowVm(SongGroup group, SongVersion? version, bool expanded, PlayerViewModel player)
    {
        Group = group;
        Version = version;
        IsExpanded = expanded;
        _player = player;
        _isCurrent = Node.Path == player.CurrentPath;
        _isPlaying = _isCurrent && player.IsPlaying;
    }

    public SongGroup Group { get; }
    public SongVersion? Version { get; }
    public bool IsExpanded { get; }
    public CatalogNode Node => Version?.File ?? Group.Picked.File;
    public bool IsSong => Version is null;
    public bool IsVersion => Version is not null;
    public bool IsPicked => Version is not null && ReferenceEquals(Version, Group.Picked);
    public bool HasManyVersions => IsSong && Group.Versions.Count > 1;
    public string Title => Version?.File.Name ?? Group.Title;
    public string Line => Version is { } v ? v.Why : Loc.Format("rules.picked", Group.Picked.File.Name);
    public string VersionsText => Loc.Format("rules.versions", ByteFormatter.FormatCount(Group.Versions.Count));
    public string SizeText => (DiskState.Current?.Has(Node.Path) == true ? "✓ " : "") + ByteFormatter.Format(Node.Size);
    public string ChevronGlyph => IsExpanded ? "" : "";
    public bool IsCurrent => _isCurrent;
    public string PlayGlyph => _isPlaying ? "" : "";
    public Thickness Indent => new(IsVersion ? 24 : 0, 0, 0, 0);

    public void RefreshPlaying()
    {
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
}

/// <summary>The By Rules page: says what it wants, and gets one file for each song.</summary>
public sealed partial class RulesViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly Library _library;
    private readonly AppSettings _settings;
    private readonly Action _save;
    private readonly DownloadViewModel _download;
    private readonly PlayerViewModel _player;
    private readonly HashSet<SongGroup> _open = [];

    private bool _visited;
    private CancellationTokenSource? _computing;
    private RuleResult? _result;
    private RuleOptions? _options;

    public RulesViewModel(Library library, AppSettings settings, Action save, DownloadViewModel download, PlayerViewModel player)
    {
        _library = library;
        _settings = settings;
        _save = save;
        _download = download;
        _player = player;

        _oneVersion = settings.RulesOneVersion;
        _skipReleased = settings.RulesSkipReleased;
        _skipUnfinished = settings.RulesSkipUnfinished;
        _oneFolder = settings.RulesOneFolder;
        Sections = Catalog.RuleSections.Select(id => new RuleSectionChip(id, settings.RulesSections.Contains(id), OnRulesChanged)).ToList();

        Loc.LanguageChanged += (_, _) =>
        {
            foreach (var chip in Sections) chip.RefreshLanguage();
            Rebuild();
            OnPropertyChanged(string.Empty);
        };
    }

    public IReadOnlyList<RuleSectionChip> Sections { get; }

    [RelayCommand]
    private void QuickUnreleased() => Quick(Catalog.UnreleasedSections.Contains);

    [RelayCommand]
    private void QuickReleased() => Quick(s => s == "albums");

    private void Quick(Func<string, bool> wanted)
    {
        foreach (var chip in Sections) chip.IsOn = wanted(chip.Id);
    }

    [ObservableProperty] private bool _oneVersion;
    [ObservableProperty] private bool _skipReleased;
    [ObservableProperty] private bool _skipUnfinished;
    [ObservableProperty] private bool _oneFolder;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string _errorText = string.Empty;
    [ObservableProperty] private IReadOnlyList<RuleRowVm> _rows = [];

    public string OneFolderDescription => Loc.Format("rules.oneFolder.desc", Loc["rules.folderName"]);
    private IReadOnlyList<DownloadFile> AllFiles => _result is { } r && _options is { } o ? SongRules.Files(r, o) : [];
    private List<DownloadFile> MissingFiles => AllFiles.Where(f => DiskState.Current?.Has(f.ApiPath) != true).ToList();
    public bool CanDownload => !IsLoading && MissingFiles.Count > 0;
    public string? DownloadList => SongRules.ListOf(MissingFiles);
    public string DownloadListTitle => Loc.Format("rules.downloadList", ByteFormatter.FormatCount(MissingFiles.Count), ByteFormatter.Format(MissingFiles.Sum(f => f.Size)));
    public string DownloadText
    {
        get
        {
            var all = AllFiles.Count;
            var missing = MissingFiles.Count;
            return all > 0 && missing == 0 ? Loc["rules.allThere"] : Loc.Format("rules.download", ByteFormatter.FormatCount(missing));
        }
    }
    public string SummaryText
    {
        get
        {
            if (_result is not { } r) return string.Empty;
            var text = Loc.Format("rules.summary", ByteFormatter.FormatCount(r.Kept.Count), ByteFormatter.Format(r.Bytes), ByteFormatter.FormatCount(r.FilesConsidered));
            var missing = MissingFiles;
            var have = AllFiles.Count - missing.Count;
            return have > 0 ? $"{text} · {Loc.Format("rules.onDisk", ByteFormatter.FormatCount(have), ByteFormatter.FormatCount(missing.Count), ByteFormatter.Format(missing.Sum(f => f.Size)))}" : text;
        }
    }

    public void OnDiskChanged()
    {
        RaiseResult();
        Rebuild();
    }

    public string SkippedText => _result is { } r
        ? Loc.Format("rules.skipped", ByteFormatter.FormatCount(r.SkippedVersions), ByteFormatter.FormatCount(r.SkippedReleased), ByteFormatter.FormatCount(r.SkippedUnfinished))
        : string.Empty;
    public string CopiesText => _result is { SkippedCopies: > 0 } r ? Loc.Format("rules.copies", ByteFormatter.FormatCount(r.SkippedCopies)) : string.Empty;

    partial void OnOneVersionChanged(bool value) => OnRulesChanged();
    partial void OnSkipReleasedChanged(bool value) => OnRulesChanged();
    partial void OnSkipUnfinishedChanged(bool value) => OnRulesChanged();
    partial void OnOneFolderChanged(bool value) => OnRulesChanged();
    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(CanDownload));

    private void OnRulesChanged()
    {
        _settings.RulesOneVersion = OneVersion;
        _settings.RulesSkipReleased = SkipReleased;
        _settings.RulesSkipUnfinished = SkipUnfinished;
        _settings.RulesOneFolder = OneFolder;
        _settings.RulesSections = Sections.Where(s => s.IsOn).Select(s => s.Id).ToList();
        _save();
        if (_visited) _ = ComputeAsync();
    }

    /// <summary>The rules read every song's words, so they wait until the page is first opened.</summary>
    public void PageOpened()
    {
        if (_visited) return;
        _visited = true;
        _ = ComputeAsync();
    }

    public void ResetToDefaults()
    {
        var defaults = AppSettings.RuleDefaults;
        OneVersion = defaults.OneVersion;
        SkipReleased = defaults.SkipReleased;
        SkipUnfinished = defaults.SkipUnfinished;
        OneFolder = defaults.OneFolder;
        foreach (var chip in Sections) chip.IsOn = defaults.Sections.Contains(chip.Id);
    }

    public void CatalogChanged()
    {
        if (_visited) _ = ComputeAsync();
    }

    private async Task ComputeAsync()
    {
        _computing?.Cancel();
        using var cts = new CancellationTokenSource();
        _computing = cts;

        var options = new RuleOptions
        {
            Sections = Sections.Where(s => s.IsOn).Select(s => s.Id).ToList(),
            OneVersion = OneVersion,
            SkipReleased = SkipReleased,
            SkipUnfinished = SkipUnfinished,
            NeverOffer = _settings.RulesNeverOffer,
            OneFolder = OneFolder,
            FolderName = Loc["rules.folderName"],
        };
        IsLoading = true;
        ErrorText = string.Empty;

        try
        {
            var result = await Task.Run(() => _library.ApplyRulesAsync(options, cts.Token));
            if (cts.IsCancellationRequested) return;
            _result = result;
            _options = options;
            _open.Clear();
            Rebuild();
        }
        catch (OperationCanceledException)
        {
            return; // a newer change took over
        }
        catch (Exception e)
        {
            ErrorText = Loc.Format("lyrics.failed", e.Message);
        }

        if (ReferenceEquals(_computing, cts))
        {
            _computing = null;
            IsLoading = false;
        }
        RaiseResult();
    }

    private void Rebuild()
    {
        if (_result is not { } result) return;
        var rows = new List<RuleRowVm>(result.Kept.Count);
        foreach (var group in result.Kept)
        {
            var open = _open.Contains(group);
            rows.Add(new RuleRowVm(group, null, open, _player));
            if (!open) continue;
            foreach (var version in group.Versions) rows.Add(new RuleRowVm(group, version, false, _player));
        }
        Rows = rows;
    }

    private void RaiseResult()
    {
        OnPropertyChanged(nameof(CanDownload));
        OnPropertyChanged(nameof(DownloadText));
        OnPropertyChanged(nameof(DownloadList));
        OnPropertyChanged(nameof(DownloadListTitle));
        OnPropertyChanged(nameof(SummaryText));
        OnPropertyChanged(nameof(SkippedText));
        OnPropertyChanged(nameof(CopiesText));
    }

    public void RefreshPlaying()
    {
        foreach (var row in Rows) row.RefreshPlaying();
    }

    [RelayCommand]
    private void ClickRow(object? parameter)
    {
        if (parameter is not RuleRowVm { HasManyVersions: true } row) return;
        if (!_open.Add(row.Group)) _open.Remove(row.Group);
        Rebuild();
    }

    [RelayCommand]
    private Task DownloadRow(object? parameter)
    {
        if (parameter is not RuleRowVm row || _options is not { } options) return Task.CompletedTask;
        var target = options.OneFolder ? options.FolderName + "/" + row.Node.Name : null;
        return _download.StartFilesAsync([new DownloadFile(row.Node.Path, row.Node.Size) { Target = target }]);
    }

    [RelayCommand]
    private void PlayRow(object? parameter)
    {
        if (parameter is RuleRowVm row) _player.PlayOrToggle(row.Node);
    }

    [RelayCommand]
    private void PickVersion(object? parameter)
    {
        if (parameter is not RuleRowVm { Version: { } version } row) return;
        row.Group.Picked = version;
        Rebuild();
        RaiseResult();
    }

    [RelayCommand]
    private Task DownloadAsync() =>
        _result is { } result && _options is { } options ? _download.StartFilesAsync(SongRules.Files(result, options)) : Task.CompletedTask;
}
