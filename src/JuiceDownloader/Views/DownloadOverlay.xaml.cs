using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using JuiceDownloader.Controls;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

public partial class DownloadOverlay : UserControl
{
    private static readonly Color[] Palette =
    [
        Color.FromRgb(0x7C, 0x6C, 0xFF), Color.FromRgb(0x22, 0xD3, 0xEE), Color.FromRgb(0xF4, 0x72, 0xB6),
        Color.FromRgb(0x34, 0xD3, 0x99), Color.FromRgb(0xFB, 0xBF, 0x24), Color.FromRgb(0x60, 0xA5, 0xFA),
    ];

    private readonly Random _random = new();
    private DownloadViewModel? _vm;

    public DownloadOverlay()
    {
        InitializeComponent();
        DataContextChanged += (_, e) =>
        {
            if (_vm is not null) _vm.PropertyChanged -= OnVmPropertyChanged;
            _vm = e.NewValue as DownloadViewModel;
            if (_vm is not null) _vm.PropertyChanged += OnVmPropertyChanged;
        };
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_vm is null || e.PropertyName != nameof(DownloadViewModel.RingAngle)) return;
        if (_vm.RingAngle <= 0)
        {
            ValueArc.BeginAnimation(Arc.EndAngleProperty, null);
            ValueArc.EndAngle = 0;
            return;
        }
        // Ticks come four times a second: each eases into the next.
        ValueArc.BeginAnimation(Arc.EndAngleProperty, Motion.Double(null, _vm.RingAngle, 400, Motion.EaseOut));
    }

    public void Show()
    {
        Visibility = Visibility.Visible;
        Confetti.Children.Clear();

        if (!Motion.Enabled)
        {
            Root.Opacity = 1;
            return;
        }

        Root.Opacity = 0;
        CardScale.ScaleX = CardScale.ScaleY = 0.92;
        CardT.Y = 24;

        Root.BeginAnimation(OpacityProperty, Motion.Double(0, 1, 220));
        CardScale.BeginAnimation(ScaleTransform.ScaleXProperty, Motion.Double(0.92, 1, 480, Motion.Spring));
        CardScale.BeginAnimation(ScaleTransform.ScaleYProperty, Motion.Double(0.92, 1, 480, Motion.Spring));
        CardT.BeginAnimation(TranslateTransform.YProperty, Motion.Double(24, 0, 480, Motion.EaseOutStrong));
    }

    public void Hide()
    {
        if (!Motion.Enabled)
        {
            Visibility = Visibility.Collapsed;
            return;
        }

        var fade = Motion.Double(null, 0, 180, Motion.EaseIn);
        fade.Completed += (_, _) =>
        {
            Visibility = Visibility.Collapsed;
            Confetti.Children.Clear();
        };
        Root.BeginAnimation(OpacityProperty, fade);
        CardScale.BeginAnimation(ScaleTransform.ScaleXProperty, Motion.Double(null, 0.96, 180, Motion.EaseIn));
        CardScale.BeginAnimation(ScaleTransform.ScaleYProperty, Motion.Double(null, 0.96, 180, Motion.EaseIn));
    }

    /// <summary>A quick confetti burst from the top of the card.</summary>
    public void Celebrate()
    {
        if (!Motion.Enabled || Visibility != Visibility.Visible) return;

        var w = ActualWidth;
        var h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        var originX = w / 2;
        var originY = h / 2 - 160;

        for (var i = 0; i < 90; i++)
        {
            var color = Palette[_random.Next(Palette.Length)];
            var size = 6 + _random.NextDouble() * 6;
            Shape piece = _random.Next(3) == 0
                ? new Ellipse { Width = size, Height = size }
                : new Rectangle { Width = size, Height = size * 1.6, RadiusX = 2, RadiusY = 2 };
            piece.Fill = new SolidColorBrush(color);
            piece.RenderTransformOrigin = new Point(0.5, 0.5);

            var rotate = new RotateTransform(_random.NextDouble() * 360);
            var translate = new TranslateTransform(originX, originY);
            piece.RenderTransform = new TransformGroup { Children = { rotate, translate } };
            Confetti.Children.Add(piece);

            var spread = (_random.NextDouble() - 0.5) * 2;
            var dx = spread * (260 + _random.NextDouble() * 260);
            var peak = originY - (120 + _random.NextDouble() * 260);
            var ms = 1500 + _random.Next(900);

            var x = new DoubleAnimation(originX, originX + dx, TimeSpan.FromMilliseconds(ms))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            };

            var y = new DoubleAnimationUsingKeyFrames();
            y.KeyFrames.Add(new EasingDoubleKeyFrame(originY, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            y.KeyFrames.Add(new EasingDoubleKeyFrame(peak, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(ms * 0.32)),
                new CubicEase { EasingMode = EasingMode.EaseOut }));
            y.KeyFrames.Add(new EasingDoubleKeyFrame(h + 40, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(ms)),
                new QuadraticEase { EasingMode = EasingMode.EaseIn }));

            var spin = new DoubleAnimation(rotate.Angle, rotate.Angle + (_random.NextDouble() - 0.5) * 1080, TimeSpan.FromMilliseconds(ms));
            var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(ms * 0.35)) { BeginTime = TimeSpan.FromMilliseconds(ms * 0.65) };

            var captured = piece;
            fade.Completed += (_, _) => Confetti.Children.Remove(captured);

            translate.BeginAnimation(TranslateTransform.XProperty, x);
            translate.BeginAnimation(TranslateTransform.YProperty, y);
            rotate.BeginAnimation(RotateTransform.AngleProperty, spin);
            piece.BeginAnimation(OpacityProperty, fade);
        }
    }
}
