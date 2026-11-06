using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Windows.Threading;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

/// <summary>A line of the Missing Lyrics list: the file, what is wrong with it, and what the web said when asked.</summary>
public sealed class GapRowVm : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private LyricsGapResult? _result;

    public GapRowVm(LyricsGap gap) => Gap = gap;

    public LyricsGap Gap { get; }
    public string Name => Path.GetFileName(Gap.File);
    public string Folder => Path.GetDirectoryName(Gap.Relative)?.Replace('\\', '/') ?? string.Empty;

    public string KindText => Gap.Kind == LyricsGapKind.NoWords ? Loc["gaps.kind.none"]
        : Gap.HasWordsOf is { Length: > 0 } song ? Loc["gaps.kind.other"] + ": " + song
        : Loc["gaps.kind.other"];

    public bool IsFound => _result?.Found.Match is not null;

    public string StatusText
    {
        get
        {
            if (_result is not { } result) return string.Empty;
            if (result.Found.Match is { } match)
                return Loc.Format(match.Fit == LyricsFit.SameRecording ? "gaps.found" : "gaps.foundOther", match.Source);

            var parts = new List<string> { Loc["gaps.notFound"] };
            if (result.Found.Closest is { Length: > 0 } closest) parts.Add(Loc.Format("gaps.closest", closest));
            if (result.Found.Failed.Count > 0) parts.Add(Loc.Format("gaps.failed", string.Join(", ", result.Found.Failed)));
            return string.Join(" · ", parts);
        }
    }

    public void Show(LyricsGapResult result)
    {
        _result = result;
        OnPropertyChanged(nameof(IsFound));
        OnPropertyChanged(nameof(StatusText));
    }

    public void RefreshLanguage() => OnPropertyChanged(string.Empty);
}

/// <summary>The Missing Lyrics page: a check of a folder, then a search of the web for what the API does not have.</summary>
public sealed partial class GapsViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly Library _library;
    private readonly SettingsViewModel _settings;
    private readonly IDialogService _dialogs;
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private readonly WebLyrics _web;

    private bool _folderChosen;
    private CancellationTokenSource? _cts;
    private LyricsGapScan? _scan;
    private int _foundCount, _notFoundCount;

    public GapsViewModel(Library library, HttpClient http, SettingsViewModel settings, LyricsViewModel lyrics, IDialogService dialogs)
    {
        _library = library;
        _settings = settings;
        _dialogs = dialogs;
        _web = new WebLyrics(http);
        Lyrics = lyrics;
        _folder = settings.Destination;

        settings.PropertyChanged += OnSettingsChanged;
        Loc.LanguageChanged += (_, _) =>
        {
            foreach (var row in Rows) row.RefreshLanguage();
            OnPropertyChanged(string.Empty);
        };
    }

    public LyricsViewModel Lyrics { get; }

    [ObservableProperty] private string _folder;
    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private bool _isSearching;
    [ObservableProperty] private string _progressText = string.Empty;
    [ObservableProperty] private string _errorText = string.Empty;
    [ObservableProperty] private IReadOnlyList<GapRowVm> _rows = [];
    [ObservableProperty] private bool _hasResult;

    public bool IsBusy => IsScanning || IsSearching;
    public bool IsIdle => !IsBusy;
    public bool HasRows => Rows.Count > 0;
    public bool CanSearch => HasRows && !IsBusy;
    public bool IsClean => _scan is { Gaps.Count: 0 } && !IsBusy;
    public string SummaryText
    {
        get
        {
            if (_scan is not { } scan) return string.Empty;
            var none = scan.Gaps.Count(g => g.Kind == LyricsGapKind.NoWords);
            return Loc.Format("gaps.summary", ByteFormatter.FormatCount(scan.Files), ByteFormatter.FormatCount(scan.Fine),
                ByteFormatter.FormatCount(none), ByteFormatter.FormatCount(scan.Gaps.Count - none));
        }
    }
    public string ResultText => HasResult ? Loc.Format("gaps.result", ByteFormatter.FormatCount(_foundCount), ByteFormatter.FormatCount(_notFoundCount)) : string.Empty;

    partial void OnIsScanningChanged(bool value) => RaiseBusy();
    partial void OnIsSearchingChanged(bool value) => RaiseBusy();
    partial void OnRowsChanged(IReadOnlyList<GapRowVm> value)
    {
        OnPropertyChanged(nameof(HasRows));
        OnPropertyChanged(nameof(CanSearch));
    }
    partial void OnHasResultChanged(bool value) => OnPropertyChanged(nameof(ResultText));

    private void RaiseBusy()
    {
        OnPropertyChanged(nameof(IsBusy));
        OnPropertyChanged(nameof(IsIdle));
        OnPropertyChanged(nameof(CanSearch));
        OnPropertyChanged(nameof(IsClean));
    }

    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SettingsViewModel.Destination) && !_folderChosen) Folder = _settings.Destination;
    }

    [RelayCommand]
    private void ChangeFolder()
    {
        if (_dialogs.PickFolder(Folder) is not { Length: > 0 } folder) return;
        _folderChosen = true;
        Folder = folder;
    }

    [RelayCommand]
    private async Task ScanAsync()
    {
        if (IsBusy) return;

        using var cts = new CancellationTokenSource();
        _cts = cts;
        ErrorText = string.Empty;
        HasResult = false;
        ProgressText = Loc.Format("gaps.scanning", ByteFormatter.FormatCount(0), "…");
        IsScanning = true;

        var progress = new Latest<LyricsRunProgress>(_dispatcher, p =>
        {
            if (IsScanning) ProgressText = Loc.Format("gaps.scanning", ByteFormatter.FormatCount(p.Done), ByteFormatter.FormatCount(p.Total));
        });

        try
        {
            var folder = Folder;
            var options = Lyrics.Options;
            // A download folder that does not exist yet is simply one with nothing missing.
            var scan = Directory.Exists(folder)
                ? await Task.Run(() => _library.ScanForGapsAsync(folder, options, progress, cts.Token))
                : new LyricsGapScan(0, 0, []);
            _scan = scan;
            Rows = scan.Gaps.Select(g => new GapRowVm(g)).ToList();
        }
        catch (OperationCanceledException)
        {
            // stopped: what was written stays, and the last list with it
        }
        catch (Exception e)
        {
            ErrorText = Loc.Format("lyrics.failed", e.Message);
        }
        finally
        {
            _cts = null;
            IsScanning = false;
            OnPropertyChanged(nameof(SummaryText));
            Lyrics.RefreshStatus();
        }
    }

    [RelayCommand]
    private async Task SearchAsync()
    {
        if (IsBusy || Rows.Count == 0) return;

        using var cts = new CancellationTokenSource();
        _cts = cts;
        ErrorText = string.Empty;
        HasResult = false;
        _foundCount = _notFoundCount = 0;
        var rows = Rows;
        var total = rows.Count;
        var byFile = rows.ToDictionary(r => r.Gap.File, StringComparer.Ordinal);
        ProgressText = Loc.Format("gaps.searching", ByteFormatter.FormatCount(0), ByteFormatter.FormatCount(total));
        IsSearching = true;

        // Created here, so each result reaches the row it belongs to on this thread.
        var progress = new Progress<LyricsGapResult>(result =>
        {
            if (result.Found.Match is not null) _foundCount++;
            else _notFoundCount++;
            if (byFile.TryGetValue(result.Gap.File, out var row)) row.Show(result);
            ProgressText = Loc.Format("gaps.searching", ByteFormatter.FormatCount(_foundCount + _notFoundCount), ByteFormatter.FormatCount(total));
        });

        try
        {
            var gaps = rows.Select(r => r.Gap).ToList();
            var options = Lyrics.Options;
            await Task.Run(() => _library.SearchWebAsync(gaps, _web, options, progress, cts.Token));
        }
        catch (OperationCanceledException)
        {
            // stopped: what was found is written, and stays shown
        }
        catch (Exception e)
        {
            ErrorText = Loc.Format("gaps.failed", e.Message);
        }
        finally
        {
            _cts = null;
            IsSearching = false;
            HasResult = true;
            OnPropertyChanged(nameof(ResultText));
        }
    }

    [RelayCommand]
    private void Stop() => _cts?.Cancel();
}
