using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using JuiceDownloader.Controls;

namespace JuiceDownloader.Views;

public partial class ConfirmDialog : UserControl
{
    private TaskCompletionSource<bool>? _pending;

    public ConfirmDialog()
    {
        InitializeComponent();
        PreviewKeyDown += OnKeyDown;
    }

    public Task<bool> ShowAsync(string title, string body, string okText, bool danger)
    {
        _pending?.TrySetResult(false);
        _pending = new TaskCompletionSource<bool>();

        TitleText.Text = title;
        BodyText.Text = body;
        OkButton.Content = okText;
        OkButton.Style = (Style)FindResource(danger ? "DangerButton" : "PrimaryButton");
        IconTile.Background = (Brush)FindResource(danger ? "Brush.DangerSoft" : "Brush.AccentSoft");
        IconGlyph.Foreground = (Brush)FindResource(danger ? "Brush.Danger" : "Brush.Accent");
        IconGlyph.Text = danger ? "\uE7BA" : "\uE896";
        CancelButton.Visibility = okText == Localization.LocalizationManager.Instance["common.ok"] ? Visibility.Collapsed : Visibility.Visible;

        Visibility = Visibility.Visible;
        Focus();

        if (Motion.Enabled)
        {
            Root.Opacity = 0;
            CardScale.ScaleX = CardScale.ScaleY = 0.94;
            CardT.Y = 18;
            Root.BeginAnimation(OpacityProperty, Motion.Double(0, 1, 200));
            CardScale.BeginAnimation(ScaleTransform.ScaleXProperty, Motion.Double(0.94, 1, 420, Motion.Spring));
            CardScale.BeginAnimation(ScaleTransform.ScaleYProperty, Motion.Double(0.94, 1, 420, Motion.Spring));
            CardT.BeginAnimation(TranslateTransform.YProperty, Motion.Double(18, 0, 420, Motion.EaseOutStrong));
        }
        else
        {
            Root.Opacity = 1;
        }

        return _pending.Task;
    }

    private void Close(bool result)
    {
        var pending = _pending;
        _pending = null;

        if (!Motion.Enabled)
        {
            Visibility = Visibility.Collapsed;
            pending?.TrySetResult(result);
            return;
        }

        var fade = Motion.Double(null, 0, 160, Motion.EaseIn);
        fade.Completed += (_, _) => Visibility = Visibility.Collapsed;
        Root.BeginAnimation(OpacityProperty, fade);
        CardScale.BeginAnimation(ScaleTransform.ScaleXProperty, Motion.Double(null, 0.96, 160, Motion.EaseIn));
        CardScale.BeginAnimation(ScaleTransform.ScaleYProperty, Motion.Double(null, 0.96, 160, Motion.EaseIn));
        pending?.TrySetResult(result);
    }

    private void OnOk(object sender, RoutedEventArgs e) => Close(true);
    private void OnCancel(object sender, RoutedEventArgs e) => Close(false);
    private void OnBackgroundClick(object sender, MouseButtonEventArgs e) => Close(false);
    private void OnCardClick(object sender, MouseButtonEventArgs e) => e.Handled = true;

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (_pending is null) return;
        if (e.Key == Key.Escape) { Close(false); e.Handled = true; }
        else if (e.Key == Key.Enter) { Close(true); e.Handled = true; }
    }
}
