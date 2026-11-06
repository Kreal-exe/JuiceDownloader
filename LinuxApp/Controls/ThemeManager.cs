using Avalonia;
using Avalonia.Styling;

namespace JuiceDownloader.Controls;

/// <summary>Dark, light or the desktop's own preference (read by Avalonia from the XDG desktop portal).</summary>
public static class ThemeManager
{
    private static Application? _app;

    public static event Action? Changed;

    public static bool IsDark => _app?.ActualThemeVariant != ThemeVariant.Light;

    public static void Attach(Application app)
    {
        _app = app;
        app.ActualThemeVariantChanged += (_, _) => Changed?.Invoke();
    }

    public static void Apply(string theme)
    {
        if (_app is null) return;
        _app.RequestedThemeVariant = theme switch
        {
            "light" => ThemeVariant.Light,
            "system" => ThemeVariant.Default,
            _ => ThemeVariant.Dark,
        };
    }
}
