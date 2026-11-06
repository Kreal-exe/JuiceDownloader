using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media.Transformation;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using JuiceDownloader.Controls;
using JuiceDownloader.Settings;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

public sealed partial class MainWindow : Window, IDialogService
{
    private AppSettings? _settings;
    private DispatcherTimer? _toastTimer;

    public MainWindow() => InitializeComponent();

    public void Attach(MainViewModel vm, AppSettings settings)
    {
        _settings = settings;
        DataContext = vm;
        vm.ToastRequested += ShowToast;
        // The keys of an open preview come before any field behind it, and Space before a button or list takes it.
        AddHandler(KeyDownEvent, (_, e) =>
        {
            if (Confirm.IsVisible) return;
            if (e.Key == Key.Space)
            {
                if (!vm.Preview.IsOpen && FocusManager?.GetFocusedElement() is TextBox or ComboBox) return;
                e.Handled = vm.OnSpace();
            }
            else if (vm.Preview.IsOpen && e.Key is Key.Left or Key.Right)
            {
                if (e.Key == Key.Left) vm.Preview.Previous();
                else vm.Preview.Next();
                e.Handled = true;
            }
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel);

        if (settings.WindowWidth >= MinWidth && settings.WindowHeight >= MinHeight)
        {
            Width = settings.WindowWidth;
            Height = settings.WindowHeight;
        }
        if (settings.WindowMaximized) WindowState = WindowState.Maximized;
    }

    protected override void OnClosing(WindowClosingEventArgs e)
    {
        base.OnClosing(e);
        if (_settings is null) return;
        _settings.WindowMaximized = WindowState == WindowState.Maximized;
        if (WindowState == WindowState.Normal)
        {
            _settings.WindowWidth = Bounds.Width;
            _settings.WindowHeight = Bounds.Height;
        }
        SettingsStore.Save(_settings);
    }

    private void ShowToast(string icon, string text)
    {
        ToastIcon.Kind = IconConverter.Parse(icon);
        ToastText.Text = text;
        Toast.Opacity = 1;
        Toast.RenderTransform = TransformOperations.Parse("translateY(0px)");

        _toastTimer?.Stop();
        _toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        _toastTimer.Tick += (_, _) =>
        {
            _toastTimer.Stop();
            Toast.Opacity = 0;
            Toast.RenderTransform = TransformOperations.Parse("translateY(-12px)");
        };
        _toastTimer.Start();
    }

    // ─────────────────────────── IDialogService ───────────────────────────

    public async Task CopyTextAsync(string text)
    {
        if (Clipboard is { } clipboard) await clipboard.SetTextAsync(text);
    }

    public Task<bool> ConfirmAsync(string title, string body, string okText, bool danger) => Confirm.ShowAsync(title, body, okText, danger);

    public async Task<string?> PickFolderAsync(string title)
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = title, AllowMultiple = false });
        return folders.Count > 0 ? folders[0].TryGetLocalPath() : null;
    }
}
