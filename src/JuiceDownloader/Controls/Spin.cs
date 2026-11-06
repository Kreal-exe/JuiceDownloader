using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace JuiceDownloader.Controls;

/// <summary>
/// Turns an element while <c>c:Spin.IsActive</c> is true. Unlike a storyboard started on load, it costs nothing while
/// nothing is going on.
/// </summary>
public static class Spin
{
    public static readonly DependencyProperty IsActiveProperty = DependencyProperty.RegisterAttached(
        "IsActive", typeof(bool), typeof(Spin), new PropertyMetadata(false, OnIsActiveChanged));

    public static bool GetIsActive(DependencyObject d) => (bool)d.GetValue(IsActiveProperty);
    public static void SetIsActive(DependencyObject d, bool value) => d.SetValue(IsActiveProperty, value);

    private static void OnIsActiveChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not UIElement element) return;

        if (element.RenderTransform is not RotateTransform rotate)
        {
            rotate = new RotateTransform();
            element.RenderTransform = rotate;
            element.RenderTransformOrigin = new Point(0.5, 0.5);
        }

        rotate.BeginAnimation(RotateTransform.AngleProperty, (bool)e.NewValue
            ? new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.9)) { RepeatBehavior = RepeatBehavior.Forever }
            : null);
    }
}
