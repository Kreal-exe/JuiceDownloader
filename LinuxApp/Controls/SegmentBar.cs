using System.Collections;
using System.Collections.Specialized;
using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace JuiceDownloader.Controls;

public interface ISegment
{
    long Bytes { get; }
    IBrush Brush { get; }
}

/// <summary>
/// A stacked bar: one coloured segment per item (the selected bytes of each section), sized by its share of the sum, or
/// of <see cref="Total"/> when set (the rest of the track is then what is not selected).
/// </summary>
public sealed class SegmentBar : Control
{
    public static readonly StyledProperty<IEnumerable?> ItemsSourceProperty = AvaloniaProperty.Register<SegmentBar, IEnumerable?>(nameof(ItemsSource));
    public static readonly StyledProperty<IBrush?> TrackProperty = AvaloniaProperty.Register<SegmentBar, IBrush?>(nameof(Track));
    public static readonly StyledProperty<long> TotalProperty = AvaloniaProperty.Register<SegmentBar, long>(nameof(Total));
    public static readonly StyledProperty<double> GapProperty = AvaloniaProperty.Register<SegmentBar, double>(nameof(Gap), 4);

    private readonly List<ISegment> _watched = [];

    static SegmentBar()
    {
        AffectsRender<SegmentBar>(TrackProperty, TotalProperty, GapProperty);
    }

    public IEnumerable? ItemsSource { get => GetValue(ItemsSourceProperty); set => SetValue(ItemsSourceProperty, value); }
    public IBrush? Track { get => GetValue(TrackProperty); set => SetValue(TrackProperty, value); }
    public long Total { get => GetValue(TotalProperty); set => SetValue(TotalProperty, value); }
    public double Gap { get => GetValue(GapProperty); set => SetValue(GapProperty, value); }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property != ItemsSourceProperty) return;
        if (change.OldValue is INotifyCollectionChanged oldList) oldList.CollectionChanged -= OnCollectionChanged;
        if (change.NewValue is INotifyCollectionChanged newList) newList.CollectionChanged += OnCollectionChanged;
        Rewatch();
    }

    private void OnCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) => Rewatch();

    private void Rewatch()
    {
        foreach (var c in _watched.OfType<INotifyPropertyChanged>()) c.PropertyChanged -= OnItemChanged;
        _watched.Clear();
        if (ItemsSource is not null)
            foreach (var c in ItemsSource.OfType<ISegment>())
            {
                if (c is INotifyPropertyChanged n) n.PropertyChanged += OnItemChanged;
                _watched.Add(c);
            }
        InvalidateVisual();
    }

    private void OnItemChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ISegment.Bytes)) InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        if (bounds.Width <= 0 || bounds.Height <= 0) return;
        var radius = bounds.Height / 2;
        if (Track is { } track) context.DrawRectangle(track, null, bounds, radius, radius);

        var parts = _watched.Where(c => c.Bytes > 0).ToList();
        var sum = (double)parts.Sum(c => c.Bytes);
        if (sum <= 0) return;
        var total = Math.Max(sum, Total);

        var gap = Gap;
        var usable = (bounds.Width - gap * (parts.Count - 1)) * (sum / total);
        var x = 0.0;
        foreach (var part in parts)
        {
            var width = Math.Max(bounds.Height, usable * part.Bytes / sum);
            width = Math.Min(width, bounds.Width - x);
            if (width <= 0) break;
            context.DrawRectangle(part.Brush, null, new Rect(x, 0, width, bounds.Height), radius, radius);
            x += width + gap;
        }
    }
}
