using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using JuiceDownloader.Core;

namespace JuiceDownloader.Controls;

public enum CounterPart { All, Number, Unit, Integer }

/// <summary>
/// Attached behaviour that tweens a TextBlock between byte values:
/// <c>anim:Counter.Bytes="{Binding TotalBytes}" anim:Counter.Part="Number"</c>.
/// </summary>
public static class Counter
{
    public static readonly DependencyProperty BytesProperty = DependencyProperty.RegisterAttached(
        "Bytes", typeof(long), typeof(Counter), new PropertyMetadata(0L, OnBytesChanged));

    public static readonly DependencyProperty PartProperty = DependencyProperty.RegisterAttached(
        "Part", typeof(CounterPart), typeof(Counter), new PropertyMetadata(CounterPart.All, OnPartChanged));

    public static readonly DependencyProperty DurationProperty = DependencyProperty.RegisterAttached(
        "Duration", typeof(int), typeof(Counter), new PropertyMetadata(700));

    private static readonly DependencyProperty CurrentProperty = DependencyProperty.RegisterAttached(
        "Current", typeof(double), typeof(Counter), new PropertyMetadata(0.0, OnCurrentChanged));

    private static readonly DependencyProperty InitializedProperty = DependencyProperty.RegisterAttached(
        "Initialized", typeof(bool), typeof(Counter), new PropertyMetadata(false));

    public static long GetBytes(DependencyObject d) => (long)d.GetValue(BytesProperty);
    public static void SetBytes(DependencyObject d, long value) => d.SetValue(BytesProperty, value);

    public static CounterPart GetPart(DependencyObject d) => (CounterPart)d.GetValue(PartProperty);
    public static void SetPart(DependencyObject d, CounterPart value) => d.SetValue(PartProperty, value);

    public static int GetDuration(DependencyObject d) => (int)d.GetValue(DurationProperty);
    public static void SetDuration(DependencyObject d, int value) => d.SetValue(DurationProperty, value);

    private static void OnBytesChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not TextBlock tb) return;

        var to = (double)(long)e.NewValue;
        var first = !(bool)tb.GetValue(InitializedProperty);
        tb.SetValue(InitializedProperty, true);

        if (first || !Motion.Enabled || !tb.IsLoaded)
        {
            tb.BeginAnimation(CurrentProperty, null);
            tb.SetValue(CurrentProperty, to);
            return;
        }

        var from = (double)tb.GetValue(CurrentProperty);
        if (Math.Abs(from - to) < 0.5) return;

        // Big jumps get a little longer so the digits are readable while they spin.
        var ms = GetDuration(tb);
        tb.BeginAnimation(CurrentProperty, Motion.Double(from, to, ms, Motion.EaseOutStrong));
    }

    private static void OnPartChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is TextBlock tb) Render(tb, (double)tb.GetValue(CurrentProperty));
    }

    private static void OnCurrentChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is TextBlock tb) Render(tb, (double)e.NewValue);
    }

    private static void Render(TextBlock tb, double value)
    {
        var part = GetPart(tb);
        switch (part)
        {
            case CounterPart.Integer:
                tb.Text = Math.Round(value).ToString("N0", CultureInfo.CurrentCulture);
                break;
            case CounterPart.Number:
                tb.Text = ByteFormatter.Split(value).Number;
                break;
            case CounterPart.Unit:
                tb.Text = ByteFormatter.Split(value).Unit;
                break;
            default:
                tb.Text = ByteFormatter.Format(value);
                break;
        }
    }
}
