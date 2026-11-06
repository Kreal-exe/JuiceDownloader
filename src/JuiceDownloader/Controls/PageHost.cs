using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace JuiceDownloader.Controls;

/// <summary>Hosts one page at a time and cross-fades/slides between them.</summary>
public sealed class PageHost : Grid
{
    private UIElement? _current;

    public void Navigate(UIElement page, bool forward = true)
    {
        if (ReferenceEquals(page, _current)) return;

        var previous = _current;
        _current = page;

        if (!Children.Contains(page)) Children.Add(page);
        page.Visibility = Visibility.Visible;
        Panel.SetZIndex(page, 1);

        if (!Motion.Enabled)
        {
            page.Opacity = 1;
            if (previous is not null) previous.Visibility = Visibility.Collapsed;
            return;
        }

        var translate = Entrance.EnsureTranslate(page);
        page.Opacity = 0;
        var distance = forward ? 24 : -24;
        translate.Y = distance;

        page.BeginAnimation(UIElement.OpacityProperty, Motion.Double(0, 1, 320, Motion.EaseOut, 60));
        translate.BeginAnimation(TranslateTransform.YProperty, Motion.Double(distance, 0, 520, Motion.EaseOutStrong, 60));

        if (previous is null) return;

        Panel.SetZIndex(previous, 0);
        previous.IsHitTestVisible = false;
        var prevTranslate = Entrance.EnsureTranslate(previous);
        var fade = Motion.Double(null, 0, 160, Motion.EaseIn);
        fade.Completed += (_, _) =>
        {
            if (!ReferenceEquals(previous, _current))
            {
                previous.Visibility = Visibility.Collapsed;
            }
            previous.IsHitTestVisible = true;
        };
        previous.BeginAnimation(UIElement.OpacityProperty, fade);
        prevTranslate.BeginAnimation(TranslateTransform.YProperty, Motion.Double(null, -distance / 2.0, 160, Motion.EaseIn));
    }
}
