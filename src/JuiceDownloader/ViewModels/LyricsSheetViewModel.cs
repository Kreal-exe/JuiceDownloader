using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

/// <summary>The words of one file, on a sheet over the window.</summary>
public sealed partial class LyricsSheetViewModel(Library library, LyricsViewModel lyrics) : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private int _request;

    [ObservableProperty] private bool _isVisible;
    [ObservableProperty] private string _title = string.Empty;
    [ObservableProperty] private string _note = string.Empty;
    [ObservableProperty] private string _words = string.Empty;

    public async Task ShowAsync(CatalogNode file)
    {
        var request = ++_request;
        Title = file.DisplayName;
        Words = string.Empty;
        Note = Loc["player.loading"];
        IsVisible = true;

        // An old copy now beats a minute of waiting; only the very first time is there nothing to show.
        var index = await Task.Run(library.KnownLyrics);
        if (request != _request) return;
        if (index is null)
        {
            void OnProgress(object? _, System.ComponentModel.PropertyChangedEventArgs e)
            {
                if (e.PropertyName == nameof(LyricsViewModel.LoadingText) && request == _request) Note = lyrics.LoadingText;
            }
            lyrics.PropertyChanged += OnProgress;
            bool ok;
            try { ok = await lyrics.FetchAsync(force: false); }
            finally { lyrics.PropertyChanged -= OnProgress; }
            if (request != _request) return;
            if (!ok || library.Lyrics is not { } fetched)
            {
                Note = lyrics.ErrorText;
                return;
            }
            index = fetched;
        }

        var match = await Task.Run(() => index.Find(file.Path));
        if (request != _request) return;
        var words = match?.Song is { } song ? (string.IsNullOrWhiteSpace(song.Lyrics) ? song.SyncedLyrics : song.Lyrics) : null;
        Words = words?.Trim() ?? string.Empty;
        Note = string.IsNullOrWhiteSpace(words) ? Loc["lyrics.view.none"]
            : match!.Fit == LyricsFit.OtherRecording ? Loc["lyrics.view.other"]
            : string.Empty;
    }

    [RelayCommand]
    private void Close()
    {
        _request++;
        IsVisible = false;
    }
}
