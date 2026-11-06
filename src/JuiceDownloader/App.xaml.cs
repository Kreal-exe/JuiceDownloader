using System.Windows;
using System.Windows.Threading;
using JuiceDownloader.Controls;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;
using JuiceDownloader.ViewModels;
using JuiceDownloader.Views;

namespace JuiceDownloader;

public partial class App : Application
{
    public static AppSettings Settings { get; private set; } = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        DispatcherUnhandledException += OnUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            MessageBox.Show(args.ExceptionObject.ToString(), "JuiceDownloader", MessageBoxButton.OK, MessageBoxImage.Error);

        Settings = SettingsStore.Load();
        Motion.Enabled = Settings.Animations;
        LocalizationManager.Instance.Apply(Settings.Language);
        ThemeManager.Apply(Settings.Theme);

        var window = new MainWindow();
        var vm = new MainViewModel(Settings, window);
        window.DataContext = vm;
        MainWindow = window;

        // Hidden switch used by screenshots/tests: --page <name>
        var args = e.Args;
        for (var i = 0; i < args.Length - 1; i++)
        {
            if (args[i].Equals("--page", StringComparison.OrdinalIgnoreCase) && Enum.TryParse<AppPage>(args[i + 1], true, out var page))
                vm.CurrentPage = page;
        }

        window.Show();
        _ = vm.StartAsync();
    }

    private void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(e.Exception.ToString(), "JuiceDownloader", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
