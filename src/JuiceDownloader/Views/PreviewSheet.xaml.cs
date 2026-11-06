using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

/// <summary>The MediaElement and its controls live here: they are the view's, and only the file comes from the model.</summary>
public partial class PreviewSheet : UserControl
{
    private readonly DispatcherTimer _ticker = new(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(250) };
    private PreviewViewModel? _vm;
    private bool _playing;
    private bool _ticking;

    public PreviewSheet()
    {
        InitializeComponent();
        _ticker.Tick += (_, _) => ShowPosition();
        DataContextChanged += (_, e) =>
        {
            if (_vm is not null) _vm.PropertyChanged -= OnVmPropertyChanged;
            _vm = e.NewValue as PreviewViewModel;
            if (_vm is not null) _vm.PropertyChanged += OnVmPropertyChanged;
        };
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_vm is null || e.PropertyName != nameof(PreviewViewModel.VideoFile)) return;
        _ticker.Stop();
        Video.Stop();
        Video.Close();
        Video.Source = null;
        SetPlaying(false);
        Show(0, VideoElapsed);
        Show(0, VideoTotal);
        if (_vm.VideoFile is not { } file) return;
        Video.Source = new Uri(file, UriKind.Absolute);
        Video.Play();
        SetPlaying(true);
    }

    private void OnRoomSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_vm is null || e.NewSize.Width <= 0 || e.NewSize.Height <= 0) return;
        var dpi = VisualTreeHelper.GetDpi(this);
        _vm.RoomWidth = Math.Max(1, (int)Math.Ceiling(e.NewSize.Width * dpi.DpiScaleX));
        _vm.RoomHeight = Math.Max(1, (int)Math.Ceiling(e.NewSize.Height * dpi.DpiScaleY));
    }

    private void OnVideoOpened(object sender, RoutedEventArgs e)
    {
        if (Video.NaturalDuration.HasTimeSpan)
        {
            VideoSeek.Maximum = Math.Max(1, Video.NaturalDuration.TimeSpan.TotalSeconds);
            Show(VideoSeek.Maximum, VideoTotal);
        }
        _ticker.Start();
    }

    private void OnVideoEnded(object sender, RoutedEventArgs e)
    {
        Video.Pause();
        Video.Position = TimeSpan.Zero;
        SetPlaying(false);
        _ticker.Stop();
        ShowPosition();
    }

    private void OnVideoFailed(object? sender, ExceptionRoutedEventArgs e)
    {
        _ticker.Stop();
        _vm?.VideoFailed(e.ErrorException?.Message ?? string.Empty);
    }

    private void OnVideoToggle(object sender, RoutedEventArgs e)
    {
        if (_playing) Video.Pause();
        else Video.Play();
        SetPlaying(!_playing);
        if (_playing) _ticker.Start();
        else _ticker.Stop();
    }

    private void OnVideoSeek(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_ticking) return;
        Video.Position = TimeSpan.FromSeconds(e.NewValue);
        Show(e.NewValue, VideoElapsed);
    }

    private void ShowPosition()
    {
        var seconds = Video.Position.TotalSeconds;
        _ticking = true;
        VideoSeek.Value = seconds;
        _ticking = false;
        Show(seconds, VideoElapsed);
    }

    private void SetPlaying(bool playing)
    {
        _playing = playing;
        VideoToggle.Content = playing ? "" : "";
    }

    private static void Show(double seconds, TextBlock label)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        label.Text = t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
    }
}
