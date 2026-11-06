using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;

namespace JuiceDownloader.Controls;

/// <summary>
/// Breathing glow for gradient buttons: <c>anim:Pulse.IsActive="{Binding CanClean}"</c>.
/// Animates the "Glow" element of <c>GradientButtonTemplate</c> while active.
/// </summary>
public static class Pulse
{
    public static readonly DependencyProperty IsActiveProperty = DependencyProperty.RegisterAttached(
        "IsActive", typeof(bool), typeof(Pulse), new PropertyMetadata(false, OnIsActiveChanged));

    public static bool GetIsActive(DependencyObject d) => (bool)d.GetValue(IsActiveProperty);
    public static void SetIsActive(DependencyObject d, bool value) => d.SetValue(IsActiveProperty, value);

    private static void OnIsActiveChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not Control control) return;

        if (!control.IsLoaded)
        {
            control.Loaded += (_, _) => Apply(control, GetIsActive(control));
            return;
        }

        Apply(control, (bool)e.NewValue);
    }

    private static void Apply(Control control, bool active)
    {
        control.ApplyTemplate();
        if (control.Template?.FindName("Glow", control) is not FrameworkElement glow) return;

        if (!active || !Motion.Enabled)
        {
            glow.BeginAnimation(UIElement.OpacityProperty, null);
            return;
        }

        var breathe = new DoubleAnimation(0.45, 0.95, TimeSpan.FromMilliseconds(1400))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        };
        glow.BeginAnimation(UIElement.OpacityProperty, breathe);
    }
}
