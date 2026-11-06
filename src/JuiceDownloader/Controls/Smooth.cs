using System.ComponentModel;
using System.Windows;
using System.Windows.Media.Animation;

namespace JuiceDownloader.Controls;

/// <summary>
/// Tweens any double dependency property towards a bound value:
/// <c>anim:Smooth.Property="EndAngle" anim:Smooth.Value="{Binding RingAngle}"</c>.
/// </summary>
public static class Smooth
{
    public static readonly DependencyProperty PropertyProperty = DependencyProperty.RegisterAttached(
        "Property", typeof(string), typeof(Smooth), new PropertyMetadata(null));

    public static readonly DependencyProperty ValueProperty = DependencyProperty.RegisterAttached(
        "Value", typeof(double), typeof(Smooth), new PropertyMetadata(0.0, OnValueChanged));

    public static readonly DependencyProperty DurationProperty = DependencyProperty.RegisterAttached(
        "Duration", typeof(int), typeof(Smooth), new PropertyMetadata(800));

    public static string? GetProperty(DependencyObject d) => (string?)d.GetValue(PropertyProperty);
    public static void SetProperty(DependencyObject d, string? value) => d.SetValue(PropertyProperty, value);
    public static double GetValue(DependencyObject d) => (double)d.GetValue(ValueProperty);
    public static void SetValue(DependencyObject d, double value) => d.SetValue(ValueProperty, value);
    public static int GetDuration(DependencyObject d) => (int)d.GetValue(DurationProperty);
    public static void SetDuration(DependencyObject d, int value) => d.SetValue(DurationProperty, value);

    private static void OnValueChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not IAnimatable animatable) return;
        var name = GetProperty(d);
        if (string.IsNullOrEmpty(name)) return;

        var dp = DependencyPropertyDescriptor.FromName(name, d.GetType(), d.GetType())?.DependencyProperty;
        if (dp is null) return;

        var to = (double)e.NewValue;
        if (!Motion.Enabled)
        {
            animatable.BeginAnimation(dp, null);
            d.SetValue(dp, to);
            return;
        }

        animatable.BeginAnimation(dp, Motion.Double(null, to, GetDuration(d), Motion.EaseOutStrong));
    }
}
