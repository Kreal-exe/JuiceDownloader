using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;

namespace JuiceDownloader.ViewModels;

/// <summary>A line of the Missing Lyrics list; its state changes as the web search reaches it.</summary>
public sealed partial class GapVm(LyricsGap gap) : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    public LyricsGap Gap { get; } = gap;
    public string Name => Path.GetFileName(Gap.File);
    public string Folder => Path.GetDirectoryName(Gap.Relative) ?? "";
    public string KindText => Gap.Kind == LyricsGapKind.NoWords
        ? Loc["gaps.kind.none"]
        : string.IsNullOrEmpty(Gap.HasWordsOf) ? Loc["gaps.kind.other"] : $"{Loc["gaps.kind.other"]}: {Gap.HasWordsOf}";

    [ObservableProperty] private string _state = "";
    [ObservableProperty] private bool _isFound;
    public bool HasState => State.Length > 0;
    partial void OnStateChanged(string value) => OnPropertyChanged(nameof(HasState));
}

/// <summary>The Missing Lyrics page: which files of a folder lack their words, and a second opinion from the web.</summary>
public sealed partial class GapsViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly Library _library;
    private readonly LyricsViewModel _lyrics;
    private readonly SettingsViewModel _settings;
    private readonly IDialogService _dialogs;
    private readonly HttpClient _http;
    private CancellationTokenSource? _cts;
    private LyricsGapScan? _scan;
    private LyricsRunProgress? _scanProgress;
    private string? _chosenFolder;
    private int _searched, _found, _notFound, _searchTotal;
    private bool _searchEnded;

    public GapsViewModel(Library library, LyricsViewModel lyrics, SettingsViewModel settings, IDialogService dialogs, HttpClient http)
    {
        _library = library;
        _lyrics = lyrics;
        _settings = settings;
        _dialogs = dialogs;
        _http = http;
        _settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SettingsViewModel.Destination)) OnPropertyChanged(nameof(Folder));
        };
    }

    public RangeCollection<GapVm> Gaps { get; } = [];

    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private bool _isSearching;
    [ObservableProperty] private string? _failure;

    /// <summary>The download folder, until another one is chosen here.</summary>
    public string Folder => _chosenFolder ?? _settings.Destination;
    public bool IsBusy => IsScanning || IsSearching;
    public bool IsIdle => !IsBusy;
    public bool HasFailure => !string.IsNullOrEmpty(Failure);
    public bool HasScan => _scan is not null;
    public bool HasGaps => Gaps.Count > 0;
    public bool IsClean => _scan is not null && Gaps.Count == 0 && !IsScanning;
    public bool CanSearch => HasGaps && IsIdle;

    public string SummaryText => _scan is not { } s ? "" : Loc.Format("gaps.summary",
        ByteFormatter.FormatCount(s.Files), ByteFormatter.FormatCount(s.Fine),
        ByteFormatter.FormatCount(s.Gaps.Count(g => g.Kind == LyricsGapKind.NoWords)),
        ByteFormatter.FormatCount(s.Gaps.Count(g => g.Kind == LyricsGapKind.OtherRecording)));

    public string ScanningText => Loc.Format("gaps.scanning", ByteFormatter.FormatCount(_scanProgress?.Done ?? 0), ByteFormatter.FormatCount(_scanProgress?.Total ?? 0));
    public string SearchingText => Loc.Format("gaps.searching", ByteFormatter.FormatCount(_searched), ByteFormatter.FormatCount(_searchTotal));
    public string ResultText => _searchEnded ? Loc.Format("gaps.result", ByteFormatter.FormatCount(_found), ByteFormatter.FormatCount(_notFound)) : "";
    public bool HasResult => _searchEnded && !IsSearching;

    partial void OnIsScanningChanged(bool value) => RaiseStates();
    partial void OnIsSearchingChanged(bool value) => RaiseStates();
    partial void OnFailureChanged(string? value) => OnPropertyChanged(nameof(HasFailure));

    private void RaiseStates()
    {
        foreach (var name in new[] { nameof(IsBusy), nameof(IsIdle), nameof(HasScan), nameof(HasGaps), nameof(IsClean), nameof(CanSearch), nameof(HasResult), nameof(ResultText), nameof(SummaryText) })
            OnPropertyChanged(name);
    }

    [RelayCommand]
    private async Task ChangeFolder()
    {
        if (await _dialogs.PickFolderAsync(Loc["gaps.folder"]) is not { Length: > 0 } folder) return;
        _chosenFolder = folder;
        OnPropertyChanged(nameof(Folder));
    }

    [RelayCommand]
    private async Task Scan()
    {
        if (IsBusy) return;
        Failure = null;
        _scan = null;
        _searchEnded = false;
        _scanProgress = null;
        Gaps.ReplaceAll([]);
        OnPropertyChanged(nameof(ScanningText));
        IsScanning = true;
        _cts = new CancellationTokenSource();
        var folder = Folder;
        var options = _lyrics.Options;
        var progress = new Progress<LyricsRunProgress>(p =>
        {
            _scanProgress = p;
            OnPropertyChanged(nameof(ScanningText));
        });

        // One fetch of the songs, however many ask: the Lyrics page may be getting them already.
        await _lyrics.LoadAsync(false);
        try
        {
            if (!Directory.Exists(folder))
            {
                _scan = new LyricsGapScan(0, 0, []);
            }
            else
            {
                _scan = await Task.Run(() => _library.ScanForGapsAsync(folder, options, progress, _cts.Token));
                Gaps.ReplaceAll(_scan.Gaps.Select(g => new GapVm(g)));
            }
        }
        catch (OperationCanceledException)
        {
            _scan = null;
        }
        catch (Exception e) when (e is HttpRequestException or IOException or UnauthorizedAccessException or JsonException or InvalidDataException)
        {
            Failure = Loc.Format("lyrics.failed", e.Message);
        }

        _cts.Dispose();
        _cts = null;
        IsScanning = false;
    }

    [RelayCommand]
    private async Task Search()
    {
        if (IsBusy || Gaps.Count == 0) return;
        Failure = null;
        var rows = Gaps.ToDictionary(g => g.Gap.File, StringComparer.Ordinal);
        foreach (var row in rows.Values) { row.State = ""; row.IsFound = false; }
        _searched = _found = _notFound = 0;
        _searchTotal = rows.Count;
        _searchEnded = false;
        OnPropertyChanged(nameof(SearchingText));
        IsSearching = true;
        _cts = new CancellationTokenSource();
        var options = _lyrics.Options;
        var gaps = rows.Values.Select(r => r.Gap).ToList();
        var progress = new Progress<LyricsGapResult>(result =>
        {
            Show(rows[result.Gap.File], result);
            _searched++;
            OnPropertyChanged(nameof(SearchingText));
        });

        try
        {
            var web = new WebLyrics(_http);
            await Task.Run(() => _library.SearchWebAsync(gaps, web, options, progress, _cts.Token));
        }
        catch (OperationCanceledException)
        {
            // what was found stays written
        }
        catch (Exception e) when (e is HttpRequestException or IOException or UnauthorizedAccessException)
        {
            Failure = Loc.Format("gaps.failed", e.Message);
        }

        _cts.Dispose();
        _cts = null;
        _searchEnded = true;
        IsSearching = false;
    }

    private void Show(GapVm row, LyricsGapResult result)
    {
        if (result.Found.Match is { } match)
        {
            _found++;
            row.IsFound = true;
            row.State = Loc.Format(match.Fit == LyricsFit.SameRecording ? "gaps.found" : "gaps.foundOther", match.Source);
            return;
        }
        _notFound++;
        if (result.Found.Failed.Count > 0 && result.Found.Closest is null)
        {
            row.State = Loc.Format("gaps.failed", string.Join(", ", result.Found.Failed));
            return;
        }
        row.State = result.Found.Closest is { } closest
            ? $"{Loc["gaps.notFound"]} · {Loc.Format("gaps.closest", closest)}"
            : Loc["gaps.notFound"];
    }

    [RelayCommand]
    private void Stop() => _cts?.Cancel();

    public void OnLanguageChanged() => OnPropertyChanged(string.Empty);
}
