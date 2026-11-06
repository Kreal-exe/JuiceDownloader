using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

public sealed partial class RulesView : UserControl
{
    public RulesView()
    {
        InitializeComponent();
        RowHover.Attach(List);
    }

    private void OnDownloadEnter(object? sender, PointerEventArgs e) => DownloadPopup.IsOpen = DownloadButton.IsEnabled;

    /// <summary>A moment to cross the gap: the list stays while the pointer is on it, so it can be scrolled.</summary>
    private void OnDownloadExit(object? sender, PointerEventArgs e) => DispatcherTimer.RunOnce(() =>
    {
        if (!DownloadButton.IsPointerOver && !DownloadPopupCard.IsPointerOver) DownloadPopup.IsOpen = false;
    }, TimeSpan.FromMilliseconds(250));

    private void OnDownloadClick(object? sender, RoutedEventArgs e) => DownloadPopup.IsOpen = false;

    /// <summary>The note on a song plays or pauses it.</summary>
    private void OnMarkPressed(object? sender, PointerPressedEventArgs e)
    {
        if ((sender as Control)?.DataContext is not RuleRowVm row) return;
        e.Handled = true;
        if (e.ClickCount == 1) row.PlayCommand.Execute(null);
    }

    private void OnMarkDoubleTapped(object? sender, TappedEventArgs e) => e.Handled = true;

    private void OnRowContext(object? sender, ContextRequestedEventArgs e)
    {
        if (sender is not Control { DataContext: RuleRowVm row } control) return;
        RowMenu.Show(control, row.Node, searching: false);
        e.Handled = true;
    }
}
