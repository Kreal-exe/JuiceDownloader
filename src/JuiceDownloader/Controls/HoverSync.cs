using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace JuiceDownloader.Controls;

/// <summary>
/// WPF works out what the pointer is over when the pointer moves. Rows scrolling or being recycled under a still pointer
/// keep their hover look until it does, so every scroll asks again, once the new layout is in place.
/// </summary>
public static class HoverSync
{
    public static readonly DependencyProperty IsEnabledProperty = DependencyProperty.RegisterAttached(
        "IsEnabled", typeof(bool), typeof(HoverSync), new PropertyMetadata(false, OnIsEnabledChanged));

    private static bool _queued;

    public static bool GetIsEnabled(DependencyObject d) => (bool)d.GetValue(IsEnabledProperty);
    public static void SetIsEnabled(DependencyObject d, bool value) => d.SetValue(IsEnabledProperty, value);

    private static void OnIsEnabledChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not ScrollViewer scroller) return;
        scroller.ScrollChanged -= OnScrollChanged;
        if ((bool)e.NewValue) scroller.ScrollChanged += OnScrollChanged;
    }

    private static void OnScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (e.VerticalChange == 0 && e.HorizontalChange == 0 && e.ExtentHeightChange == 0) return;
        if (_queued) return;
        _queued = true;
        ((ScrollViewer)sender).Dispatcher.InvokeAsync(() =>
        {
            _queued = false;
            Mouse.Synchronize();
        }, DispatcherPriority.Loaded);
    }
}
