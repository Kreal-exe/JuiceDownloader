using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Threading;

namespace JuiceDownloader.Controls;

/// <summary>A quick burst from the top of the overlay's card, when a whole download has come through.</summary>
public sealed class Confetti : Control
{
    private static readonly IBrush[] Colors =
        new[] { "#8B7CFF", "#5B8CFF", "#22D3EE", "#F472B6", "#34D399", "#F59E0B" }.Select(c => (IBrush)new ImmutableSolidColorBrush(Color.Parse(c))).ToArray();

    private sealed record Piece(double SpeedX, double SpeedY, double Spin, double Angle, double Width, double Height, double Life, bool Round, IBrush Brush);

    private readonly List<Piece> _pieces = [];
    private DispatcherTimer? _timer;
    private DateTime _started;

    public Confetti() => IsHitTestVisible = false;

    public void Burst()
    {
        if (!Motion.Enabled || Bounds.Width <= 0) return;
        var random = new Random();
        _pieces.Clear();
        for (var i = 0; i < 90; i++)
        {
            var size = 6 + random.NextDouble() * 6;
            var round = random.Next(3) == 0;
            _pieces.Add(new Piece(
                (random.NextDouble() - 0.5) * 2 * (260 + random.NextDouble() * 260),
                -(420 + random.NextDouble() * 520),
                (random.NextDouble() - 0.5) * 1080,
                random.NextDouble() * 360,
                size,
                round ? size : size * 1.6,
                1.5 + random.NextDouble() * 0.9,
                round,
                Colors[random.Next(Colors.Length)]));
        }
        _started = DateTime.UtcNow;
        _timer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => InvalidateVisual());
        _timer.Start();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        _timer?.Stop();
        _pieces.Clear();
    }

    public override void Render(DrawingContext context)
    {
        if (_pieces.Count == 0) return;
        var t = (DateTime.UtcNow - _started).TotalSeconds;
        var originX = Bounds.Width / 2;
        var originY = Bounds.Height / 2 - 160;
        var alive = false;

        foreach (var p in _pieces)
        {
            if (t >= p.Life) continue;
            alive = true;
            var progress = t / p.Life;
            var x = originX + p.SpeedX * Motion.EaseOut(progress) * 0.9;
            var y = originY + p.SpeedY * t + 900 * t * t;
            var opacity = progress < 0.65 ? 1 : 1 - (progress - 0.65) / 0.35;
            var matrix = Matrix.CreateRotation((p.Angle + p.Spin * progress) * Math.PI / 180) * Matrix.CreateTranslation(x, y);
            using (context.PushTransform(matrix))
            using (context.PushOpacity(opacity))
            {
                var rect = new Rect(-p.Width / 2, -p.Height / 2, p.Width, p.Height);
                context.DrawRectangle(p.Brush, null, rect, p.Round ? p.Width / 2 : 2, p.Round ? p.Width / 2 : 2);
            }
        }

        if (alive) return;
        _timer?.Stop();
        _pieces.Clear();
    }
}
