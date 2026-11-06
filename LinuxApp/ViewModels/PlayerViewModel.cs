using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;

namespace JuiceDownloader.ViewModels;

/// <summary>A line of the player's queue.</summary>
public sealed record QueueRow(string Name, string SizeText, bool IsCurrent, bool IsPlayingNow, System.Windows.Input.ICommand PlayCommand)
{
    public bool IsIdle => !IsCurrent;
    public bool IsPaused => IsCurrent && !IsPlayingNow;
    public bool IsSounding => IsCurrent && IsPlayingNow;
}

/// <summary>The player bar: what plays, from where, and the walk through its folder. The sound itself is <see cref="MpvPlayer"/>'s.</summary>
public sealed partial class PlayerViewModel : ObservableObject, IDisposable
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly MpvPlayer _mpv;
    private readonly AppSettings _settings;
    private readonly SettingsViewModel _options;
    private readonly Action _save;
    private readonly Action<string, string> _toast;
    private long _seekedAt;
    private double _position;
    private double _volume;

    public PlayerViewModel(string userAgent, AppSettings settings, SettingsViewModel options, Action save, Action<string, string> toast)
    {
        _settings = settings;
        _options = options;
        _save = save;
        _toast = toast;
        _volume = settings.PlayerVolume;
        _mpv = new MpvPlayer(userAgent);
        _mpv.TimeChanged += t => Post(() => ShowTime(t));
        _mpv.DurationChanged += d => Post(() => Duration = d);
        _mpv.PauseChanged += p => Post(() => IsPlaying = !p);
        _mpv.Loaded += () => Post(() => IsLoading = false);
        _mpv.Ended += () => Post(OnEnded);
        _mpv.Failed += why => Post(() => OnFailed(why));
    }

    /// <summary>The row that plays changed, or whether it plays.</summary>
    public event Action? StateChanged;

    [ObservableProperty] private CatalogNode? _current;
    [ObservableProperty] private bool _isOpen;
    [ObservableProperty] private bool _isPlaying;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private double _duration;
    [ObservableProperty] private bool _isQueueOpen;
    [ObservableProperty] private bool _isMuted;
    [ObservableProperty] private bool _isDownloaded;
    [ObservableProperty] private IReadOnlyList<QueueRow> _queue = [];
    [ObservableProperty] private string _queueLine = "";

    /// <summary>Set by the main view model, which owns the lyrics sheet and the downloads.</summary>
    public Action<CatalogNode>? ShowLyrics { get; set; }
    public Func<CatalogNode, Task>? DownloadFile { get; set; }
    public bool IsSilent => IsMuted || Volume <= 0;
    public string SpeakerTip => Loc[IsMuted ? "player.unmute" : "player.mute"];
    public string DownloadTip => Loc[IsDownloaded ? "menu.row.showFile" : "player.download"];
    /// <summary>Previous goes to the start of the track, or within its first seconds to the track before.</summary>
    public bool CanGoBack => HasPrevious || _position > 3;

    public string Title => Current?.DisplayName ?? "";
    public string FolderName => IsLoading ? Loc["player.loading"] : Current?.Parent?.DisplayName ?? "";
    public string ElapsedText => TimeText(Position);
    public string TotalText => TimeText(Duration);
    public bool HasPrevious => Neighbour(-1) is not null;
    public bool HasNext => Neighbour(1) is not null;

    /// <summary>Bound both ways to the slider: a change that arrives here from the view is a seek.</summary>
    public double Position
    {
        get => _position;
        set
        {
            // While nothing is loaded the slider's maximum is zero, and it pulls its value down with it: that is no seek.
            if (IsLoading || Duration <= 0 || Math.Abs(value - _position) < 0.01) return;
            _position = value;
            _seekedAt = Environment.TickCount64;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ElapsedText));
            _ = Task.Run(() => _mpv.Seek(value));
        }
    }

    public double Volume
    {
        get => _volume;
        set
        {
            if (!SetProperty(ref _volume, value)) return;
            _settings.PlayerVolume = value;
            _save();
            IsMuted = false;
            OnPropertyChanged(nameof(IsSilent));
            _ = Task.Run(() => _mpv.SetVolume(value));
        }
    }

    partial void OnCurrentChanged(CatalogNode? value)
    {
        OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(FolderName));
        OnPropertyChanged(nameof(HasPrevious));
        OnPropertyChanged(nameof(HasNext));
        OnPropertyChanged(nameof(CanGoBack));
        IsDownloaded = value is not null && Library.LocalCopy(_options.Destination, value) is not null;
        RefreshQueue();
        StateChanged?.Invoke();
    }

    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(FolderName));
    partial void OnIsQueueOpenChanged(bool value) => RefreshQueue();
    partial void OnIsDownloadedChanged(bool value) => OnPropertyChanged(nameof(DownloadTip));
    partial void OnIsMutedChanged(bool value)
    {
        OnPropertyChanged(nameof(IsSilent));
        OnPropertyChanged(nameof(SpeakerTip));
        var volume = value ? 0 : Volume;
        _ = Task.Run(() => _mpv.SetVolume(volume));
    }

    partial void OnIsPlayingChanged(bool value)
    {
        RefreshQueue();
        StateChanged?.Invoke();
    }

    private void RefreshQueue()
    {
        if (!IsQueueOpen) return;
        if (Current is not { Parent: { } folder } current)
        {
            Queue = [];
            return;
        }
        var files = folder.Children.Where(c => !c.IsDirectory && Library.IsPlayable(c.Name)).ToList();
        Queue = files.Select(f =>
        {
            var isCurrent = f.Path == current.Path;
            return new QueueRow(f.DisplayName, ByteFormatter.Format(f.Size), isCurrent, isCurrent && IsPlaying, new RelayCommand(() => Toggle(f)));
        }).ToList();
        QueueLine = Loc.Format("player.queue.line", ByteFormatter.FormatCount(files.FindIndex(f => f.Path == current.Path) + 1), ByteFormatter.FormatCount(files.Count), folder.DisplayName);
    }

    [RelayCommand]
    private void ToggleQueue() => IsQueueOpen = !IsQueueOpen;

    [RelayCommand]
    private void ToggleMute() => IsMuted = !IsMuted;

    [RelayCommand]
    private void OpenLyrics()
    {
        if (Current is { } file) ShowLyrics?.Invoke(file);
    }

    /// <summary>Downloads the track, or shows the file when it is already there.</summary>
    [RelayCommand]
    private async Task DownloadTrack()
    {
        if (Current is not { } file) return;
        if (Library.LocalCopy(_options.Destination, file) is { } local)
        {
            Platform.Reveal(local);
            return;
        }
        if (DownloadFile is { } download) await download(file);
        if (ReferenceEquals(Current, file)) IsDownloaded = Library.LocalCopy(_options.Destination, file) is not null;
    }
    partial void OnDurationChanged(double value) => OnPropertyChanged(nameof(TotalText));

    private static void Post(Action action) => Dispatcher.UIThread.Post(action);

    private void ShowTime(double seconds)
    {
        // Just after a seek mpv still reports where it was; the slider must not jump back.
        if (Environment.TickCount64 - _seekedAt < 600) return;
        _position = seconds;
        OnPropertyChanged(nameof(Position));
        OnPropertyChanged(nameof(ElapsedText));
        OnPropertyChanged(nameof(CanGoBack));
    }

    /// <summary>The play button of a row: starts it, or pauses and resumes the one already playing.</summary>
    public void Toggle(CatalogNode file)
    {
        if (Current?.Path == file.Path) { PlayPause(); return; }
        _ = PlayAsync(file);
    }

    private async Task PlayAsync(CatalogNode file)
    {
        var source = Library.LocalCopy(_options.Destination, file) ?? ApiClient.DownloadUrl(file.Path);
        var volume = Volume;
        Current = file;
        IsOpen = true;
        IsLoading = true;
        Duration = 0;
        _position = 0;
        OnPropertyChanged(nameof(Position));
        OnPropertyChanged(nameof(ElapsedText));

        var started = await Task.Run(() =>
        {
            if (!_mpv.EnsureStarted()) return false;
            _mpv.SetVolume(volume);
            _mpv.Load(source);
            return true;
        });
        if (started) return;

        Close();
        _toast("AlertCircleOutline", Loc["player.noBackend"]);
    }

    [RelayCommand]
    private void PlayPause()
    {
        if (Current is null) return;
        var pause = IsPlaying;
        _ = Task.Run(() => _mpv.SetPause(pause));
    }

    [RelayCommand]
    private void Next() => Step(1);

    [RelayCommand]
    private void Previous()
    {
        if (_position > 3)
        {
            Position = 0;
            return;
        }
        Step(-1);
    }

    private void Step(int by)
    {
        if (Neighbour(by) is { } file) _ = PlayAsync(file);
    }

    /// <summary>The next playable file of the same folder, or null at its end.</summary>
    private CatalogNode? Neighbour(int by)
    {
        if (Current?.Parent is not { } folder) return null;
        var files = folder.Children.Where(c => !c.IsDirectory && Library.IsPlayable(c.Name)).ToList();
        var at = files.FindIndex(f => f.Path == Current.Path) + by;
        return at >= 0 && at < files.Count ? files[at] : null;
    }

    private void OnEnded()
    {
        if (Neighbour(1) is { } file) { _ = PlayAsync(file); return; }
        // The end of the folder: the bar stays, at the end of the last track.
        IsPlaying = false;
    }

    private void OnFailed(string why)
    {
        if (!IsOpen) return;
        Close();
        _toast("AlertCircleOutline", Loc.Format("player.failed", why));
    }

    [RelayCommand]
    private void Close()
    {
        IsOpen = false;
        IsPlaying = false;
        IsLoading = false;
        IsQueueOpen = false;
        Current = null;
        _ = Task.Run(() => _mpv.Unload());
    }

    public void Dispose() => _mpv.Dispose();

    private static string TimeText(double seconds)
    {
        if (double.IsNaN(seconds) || seconds < 0) seconds = 0;
        var time = TimeSpan.FromSeconds(seconds);
        return time.TotalHours >= 1 ? $"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}" : $"{time.Minutes}:{time.Seconds:00}";
    }
}
