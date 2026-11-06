using System.ComponentModel;
using Avalonia.Data;
using Avalonia.Markup.Xaml;

namespace JuiceDownloader.Localization;

/// <summary>XAML: <c>Text="{loc:Str nav.overview}"</c>. Live-updates when the language changes.</summary>
public sealed class StrExtension : MarkupExtension
{
    public StrExtension() { }

    public StrExtension(string key) => Key = key;

    public string Key { get; set; } = string.Empty;

    public override object ProvideValue(IServiceProvider serviceProvider)
        => new Binding(nameof(LocalizedString.Value)) { Source = LocalizedString.For(Key), Mode = BindingMode.OneWay };
}

/// <summary>One string key as an observable value; one shared instance per key.</summary>
public sealed class LocalizedString : INotifyPropertyChanged
{
    private static readonly Dictionary<string, LocalizedString> Cache = new(StringComparer.Ordinal);

    private readonly string _key;

    private LocalizedString(string key)
    {
        _key = key;
        LocalizationManager.Instance.LanguageChanged += (_, _) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Value)));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Value => LocalizationManager.Instance[_key];

    public static LocalizedString For(string key)
    {
        lock (Cache)
        {
            if (!Cache.TryGetValue(key, out var value)) Cache[key] = value = new LocalizedString(key);
            return value;
        }
    }
}
