using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text.Json;

namespace JuiceDownloader.Localization;

public sealed record LanguageInfo(string Code, string NativeName, string EnglishName);

/// <summary>
/// Flat key → string dictionaries loaded from embedded JSON. Exposes an indexer so XAML can bind
/// <c>[key]</c>; switching language raises a single <c>Item[]</c> change so every binding refreshes live.
/// </summary>
public sealed class LocalizationManager : INotifyPropertyChanged
{
    public const string DefaultCode = "en";

    public static LocalizationManager Instance { get; } = new();

    public static IReadOnlyList<LanguageInfo> Languages { get; } =
    [
        new("en", "English", "English"),
        new("ru", "Русский", "Russian"),
    ];

    private readonly Dictionary<string, string> _fallback;
    private Dictionary<string, string> _current;

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? LanguageChanged;

    public string CurrentCode { get; private set; } = DefaultCode;

    private LocalizationManager()
    {
        _fallback = Load(DefaultCode) ?? new Dictionary<string, string>();
        _current = _fallback;
    }

    public string this[string key]
    {
        get
        {
            if (_current.TryGetValue(key, out var value)) return value;
            if (_fallback.TryGetValue(key, out value)) return value;
            return "[" + key + "]";
        }
    }

    public bool Has(string key) => _current.ContainsKey(key) || _fallback.ContainsKey(key);

    public string Format(string key, params object?[] args)
    {
        try
        {
            return string.Format(CultureInfo.CurrentCulture, this[key], args);
        }
        catch (FormatException)
        {
            return this[key];
        }
    }

    /// <summary>Applies a settings value: "auto" picks the Windows display language, otherwise a code.</summary>
    public void Apply(string setting)
    {
        var code = string.IsNullOrWhiteSpace(setting) || setting == "auto" ? DetectSystemLanguage() : setting;
        SetLanguage(code);
    }

    public void SetLanguage(string code)
    {
        var info = Languages.FirstOrDefault(l => l.Code.Equals(code, StringComparison.OrdinalIgnoreCase)) ?? Languages[0];
        _current = info.Code == DefaultCode ? _fallback : Load(info.Code) ?? _fallback;
        CurrentCode = info.Code;

        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CurrentCode)));
        LanguageChanged?.Invoke(this, EventArgs.Empty);
    }

    public static string DetectSystemLanguage() => Match(CultureInfo.CurrentUICulture);

    public static string Match(CultureInfo culture)
    {
        var name = culture.Name;

        var exact = Languages.FirstOrDefault(l => l.Code.Equals(name, StringComparison.OrdinalIgnoreCase));
        if (exact is not null) return exact.Code;

        var two = culture.TwoLetterISOLanguageName;
        var byPrefix = Languages.FirstOrDefault(l => l.Code.Equals(two, StringComparison.OrdinalIgnoreCase));
        return byPrefix?.Code ?? DefaultCode;
    }

    internal static Dictionary<string, string>? Load(string code)
    {
        try
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream($"Strings.{code}.json");
            if (stream is null) return null;
            using var reader = new StreamReader(stream);
            var json = reader.ReadToEnd();
            return JsonSerializer.Deserialize<Dictionary<string, string>>(json);
        }
        catch
        {
            return null;
        }
    }
}
