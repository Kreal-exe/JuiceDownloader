using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;

namespace JuiceDownloader.Controls;

/// <summary>
/// The ring: an arc that sweeps to its share, or a spinning segment while something is under way.
/// </summary>
public sealed class RingArc : Control
{
    public static readonly StyledProperty<double> SweepProperty = AvaloniaProperty.Register<RingArc, double>(nameof(Sweep));
    public static readonly StyledProperty<IBrush?> StrokeProperty = AvaloniaProperty.Register<RingArc, IBrush?>(nameof(Stroke));
    public static readonly StyledProperty<double> StrokeThicknessProperty = AvaloniaProperty.Register<RingArc, double>(nameof(StrokeThickness), 14);
    public static readonly StyledProperty<bool> IsSpinningProperty = AvaloniaProperty.Register<RingArc, bool>(nameof(IsSpinning));
    private static readonly StyledProperty<double> ShownSweepProperty = AvaloniaProperty.Register<RingArc, double>("ShownSweep");

    private DispatcherTimer? _spin;
    private double _rotation;

    static RingArc()
    {
        AffectsRender<RingArc>(ShownSweepProperty, StrokeProperty, StrokeThicknessProperty);
    }

    public double Sweep { get => GetValue(SweepProperty); set => SetValue(SweepProperty, value); }
    public IBrush? Stroke { get => GetValue(StrokeProperty); set => SetValue(StrokeProperty, value); }
    public double StrokeThickness { get => GetValue(StrokeThicknessProperty); set => SetValue(StrokeThicknessProperty, value); }
    public bool IsSpinning { get => GetValue(IsSpinningProperty); set => SetValue(IsSpinningProperty, value); }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        Transitions = Motion.Enabled
            ? [new DoubleTransition { Property = ShownSweepProperty, Duration = TimeSpan.FromMilliseconds(900), Easing = new CubicEaseOut() }]
            : null;
        Update();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        _spin?.Stop();
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == SweepProperty || change.Property == IsSpinningProperty) Update();
    }

    private void Update()
    {
        if (IsSpinning)
        {
            SetValue(ShownSweepProperty, 70.0);
            _spin ??= new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) =>
            {
                _rotation = (_rotation + 5) % 360;
                InvalidateVisual();
            });
            _spin.Start();
        }
        else
        {
            _spin?.Stop();
            _rotation = 0;
            SetValue(ShownSweepProperty, Math.Clamp(Sweep, 0, 360));
            InvalidateVisual();
        }
    }

    public override void Render(DrawingContext context)
    {
        var sweep = GetValue(ShownSweepProperty);
        if (Stroke is not { } stroke || sweep <= 0.1) return;

        var thickness = StrokeThickness;
        var size = Math.Min(Bounds.Width, Bounds.Height);
        var radius = (size - thickness) / 2;
        if (radius <= 0) return;
        var center = new Point(Bounds.Width / 2, Bounds.Height / 2);
        var pen = new Pen(stroke, thickness, lineCap: PenLineCap.Round);

        if (sweep >= 359.9)
        {
            context.DrawEllipse(null, pen, center, radius, radius);
            return;
        }

        // 0° is twelve o'clock, angles grow clockwise.
        var start = _rotation - 90;
        var end = start + sweep;
        Point At(double degrees)
        {
            var r = degrees * Math.PI / 180;
            return new Point(center.X + radius * Math.Cos(r), center.Y + radius * Math.Sin(r));
        }

        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            g.BeginFigure(At(start), false);
            g.ArcTo(At(end), new Size(radius, radius), 0, sweep > 180, SweepDirection.Clockwise);
            g.EndFigure(false);
        }
        context.DrawGeometry(null, pen, geometry);
    }
}
