using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using JuiceDownloader.Controls;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;
using JuiceDownloader.ViewModels;
using JuiceDownloader.Views;

namespace JuiceDownloader;

public sealed class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var settings = SettingsStore.Load();
            LocalizationManager.Instance.Apply(settings.Language);
            Motion.Enabled = settings.Animations;
            ThemeManager.Attach(this);
            ThemeManager.Apply(settings.Theme);

            var window = new MainWindow();
            var vm = new MainViewModel(settings, window);
            vm.Settings.ThemeChanged += () => ThemeManager.Apply(vm.Settings.Theme);
            window.Attach(vm, settings);
            desktop.MainWindow = window;
            desktop.Exit += (_, _) => { vm.Player.Dispose(); vm.Preview.Dispose(); };
            // A terminated app takes its player along too.
            AppDomain.CurrentDomain.ProcessExit += (_, _) => vm.Player.Dispose();

            vm.OpenPage(Program.StartPage);
            _ = vm.StartAsync();
        }

        base.OnFrameworkInitializationCompleted();
    }
}
