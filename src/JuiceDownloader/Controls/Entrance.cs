using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace JuiceDownloader.Controls;

/// <summary>
/// Fade + rise entrance animations.
/// <list type="bullet">
/// <item><c>anim:Entrance.Delay="120"</c> on any element plays once when it loads.</item>
/// <item><c>anim:Entrance.Stagger="45"</c> on an ItemsControl plays its containers one after another.</item>
/// <item><c>anim:Entrance.Replay="{Binding Flag}"</c> replays whenever the value becomes true.</item>
/// </list>
/// </summary>
public static class Entrance
{
    public static readonly DependencyProperty DelayProperty = DependencyProperty.RegisterAttached(
        "Delay", typeof(int), typeof(Entrance), new PropertyMetadata(-1, OnDelayChanged));

    public static readonly DependencyProperty StaggerProperty = DependencyProperty.RegisterAttached(
        "Stagger", typeof(int), typeof(Entrance), new PropertyMetadata(-1, OnStaggerChanged));

    public static readonly DependencyProperty ReplayProperty = DependencyProperty.RegisterAttached(
        "Replay", typeof(bool), typeof(Entrance), new PropertyMetadata(false, OnReplayChanged));

    public static readonly DependencyProperty DistanceProperty = DependencyProperty.RegisterAttached(
        "Distance", typeof(double), typeof(Entrance), new FrameworkPropertyMetadata(18.0, FrameworkPropertyMetadataOptions.Inherits));

    private static readonly DependencyProperty PlayedProperty = DependencyProperty.RegisterAttached(
        "Played", typeof(bool), typeof(Entrance), new PropertyMetadata(false));

    public static int GetDelay(DependencyObject d) => (int)d.GetValue(DelayProperty);
    public static void SetDelay(DependencyObject d, int value) => d.SetValue(DelayProperty, value);
    public static int GetStagger(DependencyObject d) => (int)d.GetValue(StaggerProperty);
    public static void SetStagger(DependencyObject d, int value) => d.SetValue(StaggerProperty, value);
    public static bool GetReplay(DependencyObject d) => (bool)d.GetValue(ReplayProperty);
    public static void SetReplay(DependencyObject d, bool value) => d.SetValue(ReplayProperty, value);
    public static double GetDistance(DependencyObject d) => (double)d.GetValue(DistanceProperty);
    public static void SetDistance(DependencyObject d, double value) => d.SetValue(DistanceProperty, value);

    private static void OnDelayChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not FrameworkElement fe || (int)e.NewValue < 0) return;

        if (fe.IsLoaded)
        {
            Play(fe, (int)e.NewValue);
        }
        else
        {
            fe.Opacity = 0;
            fe.Loaded += OnLoadedOnce;
        }
    }

    private static void OnLoadedOnce(object sender, RoutedEventArgs e)
    {
        var fe = (FrameworkElement)sender;
        fe.Loaded -= OnLoadedOnce;
        Play(fe, GetDelay(fe));
    }

    private static void OnReplayChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is FrameworkElement fe && (bool)e.NewValue)
        {
            Play(fe, Math.Max(0, GetDelay(fe)));
        }
    }

    private static void OnStaggerChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not ItemsControl ic) return;

        ic.ItemContainerGenerator.StatusChanged += (_, _) =>
        {
            if (ic.ItemContainerGenerator.Status == GeneratorStatus.ContainersGenerated)
                PlayContainers(ic);
        };
        ic.Loaded += (_, _) => PlayContainers(ic);
    }

    private static void PlayContainers(ItemsControl ic)
    {
        var stagger = GetStagger(ic);
        var index = 0;
        for (var i = 0; i < ic.Items.Count; i++)
        {
            if (ic.ItemContainerGenerator.ContainerFromIndex(i) is not FrameworkElement container) continue;
            if ((bool)container.GetValue(PlayedProperty)) continue;

            container.SetValue(PlayedProperty, true);
            Play(container, index * stagger);
            index++;
        }
    }

    public static void Play(FrameworkElement fe, int delayMs)
    {
        if (!Motion.Enabled)
        {
            fe.BeginAnimation(UIElement.OpacityProperty, null);
            fe.Opacity = 1;
            return;
        }

        var translate = EnsureTranslate(fe);
        var distance = GetDistance(fe);

        fe.Opacity = 0;
        translate.Y = distance;

        fe.BeginAnimation(UIElement.OpacityProperty, Motion.Double(0, 1, 380, Motion.EaseOut, delayMs));
        translate.BeginAnimation(TranslateTransform.YProperty, Motion.Double(distance, 0, 560, Motion.EaseOutStrong, delayMs));
    }

    /// <summary>Finds or installs a TranslateTransform on the element without clobbering other transforms.</summary>
    internal static TranslateTransform EnsureTranslate(UIElement element)
    {
        switch (element.RenderTransform)
        {
            case TranslateTransform t:
                return t;
            case TransformGroup g:
                foreach (var child in g.Children)
                    if (child is TranslateTransform existing) return existing;
                var added = new TranslateTransform();
                g.Children.Add(added);
                return added;
            default:
                var group = new TransformGroup();
                if (element.RenderTransform is { } other && other != Transform.Identity)
                    group.Children.Add(other);
                var translate = new TranslateTransform();
                group.Children.Add(translate);
                element.RenderTransform = group;
                return translate;
        }
    }
}
