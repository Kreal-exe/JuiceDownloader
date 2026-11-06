using System.IO;
using System.Net.Http;
using System.Windows.Media;
using System.Windows.Threading;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

/// <summary>
/// The player bar. WPF's MediaPlayer cannot send the app's User-Agent, so a track that is not downloaded is fetched to a
/// temporary file and played from there; the file goes on the next track and on exit.
/// </summary>
/// <summary>A line of the player's queue.</summary>
public sealed record QueueRow(CatalogNode Node, string Name, string SizeText, bool IsCurrent, string Glyph) : IRowNode;

public sealed partial class PlayerViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;
    private static readonly string TempFolder = Path.Combine(Path.GetTempPath(), "JuiceDownloader", "player");

    private readonly HttpClient _http;
    private readonly SettingsViewModel _settings;
    private readonly AppSettings _appSettings;
    private readonly Action _save;
    private readonly Action<string, string> _toast;
    private readonly MediaPlayer _media = new();
    private readonly DispatcherTimer _ticker;
    private readonly DispatcherTimer _saveVolume;

    private CancellationTokenSource? _loading;
    private CatalogNode? _current;
    private string? _temp;
    private string? _openedLocal;
    private bool _ended;
    private double _position;

    public PlayerViewModel(HttpClient http, SettingsViewModel settings, AppSettings appSettings, Action save, Action<string, string> toast)
    {
        _http = http;
        _settings = settings;
        _appSettings = appSettings;
        _save = save;
        _toast = toast;

        _volume = appSettings.PlayerVolume;
        _media.Volume = _volume;
        _media.MediaOpened += (_, _) => OnOpened();
        _media.MediaEnded += (_, _) => OnEnded();
        _media.MediaFailed += (_, e) => OnFailed(e.ErrorException);

        _ticker = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(250) };
        _ticker.Tick += (_, _) => ShowPosition();
        _saveVolume = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _saveVolume.Tick += (_, _) =>
        {
            _saveVolume.Stop();
            _save();
        };

        settings.ResetRequested += () => Volume = AppSettings.DefaultPlayerVolume;
        Loc.LanguageChanged += (_, _) => OnPropertyChanged(string.Empty);
        _ = Task.Run(SweepTemp);
    }

    /// <summary>The track changed, or started or stopped playing: rows show it.</summary>
    public event Action? NowPlayingChanged;

    [ObservableProperty] private bool _isVisible;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private bool _isPlaying;
    [ObservableProperty] private double _durationSeconds = 1;
    [ObservableProperty] private double _volume;
    [ObservableProperty] private string _title = string.Empty;
    [ObservableProperty] private string _folder = string.Empty;
    [ObservableProperty] private string _elapsedText = "0:00";
    [ObservableProperty] private string _totalText = "0:00";
    [ObservableProperty] private bool _hasPrevious;
    [ObservableProperty] private bool _hasNext;
    [ObservableProperty] private bool _isQueueOpen;
    [ObservableProperty] private bool _isMuted;
    [ObservableProperty] private bool _isDownloaded;
    [ObservableProperty] private IReadOnlyList<QueueRow> _queue = [];
    [ObservableProperty] private string _queueLine = string.Empty;

    /// <summary>Set by the main view model, which owns the lyrics sheet and the downloads.</summary>
    public Action<CatalogNode>? ShowLyrics { get; set; }
    public Func<CatalogNode, Task>? DownloadFile { get; set; }
    public string ChevronGlyph => IsQueueOpen ? "\uE70D" : "\uE70E";
    public string SpeakerGlyph => IsMuted || Volume <= 0 ? "\uE74F" : "\uE767";
    public string SpeakerTip => Loc[IsMuted ? "player.unmute" : "player.mute"];
    public string DownloadGlyph => IsDownloaded ? "\uE73E" : "\uE896";
    public string DownloadTip => Loc[IsDownloaded ? "menu.row.showFile" : "player.download"];
    /// <summary>Previous goes to the start of the track, or within its first seconds to the track before.</summary>
    public bool CanGoBack => HasPrevious || _position > 3;

    public string? CurrentPath => _current?.Path;
    public string SubtitleText => IsLoading ? Loc["player.loading"] : Folder;
    public string PlayGlyph => IsPlaying ? "" : "";
    public string PlayTip => Loc[IsPlaying ? "player.pause" : "player.play"];

    /// <summary>Set by the slider, which seeks; the ticker moves the slider through <see cref="ShowPosition"/>, which does not.</summary>
    public double PositionSeconds
    {
        get => _position;
        set
        {
            if (!SetProperty(ref _position, value)) return;
            _media.Position = TimeSpan.FromSeconds(value);
            _ended = false;
            ElapsedText = Time(value);
        }
    }

    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(SubtitleText));
    partial void OnHasPreviousChanged(bool value) => OnPropertyChanged(nameof(CanGoBack));
    partial void OnIsQueueOpenChanged(bool value)
    {
        OnPropertyChanged(nameof(ChevronGlyph));
        if (value) RefreshQueue();
    }
    partial void OnIsMutedChanged(bool value)
    {
        _media.IsMuted = value;
        OnPropertyChanged(nameof(SpeakerGlyph));
        OnPropertyChanged(nameof(SpeakerTip));
    }
    partial void OnIsDownloadedChanged(bool value)
    {
        OnPropertyChanged(nameof(DownloadGlyph));
        OnPropertyChanged(nameof(DownloadTip));
    }
    partial void OnFolderChanged(string value) => OnPropertyChanged(nameof(SubtitleText));
    partial void OnIsPlayingChanged(bool value)
    {
        OnPropertyChanged(nameof(PlayGlyph));
        OnPropertyChanged(nameof(PlayTip));
        RefreshQueue();
        NowPlayingChanged?.Invoke();
    }

    partial void OnVolumeChanged(double value)
    {
        _media.Volume = value;
        if (IsMuted) IsMuted = false;
        OnPropertyChanged(nameof(SpeakerGlyph));
        _appSettings.PlayerVolume = value;
        _saveVolume.Stop();
        _saveVolume.Start();
    }

    /// <summary>Plays a file of the catalog, or pauses or resumes it if it is the current one.</summary>
    public void PlayOrToggle(CatalogNode file)
    {
        if (file.Path == CurrentPath) Toggle();
        else _ = OpenAsync(file);
    }

    private async Task OpenAsync(CatalogNode file)
    {
        _loading?.Cancel();
        var loading = new CancellationTokenSource();
        _loading = loading;

        StopMedia();
        _current = file;
        _openedLocal = null;
        _ended = false;
        Title = file.DisplayName;
        Folder = file.Parent?.DisplayName ?? string.Empty;
        IsLoading = true;
        IsVisible = true;
        DurationSeconds = 1;
        ShowPosition(0);
        TotalText = Time(0);
        (HasPrevious, HasNext) = (Neighbour(-1) is not null, Neighbour(1) is not null);
        OnPropertyChanged(nameof(CurrentPath));
        RefreshQueue();
        NowPlayingChanged?.Invoke();

        try
        {
            var destination = _settings.Destination;
            var local = await Task.Run(() => Library.LocalCopy(destination, file));
            if (loading.IsCancellationRequested) return;
            IsDownloaded = local is not null;
            if (local is not null)
            {
                _openedLocal = local;
                Open(local);
            }
            else
            {
                Open(await FetchAsync(file.Name, ApiClient.DownloadUrl(file.Path), loading.Token));
            }
        }
        catch (OperationCanceledException) when (loading.IsCancellationRequested)
        {
            // another track was asked for, or the bar was closed
        }
        catch (Exception e)
        {
            Fail(e.Message);
        }
    }

    private void Open(string file)
    {
        _media.Open(new Uri(file, UriKind.Absolute));
        _media.Play();
    }

    private async Task<string> FetchAsync(string name, string url, CancellationToken ct)
    {
        var temp = NewTemp(name);
        _temp = temp;
        await MediaFetch.ToFileAsync(_http, url, temp, null, ct);
        ct.ThrowIfCancellationRequested();
        return temp;
    }

    private void OnOpened()
    {
        if (_current is null) return;
        IsLoading = false;
        IsPlaying = true;
        if (_media.NaturalDuration.HasTimeSpan)
        {
            DurationSeconds = Math.Max(1, _media.NaturalDuration.TimeSpan.TotalSeconds);
            TotalText = Time(DurationSeconds);
        }
        _ticker.Start();
    }

    private void OnEnded()
    {
        if (Neighbour(1) is { } next)
        {
            _ = OpenAsync(next);
            return;
        }
        // The end of the folder: stops here, ready to start over.
        _media.Pause();
        _ended = true;
        _ticker.Stop();
        IsPlaying = false;
    }

    private void OnFailed(Exception? error)
    {
        // A path Windows' media stack cannot read as a URL, such as one with a '#': a plain name in the temp folder can be.
        if (_openedLocal is { } local && _current is not null)
        {
            _openedLocal = null;
            _ = RetryFromCopyAsync(local);
            return;
        }
        Fail(error?.Message ?? string.Empty);
    }

    private async Task RetryFromCopyAsync(string local)
    {
        var token = _loading?.Token ?? CancellationToken.None;
        try
        {
            var temp = NewTemp(local);
            _temp = temp;
            await Task.Run(() =>
            {
                Directory.CreateDirectory(TempFolder);
                File.Copy(local, temp, overwrite: true);
            }, token);
            if (!token.IsCancellationRequested) Open(temp);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Fail(e.Message);
        }
    }

    private void Fail(string reason)
    {
        _ticker.Stop();
        IsLoading = false;
        IsPlaying = false;
        _toast("", Loc.Format("player.failed", reason));
    }

    private void ShowPosition() => ShowPosition(_media.Position.TotalSeconds);

    private void ShowPosition(double seconds)
    {
        _position = seconds;
        OnPropertyChanged(nameof(PositionSeconds));
        OnPropertyChanged(nameof(CanGoBack));
        ElapsedText = Time(seconds);
    }

    private static string Time(double seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
    }

    /// <summary>The playable file before or after this one in its folder.</summary>
    private CatalogNode? Neighbour(int step)
    {
        if (_current?.Parent is not { } parent) return null;
        var files = parent.Children.Where(n => !n.IsDirectory && Library.IsPlayable(n.Name)).ToList();
        var at = files.IndexOf(_current) + step;
        return at >= 0 && at < files.Count && files.Contains(_current) ? files[at] : null;
    }

    /// <summary>A video started on the preview sheet: the two are not heard together.</summary>
    public void Pause()
    {
        if (IsPlaying) Toggle();
    }

    [RelayCommand]
    private void Toggle()
    {
        if (_current is null || IsLoading) return;
        if (IsPlaying)
        {
            _media.Pause();
            _ticker.Stop();
            IsPlaying = false;
            return;
        }
        if (_ended)
        {
            _media.Position = TimeSpan.Zero;
            _ended = false;
        }
        _media.Play();
        _ticker.Start();
        IsPlaying = true;
    }

    [RelayCommand]
    private void Previous()
    {
        if (_position > 3)
        {
            PositionSeconds = 0;
            return;
        }
        if (Neighbour(-1) is { } file) _ = OpenAsync(file);
    }

    private void RefreshQueue()
    {
        if (!IsQueueOpen) return;
        if (_current?.Parent is not { } parent)
        {
            Queue = [];
            return;
        }
        var files = parent.Children.Where(n => !n.IsDirectory && Library.IsPlayable(n.Name)).ToList();
        Queue = files.Select(f =>
        {
            var current = f.Path == _current.Path;
            return new QueueRow(f, f.DisplayName, ByteFormatter.Format(f.Size), current, !current ? "\uEC4F" : IsPlaying ? "\uE767" : "\uE769");
        }).ToList();
        QueueLine = Loc.Format("player.queue.line", ByteFormatter.FormatCount(files.FindIndex(f => f.Path == _current.Path) + 1), ByteFormatter.FormatCount(files.Count), parent.DisplayName);
    }

    [RelayCommand]
    private void ToggleQueue() => IsQueueOpen = !IsQueueOpen;

    /// <summary>A click on a line of the queue. A plain object: a recycled container may hand over something else for a moment.</summary>
    [RelayCommand]
    private void PlayQueueRow(object? parameter)
    {
        if (parameter is QueueRow row) PlayOrToggle(row.Node);
    }

    [RelayCommand]
    private void ToggleMute() => IsMuted = !IsMuted;

    [RelayCommand]
    private void OpenLyrics()
    {
        if (_current is { } file) ShowLyrics?.Invoke(file);
    }

    /// <summary>Downloads the track, or shows the file when it is already there.</summary>
    [RelayCommand]
    private async Task DownloadTrack()
    {
        if (_current is not { } file) return;
        if (Library.LocalCopy(_settings.Destination, file) is { } local)
        {
            Shell.RevealFile(local);
            return;
        }
        if (DownloadFile is { } download) await download(file);
        if (ReferenceEquals(_current, file)) IsDownloaded = Library.LocalCopy(_settings.Destination, file) is not null;
    }

    [RelayCommand]
    private void Next()
    {
        if (Neighbour(1) is { } file) _ = OpenAsync(file);
    }

    [RelayCommand]
    private void Close()
    {
        _loading?.Cancel();
        StopMedia();
        _current = null;
        IsLoading = false;
        IsPlaying = false;
        IsQueueOpen = false;
        IsVisible = false;
        OnPropertyChanged(nameof(CurrentPath));
        NowPlayingChanged?.Invoke();
    }

    /// <summary>When the window closes: lets go of the temporary file and removes it, and what is left of earlier runs.</summary>
    public void Shutdown()
    {
        _loading?.Cancel();
        _media.Close();
        SweepTemp();
    }

    private void StopMedia()
    {
        _ticker.Stop();
        _media.Close();
        IsPlaying = false;
        if (_temp is { } temp)
        {
            _temp = null;
            // The player lets go of it a moment after Close; a miss is swept up on the next start.
            _ = Task.Run(async () =>
            {
                await Task.Delay(500);
                MediaFetch.TryDelete(temp);
            });
        }
    }

    private static string NewTemp(string name) => Path.Combine(TempFolder, Guid.NewGuid().ToString("N") + Path.GetExtension(name).ToLowerInvariant());

    private static void SweepTemp() => MediaFetch.Sweep(TempFolder);
}
