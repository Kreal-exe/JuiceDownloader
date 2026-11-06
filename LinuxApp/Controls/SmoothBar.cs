using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Media;

namespace JuiceDownloader.Controls;

/// <summary>A rounded progress bar (0…1) that glides to each new value.</summary>
public sealed class SmoothBar : Control
{
    public static readonly StyledProperty<double> ValueProperty = AvaloniaProperty.Register<SmoothBar, double>(nameof(Value));
    public static readonly StyledProperty<IBrush?> FillProperty = AvaloniaProperty.Register<SmoothBar, IBrush?>(nameof(Fill));
    public static readonly StyledProperty<IBrush?> TrackProperty = AvaloniaProperty.Register<SmoothBar, IBrush?>(nameof(Track));
    public static readonly StyledProperty<int> DurationProperty = AvaloniaProperty.Register<SmoothBar, int>(nameof(Duration), 700);

    static SmoothBar()
    {
        AffectsRender<SmoothBar>(ValueProperty, FillProperty, TrackProperty);
    }

    public double Value { get => GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public IBrush? Fill { get => GetValue(FillProperty); set => SetValue(FillProperty, value); }
    public IBrush? Track { get => GetValue(TrackProperty); set => SetValue(TrackProperty, value); }
    public int Duration { get => GetValue(DurationProperty); set => SetValue(DurationProperty, value); }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        Transitions = Motion.Enabled
            ? [new DoubleTransition { Property = ValueProperty, Duration = TimeSpan.FromMilliseconds(Duration), Easing = new CubicEaseOut() }]
            : null;
    }

    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        if (bounds.Width <= 0 || bounds.Height <= 0) return;
        var radius = bounds.Height / 2;

        if (Track is { } track) context.DrawRectangle(track, null, bounds, radius, radius);

        var width = bounds.Width * Math.Clamp(Value, 0, 1);
        if (width <= 0.5 || Fill is not { } fill) return;
        // Never thinner than its own height, so a tiny share still shows as a dot.
        width = Math.Max(width, bounds.Height);
        context.DrawRectangle(fill, null, new Rect(0, 0, width, bounds.Height), radius, radius);
    }
}
