using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;
using JuiceDownloader.Core;

namespace JuiceDownloader.Controls;

public enum CounterPart { All, Number, Unit }

/// <summary>A TextBlock that tweens between byte values: <c>&lt;c:CounterText Bytes="{Binding TotalBytes}" Part="Number" /&gt;</c>.</summary>
public sealed class CounterText : TextBlock
{
    public static readonly StyledProperty<long> BytesProperty = AvaloniaProperty.Register<CounterText, long>(nameof(Bytes));
    public static readonly StyledProperty<CounterPart> PartProperty = AvaloniaProperty.Register<CounterText, CounterPart>(nameof(Part));
    public static readonly StyledProperty<int> DurationProperty = AvaloniaProperty.Register<CounterText, int>(nameof(Duration), 700);

    private DispatcherTimer? _timer;
    private double _current;
    private double _from;
    private double _to;
    private DateTime _started;
    private bool _initialized;

    protected override Type StyleKeyOverride => typeof(TextBlock);

    public long Bytes { get => GetValue(BytesProperty); set => SetValue(BytesProperty, value); }
    public CounterPart Part { get => GetValue(PartProperty); set => SetValue(PartProperty, value); }
    public int Duration { get => GetValue(DurationProperty); set => SetValue(DurationProperty, value); }

    public CounterText() => Render(0);

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == BytesProperty) OnBytesChanged(change.GetNewValue<long>());
        else if (change.Property == PartProperty) Render(_current);
    }

    private void OnBytesChanged(long bytes)
    {
        var first = !_initialized;
        _initialized = true;
        if (first || !Motion.Enabled || !IsLoaded)
        {
            _timer?.Stop();
            Render(bytes);
            return;
        }

        if (Math.Abs(_current - bytes) < 0.5) return;
        _from = _current;
        _to = bytes;
        _started = DateTime.UtcNow;
        _timer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => Tick());
        _timer.Start();
    }

    private void Tick()
    {
        var t = (DateTime.UtcNow - _started).TotalMilliseconds / Math.Max(1, Duration);
        if (t >= 1)
        {
            _timer?.Stop();
            Render(_to);
            return;
        }
        Render(_from + (_to - _from) * Motion.EaseOut(t));
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        if (_timer?.IsEnabled == true)
        {
            _timer.Stop();
            Render(_to);
        }
    }

    private void Render(double value)
    {
        _current = value;
        Text = Part switch
        {
            CounterPart.Number => ByteFormatter.Split(value).Number,
            CounterPart.Unit => ByteFormatter.Split(value).Unit,
            _ => ByteFormatter.Format(value),
        };
    }
}
