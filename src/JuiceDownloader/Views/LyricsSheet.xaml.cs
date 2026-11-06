using System.Windows.Controls;
using System.Windows.Input;

namespace JuiceDownloader.Views;

public partial class LyricsSheet : UserControl
{
    public LyricsSheet() => InitializeComponent();

    private void OnCardClick(object sender, MouseButtonEventArgs e) => e.Handled = true;
}
