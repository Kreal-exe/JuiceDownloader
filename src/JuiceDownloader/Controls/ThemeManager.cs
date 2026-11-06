using System.Windows;
using Microsoft.Win32;

namespace JuiceDownloader.Controls;

public static class ThemeManager
{
    public static bool IsDark { get; private set; } = true;
    public static event Action? Changed;

    public static void Apply(string theme)
    {
        var dark = theme switch
        {
            "light" => false,
            "system" => SystemPrefersDark(),
            _ => true,
        };

        var uri = new Uri($"Themes/{(dark ? "Dark" : "Light")}.xaml", UriKind.Relative);
        var dictionaries = Application.Current.Resources.MergedDictionaries;
        var existing = dictionaries.FirstOrDefault(d =>
            d.Source?.OriginalString.Contains("Themes/Dark", StringComparison.OrdinalIgnoreCase) == true ||
            d.Source?.OriginalString.Contains("Themes/Light", StringComparison.OrdinalIgnoreCase) == true);

        var replacement = new ResourceDictionary { Source = uri };
        if (existing is not null)
        {
            if (existing.Source?.OriginalString == uri.OriginalString) { IsDark = dark; return; }
            dictionaries[dictionaries.IndexOf(existing)] = replacement;
        }
        else
        {
            dictionaries.Insert(0, replacement);
        }

        IsDark = dark;
        Changed?.Invoke();
    }

    public static bool SystemPrefersDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
        }
        catch
        {
            return true;
        }
    }
}
