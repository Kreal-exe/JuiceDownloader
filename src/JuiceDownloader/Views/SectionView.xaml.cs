using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

/// <summary>
/// A list that replaces its rows whenever a folder opens, since inserting thousands of lines one by one is far slower.
/// Replacing them must not move what the user is looking at, so the offset is carried across.
/// </summary>
public partial class SectionView : UserControl
{
    private SectionViewModel? _vm;
    private double _offset;

    /// <summary>The Overview shows the list alone, under its own search.</summary>
    public bool ShowHeader
    {
        set => Header.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    }

    public SectionView()
    {
        InitializeComponent();
        DataContextChanged += (_, e) =>
        {
            if (_vm is not null)
            {
                _vm.PropertyChanging -= OnRowsChanging;
                _vm.PropertyChanged -= OnRowsChanged;
                _vm.RevealRequested -= OnRevealRequested;
            }
            _vm = e.NewValue as SectionViewModel;
            if (_vm is null) return;
            _vm.PropertyChanging += OnRowsChanging;
            _vm.PropertyChanged += OnRowsChanged;
            _vm.RevealRequested += OnRevealRequested;
        };
    }

    // Below the priority of the offset being restored, and of the layout of a page that has only just been shown.
    private void OnRevealRequested(LibraryRowVm row) =>
        Dispatcher.InvokeAsync(() => List.ScrollIntoView(row), DispatcherPriority.Background);

    private void OnRightClick(object sender, MouseButtonEventArgs e) =>
        e.Handled = RowMenu.TryOpen(e.OriginalSource, List, _vm?.Owner, _vm?.IsSearching == true);

    private ScrollViewer? Scroller
    {
        get
        {
            List.ApplyTemplate();
            return List.Template?.FindName("Scroller", List) as ScrollViewer;
        }
    }

    private void OnRowsChanging(object? sender, PropertyChangingEventArgs e)
    {
        if (e.PropertyName == nameof(SectionViewModel.Rows)) _offset = Scroller?.VerticalOffset ?? 0;
    }

    private void OnRowsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(SectionViewModel.Rows) || _vm is null) return;
        var offset = _vm.KeepScroll ? _offset : 0;
        Dispatcher.InvokeAsync(() => Scroller?.ScrollToVerticalOffset(offset), DispatcherPriority.Loaded);
    }
}
