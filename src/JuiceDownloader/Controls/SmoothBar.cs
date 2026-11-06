using System.Windows;
using System.Windows.Media;

namespace JuiceDownloader.Controls;

/// <summary>A rounded progress bar (0..1) whose fill width eases towards <see cref="Value"/>.</summary>
public sealed class SmoothBar : FrameworkElement
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(SmoothBar), new PropertyMetadata(0.0, OnValueChanged));

    public static readonly DependencyProperty AnimatedValueProperty = DependencyProperty.Register(
        nameof(AnimatedValue), typeof(double), typeof(SmoothBar),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(
        nameof(Fill), typeof(Brush), typeof(SmoothBar),
        new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty TrackProperty = DependencyProperty.Register(
        nameof(Track), typeof(Brush), typeof(SmoothBar),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty DurationProperty = DependencyProperty.Register(
        nameof(Duration), typeof(int), typeof(SmoothBar), new PropertyMetadata(800));

    static SmoothBar()
    {
        HeightProperty.OverrideMetadata(typeof(SmoothBar), new FrameworkPropertyMetadata(6.0));
    }

    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public double AnimatedValue { get => (double)GetValue(AnimatedValueProperty); set => SetValue(AnimatedValueProperty, value); }
    public Brush Fill { get => (Brush)GetValue(FillProperty); set => SetValue(FillProperty, value); }
    public Brush Track { get => (Brush)GetValue(TrackProperty); set => SetValue(TrackProperty, value); }
    public int Duration { get => (int)GetValue(DurationProperty); set => SetValue(DurationProperty, value); }

    private static void OnValueChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var bar = (SmoothBar)d;
        var to = Math.Clamp((double)e.NewValue, 0, 1);

        if (!Motion.Enabled || !bar.IsLoaded)
        {
            bar.BeginAnimation(AnimatedValueProperty, null);
            bar.AnimatedValue = to;
            return;
        }

        bar.BeginAnimation(AnimatedValueProperty, Motion.Double(null, to, bar.Duration, Motion.EaseOutStrong));
    }

    protected override Size MeasureOverride(Size availableSize)
        => new(double.IsInfinity(availableSize.Width) ? 0 : availableSize.Width, Height);

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        var radius = h / 2;
        dc.DrawRoundedRectangle(Track, null, new Rect(0, 0, w, h), radius, radius);

        var value = Math.Clamp(AnimatedValue, 0, 1);
        if (value <= 0) return;

        var fillWidth = Math.Max(h, value * w);
        dc.DrawRoundedRectangle(Fill, null, new Rect(0, 0, fillWidth, h), radius, radius);
    }
}
