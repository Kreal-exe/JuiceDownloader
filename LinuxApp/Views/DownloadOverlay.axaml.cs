using Avalonia.Controls;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

public sealed partial class DownloadOverlay : UserControl
{
    private DownloadViewModel? _vm;

    public DownloadOverlay() => InitializeComponent();

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);
        if (_vm is not null) _vm.Celebrate -= Burst.Burst;
        _vm = DataContext as DownloadViewModel;
        if (_vm is not null) _vm.Celebrate += Burst.Burst;
    }
}
