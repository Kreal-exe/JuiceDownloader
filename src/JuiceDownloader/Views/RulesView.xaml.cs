using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

public partial class RulesView : UserControl
{
    private double _offset;

    public RulesView()
    {
        InitializeComponent();
        DataContextChanged += (_, e) =>
        {
            if (e.NewValue is not RulesViewModel vm) return;
            // Opening a song replaces the rows: what the user is looking at stays where it is.
            vm.PropertyChanging += (_, a) =>
            {
                if (a.PropertyName == nameof(RulesViewModel.Rows)) _offset = Scroller?.VerticalOffset ?? 0;
            };
            vm.PropertyChanged += (_, a) =>
            {
                if (a.PropertyName != nameof(RulesViewModel.Rows)) return;
                var offset = _offset;
                Dispatcher.InvokeAsync(() => Scroller?.ScrollToVerticalOffset(offset), DispatcherPriority.Loaded);
            };
        };
    }

    private void OnDownloadEnter(object sender, MouseEventArgs e) => DownloadPopup.IsOpen = DownloadButton.IsEnabled;

    /// <summary>A moment to cross the gap: the list stays while the pointer is on it, so it can be scrolled.</summary>
    private void OnDownloadLeave(object sender, MouseEventArgs e)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (!DownloadButton.IsMouseOver && DownloadPopup.Child?.IsMouseOver != true) DownloadPopup.IsOpen = false;
        };
        timer.Start();
    }

    private void OnDownloadClick(object sender, RoutedEventArgs e) => DownloadPopup.IsOpen = false;

    private ScrollViewer? Scroller
    {
        get
        {
            List.ApplyTemplate();
            return List.Template?.FindName("Scroller", List) as ScrollViewer;
        }
    }

    /// <summary>The list always keeps some room: on a short window the rules above it scroll instead.</summary>
    private void OnRootSizeChanged(object sender, SizeChangedEventArgs e) => HeaderRow.MaxHeight = Math.Max(120, e.NewSize.Height - 180);

    private void OnRightClick(object sender, MouseButtonEventArgs e) =>
        e.Handled = RowMenu.TryOpen(e.OriginalSource, List, Window.GetWindow(this)?.DataContext as MainViewModel, searching: true);
}
