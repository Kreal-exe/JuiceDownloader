using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Material.Icons;

namespace JuiceDownloader.Views;

/// <summary>An in-window confirmation: the card over a dimmed window, answered with the buttons, Enter or Esc.</summary>
public sealed partial class ConfirmDialog : UserControl
{
    private TaskCompletionSource<bool>? _answer;

    public ConfirmDialog()
    {
        InitializeComponent();
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) Close(false);
            else if (e.Key == Key.Enter) Close(true);
            else return;
            e.Handled = true;
        };
    }

    public Task<bool> ShowAsync(string title, string body, string okText, bool danger)
    {
        _answer?.TrySetResult(false);
        _answer = new TaskCompletionSource<bool>();

        TitleText.Text = title;
        BodyText.Text = body;
        OkButton.Content = okText;
        OkButton.Classes.Set("danger", danger);
        OkButton.Classes.Set("primary", !danger);
        Icon.Kind = danger ? MaterialIconKind.AlertCircleOutline : MaterialIconKind.TrayArrowDown;
        // Theme brushes live in the palette's theme dictionaries: follow them like {DynamicResource} would.
        Icon[!Material.Icons.Avalonia.MaterialIcon.ForegroundProperty] = this.GetResourceObservable(danger ? "Brush.Danger" : "Brush.Accent").ToBinding();
        IconTile[!Border.BackgroundProperty] = this.GetResourceObservable(danger ? "Brush.DangerSoft" : "Brush.AccentSoft").ToBinding();

        IsVisible = true;
        Focusable = true;
        Focus();
        return _answer.Task;
    }

    private void OnOk(object? sender, RoutedEventArgs e) => Close(true);

    private void OnCancel(object? sender, RoutedEventArgs e) => Close(false);

    private void Close(bool result)
    {
        IsVisible = false;
        _answer?.TrySetResult(result);
        _answer = null;
    }
}
