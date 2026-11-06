using System.Windows;
using System.Windows.Media;
using System.Windows.Shapes;

namespace JuiceDownloader.Controls;

/// <summary>A circular arc drawn clockwise from <see cref="StartAngle"/> to <see cref="EndAngle"/> (degrees, 0 = 12 o'clock). Both angles are animatable.</summary>
public sealed class Arc : Shape
{
    public static readonly DependencyProperty StartAngleProperty = DependencyProperty.Register(
        nameof(StartAngle), typeof(double), typeof(Arc),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty EndAngleProperty = DependencyProperty.Register(
        nameof(EndAngle), typeof(double), typeof(Arc),
        new FrameworkPropertyMetadata(360.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public double StartAngle
    {
        get => (double)GetValue(StartAngleProperty);
        set => SetValue(StartAngleProperty, value);
    }

    public double EndAngle
    {
        get => (double)GetValue(EndAngleProperty);
        set => SetValue(EndAngleProperty, value);
    }

    protected override Geometry DefiningGeometry
    {
        get
        {
            var w = ActualWidth;
            var h = ActualHeight;
            if (w <= 0 || h <= 0) return Geometry.Empty;

            var thickness = StrokeThickness;
            var radius = Math.Max(0, Math.Min(w, h) / 2 - thickness / 2);
            var center = new Point(w / 2, h / 2);

            var start = StartAngle;
            var sweep = EndAngle - StartAngle;
            if (sweep <= 0) return Geometry.Empty;

            if (sweep >= 360)
            {
                return new EllipseGeometry(center, radius, radius);
            }

            var p0 = PointAt(center, radius, start);
            var p1 = PointAt(center, radius, start + sweep);

            var figure = new PathFigure { StartPoint = p0, IsClosed = false, IsFilled = false };
            figure.Segments.Add(new ArcSegment(p1, new Size(radius, radius), 0, sweep > 180, SweepDirection.Clockwise, true));

            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            geometry.Freeze();
            return geometry;
        }
    }

    private static Point PointAt(Point center, double radius, double degrees)
    {
        var rad = (degrees - 90) * Math.PI / 180;
        return new Point(center.X + radius * Math.Cos(rad), center.Y + radius * Math.Sin(rad));
    }
}
