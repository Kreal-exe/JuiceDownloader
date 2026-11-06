using System.Collections;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Reflection;
using System.Windows;
using System.Windows.Media;

namespace JuiceDownloader.Controls;

/// <summary>
/// A stacked, proportional bar. Binds to a collection of items exposing a weight (double/long) and a Brush;
/// every change tweens from the previous layout to the new one.
/// </summary>
public sealed class SegmentBar : FrameworkElement
{
    public static readonly DependencyProperty ItemsSourceProperty = DependencyProperty.Register(
        nameof(ItemsSource), typeof(IEnumerable), typeof(SegmentBar), new PropertyMetadata(null, OnItemsSourceChanged));

    public static readonly DependencyProperty WeightPathProperty = DependencyProperty.Register(
        nameof(WeightPath), typeof(string), typeof(SegmentBar), new PropertyMetadata("Bytes"));

    public static readonly DependencyProperty BrushPathProperty = DependencyProperty.Register(
        nameof(BrushPath), typeof(string), typeof(SegmentBar), new PropertyMetadata("Brush"));

    public static readonly DependencyProperty TrackProperty = DependencyProperty.Register(
        nameof(Track), typeof(Brush), typeof(SegmentBar),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty GapProperty = DependencyProperty.Register(
        nameof(Gap), typeof(double), typeof(SegmentBar),
        new FrameworkPropertyMetadata(3.0, FrameworkPropertyMetadataOptions.AffectsRender));

    /// <summary>When larger than the items' sum, the bar is that much (a whole disk): the rest of the track stays empty.</summary>
    public static readonly DependencyProperty TotalProperty = DependencyProperty.Register(
        nameof(Total), typeof(double), typeof(SegmentBar),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ProgressProperty = DependencyProperty.Register(
        nameof(Progress), typeof(double), typeof(SegmentBar),
        new FrameworkPropertyMetadata(1.0, FrameworkPropertyMetadataOptions.AffectsRender));

    static SegmentBar()
    {
        HeightProperty.OverrideMetadata(typeof(SegmentBar), new FrameworkPropertyMetadata(10.0));
    }

    private readonly List<Segment> _segments = [];
    private bool _refreshQueued;

    public IEnumerable? ItemsSource { get => (IEnumerable?)GetValue(ItemsSourceProperty); set => SetValue(ItemsSourceProperty, value); }
    public string WeightPath { get => (string)GetValue(WeightPathProperty); set => SetValue(WeightPathProperty, value); }
    public string BrushPath { get => (string)GetValue(BrushPathProperty); set => SetValue(BrushPathProperty, value); }
    public Brush Track { get => (Brush)GetValue(TrackProperty); set => SetValue(TrackProperty, value); }
    public double Gap { get => (double)GetValue(GapProperty); set => SetValue(GapProperty, value); }
    public double Progress { get => (double)GetValue(ProgressProperty); set => SetValue(ProgressProperty, value); }
    public double Total { get => (double)GetValue(TotalProperty); set => SetValue(TotalProperty, value); }

    /// <summary>Run with the clicked segment's item; segments are clickable only when it is set.</summary>
    public static readonly DependencyProperty CommandProperty = DependencyProperty.Register(
        nameof(Command), typeof(System.Windows.Input.ICommand), typeof(SegmentBar), new PropertyMetadata(null, (d, _) =>
            ((SegmentBar)d).Cursor = ((SegmentBar)d).Command is null ? null : System.Windows.Input.Cursors.Hand));

    public System.Windows.Input.ICommand? Command { get => (System.Windows.Input.ICommand?)GetValue(CommandProperty); set => SetValue(CommandProperty, value); }

    // Where each segment was last drawn, for clicks.
    private readonly List<(double From, double To, object Item)> _hits = [];

    protected override void OnMouseLeftButtonUp(System.Windows.Input.MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (Command is null) return;
        var x = e.GetPosition(this).X;
        foreach (var (from, to, item) in _hits)
        {
            if (x < from - Gap / 2 || x > to + Gap / 2) continue;
            if (Command.CanExecute(item)) Command.Execute(item);
            e.Handled = true;
            return;
        }
    }

    // Keeps the bar hit-testable over its whole width, gaps and track included.
    protected override HitTestResult? HitTestCore(PointHitTestParameters p)
        => new Rect(RenderSize).Contains(p.HitPoint) ? new PointHitTestResult(this, p.HitPoint) : null;

    private static void OnItemsSourceChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var bar = (SegmentBar)d;

        if (e.OldValue is IEnumerable old)
        {
            if (old is INotifyCollectionChanged oldCc) oldCc.CollectionChanged -= bar.OnCollectionChanged;
            foreach (var item in old) if (item is INotifyPropertyChanged npc) npc.PropertyChanged -= bar.OnItemChanged;
        }

        if (e.NewValue is IEnumerable items)
        {
            if (items is INotifyCollectionChanged cc) cc.CollectionChanged += bar.OnCollectionChanged;
            foreach (var item in items) if (item is INotifyPropertyChanged npc) npc.PropertyChanged += bar.OnItemChanged;
        }

        bar.QueueRefresh();
    }

    private void OnCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.OldItems is not null)
            foreach (var item in e.OldItems) if (item is INotifyPropertyChanged npc) npc.PropertyChanged -= OnItemChanged;
        if (e.NewItems is not null)
            foreach (var item in e.NewItems) if (item is INotifyPropertyChanged npc) npc.PropertyChanged += OnItemChanged;
        QueueRefresh();
    }

    private void OnItemChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (string.IsNullOrEmpty(e.PropertyName) || e.PropertyName == WeightPath || e.PropertyName == BrushPath)
            QueueRefresh();
    }

    private void QueueRefresh()
    {
        if (_refreshQueued) return;
        _refreshQueued = true;
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Render, () =>
        {
            _refreshQueued = false;
            Refresh();
        });
    }

    private void Refresh()
    {
        var eased = Ease(Math.Clamp(Progress, 0, 1));
        var current = _segments.ToDictionary(s => s.Item, s => s.From + (s.To - s.From) * eased);

        _segments.Clear();
        if (ItemsSource is { } items)
        {
            foreach (var item in items)
            {
                if (item is null) continue;
                var weight = ReadWeight(item);
                var brush = ReadBrush(item) ?? Brushes.Gray;
                var from = current.TryGetValue(item, out var prev) ? prev : 0;
                _segments.Add(new Segment(item, from, weight, brush));
            }
        }

        BeginAnimation(ProgressProperty, null);
        if (!Motion.Enabled || !IsLoaded)
        {
            Progress = 1;
            InvalidateVisual();
            return;
        }

        Progress = 0;
        BeginAnimation(ProgressProperty, Motion.Double(0, 1, 900, Motion.EaseOutStrong));
    }

    private double ReadWeight(object item)
    {
        var prop = item.GetType().GetProperty(WeightPath, BindingFlags.Public | BindingFlags.Instance);
        var value = prop?.GetValue(item);
        return value switch
        {
            double d => d,
            float f => f,
            long l => l,
            int i => i,
            decimal m => (double)m,
            _ => 0,
        };
    }

    private Brush? ReadBrush(object item)
    {
        var prop = item.GetType().GetProperty(BrushPath, BindingFlags.Public | BindingFlags.Instance);
        return prop?.GetValue(item) as Brush;
    }

    private static double Ease(double t) => 1 - Math.Pow(1 - t, 5);

    protected override Size MeasureOverride(Size availableSize)
        => new(double.IsInfinity(availableSize.Width) ? 0 : availableSize.Width, Height);

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        var radius = h / 2;
        _hits.Clear();
        dc.DrawRoundedRectangle(Track, null, new Rect(0, 0, w, h), radius, radius);

        var eased = Ease(Math.Clamp(Progress, 0, 1));
        var widths = _segments.Select(s => Math.Max(0, s.From + (s.To - s.From) * eased)).ToList();
        var sum = widths.Sum();
        if (sum <= 0) return;
        var total = Math.Max(sum, Total);

        var visible = widths.Count(x => x / total * w >= 1);
        var available = w - Gap * Math.Max(0, visible - 1);
        if (available <= 0) return;

        dc.PushClip(new RectangleGeometry(new Rect(0, 0, w, h), radius, radius));
        double x = 0;
        for (var i = 0; i < _segments.Count; i++)
        {
            var segWidth = widths[i] / total * available;
            if (segWidth < 1) continue;
            dc.DrawRectangle(_segments[i].Brush, null, new Rect(x, 0, segWidth, h));
            _hits.Add((x, x + segWidth, _segments[i].Item));
            x += segWidth + Gap;
        }
        dc.Pop();
    }

    private sealed record Segment(object Item, double From, double To, Brush Brush);
}
