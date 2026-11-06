using System.Diagnostics;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace JuiceDownloader.Views;

/// <summary>A click shakes the juice box, each time differently: how hard, how fast and for how long are left to chance.</summary>
public partial class Logo : UserControl
{
    private readonly RotateTransform _turn = new();
    private readonly TranslateTransform _move = new();
    private readonly DispatcherTimer _timer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(16) };
    private readonly Stopwatch _clock = new();
    private double _degrees, _hop, _rate, _seconds, _phase;

    public Logo()
    {
        InitializeComponent();
        RenderTransformOrigin = new System.Windows.Point(0.5, 0.5);
        RenderTransform = new TransformGroup { Children = { _turn, _move } };
        _timer.Tick += (_, _) => Step();
        MouseLeftButtonDown += OnClicked;
    }

    private void OnClicked(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        var random = Random.Shared;
        _degrees = (6 + random.NextDouble() * 36) * (random.Next(2) == 0 ? 1 : -1);
        _hop = random.NextDouble() * 5;
        _rate = 3 + random.NextDouble() * 6;
        _seconds = 0.45 + random.NextDouble() * 0.75;
        _phase = random.NextDouble() * Math.PI * 2;
        _clock.Restart();
        _timer.Start();
    }

    private void Step()
    {
        var t = _clock.Elapsed.TotalSeconds;
        if (t >= _seconds)
        {
            _timer.Stop();
            _turn.Angle = _move.X = _move.Y = 0;
            return;
        }
        var fade = Math.Pow(1 - t / _seconds, 2);
        _turn.Angle = _degrees * fade * Math.Sin(2 * Math.PI * _rate * t);
        _move.X = _hop * fade * Math.Sin(2 * Math.PI * _rate * 1.3 * t + _phase);
        _move.Y = _hop * 0.6 * fade * Math.Sin(2 * Math.PI * _rate * 0.7 * t + _phase);
    }
}
