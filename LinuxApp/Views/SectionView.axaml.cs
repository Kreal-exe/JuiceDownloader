using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Threading;
using Avalonia.VisualTree;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

public sealed partial class SectionView : UserControl
{
    private SectionViewModel? _section;

    public SectionView()
    {
        InitializeComponent();
        RowHover.Attach(List, row => { if (_section is not null) _section.HoveredRow = row as RowVm; });
    }

    /// <summary>The Overview shows the list alone, under its own search.</summary>
    public bool ShowHeader
    {
        set => Header.IsVisible = value;
    }

    /// <summary>The note on a row plays or pauses it, a picture's icon previews it. A folder's icon stays part of the row.</summary>
    private void OnMarkPressed(object? sender, PointerPressedEventArgs e)
    {
        if ((sender as Control)?.DataContext is not RowVm { IsFile: true } row || !(row.IsPlayable || row.HasPreview)) return;
        e.Handled = true;
        if (e.ClickCount != 1) return;
        row.Play();
        row.ShowPreview();
    }

    private void OnMarkDoubleTapped(object? sender, TappedEventArgs e)
    {
        if ((sender as Control)?.DataContext is RowVm { IsFile: true } row && (row.IsPlayable || row.HasPreview)) e.Handled = true;
    }

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);
        if (_section is not null)
        {
            _section.Searched -= ScrollToTop;
            _section.Revealed -= OnRevealed;
        }
        _section = DataContext as SectionViewModel;
        if (_section is not null)
        {
            _section.Searched += ScrollToTop;
            _section.Revealed += OnRevealed;
        }

        // One view for ten pages: each opens at its top and enters like any other page.
        ScrollToTop();
        Body.IsVisible = false;
        Body.IsVisible = true;
    }

    private void ScrollToTop()
    {
        if (List.Scroll is { } scroll) scroll.Offset = default;
    }

    /// <summary>Scrolls to a row that was asked for and flashes it, once the list has laid out its new rows.</summary>
    private void OnRevealed(RowVm row)
    {
        Dispatcher.UIThread.Post(() =>
        {
            List.ScrollIntoView(row);
            Dispatcher.UIThread.Post(() =>
            {
                if (List.ContainerFromItem(row) is not { } container || RowHover.RowOf(container) is not { } button) return;
                button.Classes.Set("flash", true);
                DispatcherTimer.RunOnce(() => button.Classes.Set("flash", false), TimeSpan.FromSeconds(1.4));
            }, DispatcherPriority.Background);
        }, DispatcherPriority.Background);
    }

    private void OnRowDoubleTapped(object? sender, TappedEventArgs e)
    {
        // The row's own surface: its checkbox and buttons already did what their clicks mean.
        if ((e.Source as Visual)?.FindAncestorOfType<Button>(includeSelf: true) != sender) return;
        if ((e.Source as Visual)?.FindAncestorOfType<CheckBox>(includeSelf: true) is not null) return;
        if ((sender as Control)?.DataContext is not RowVm row) return;
        row.Play();
        row.ShowPreview();
    }

    private void OnRowContext(object? sender, ContextRequestedEventArgs e)
    {
        if (sender is not Control { DataContext: RowVm row } control) return;
        RowMenu.Show(control, row.Node, !string.IsNullOrWhiteSpace(_section?.Query));
        e.Handled = true;
    }
}
