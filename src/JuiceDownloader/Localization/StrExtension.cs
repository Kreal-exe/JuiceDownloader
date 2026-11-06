using System.Windows.Data;
using System.Windows.Markup;

namespace JuiceDownloader.Localization;

/// <summary>XAML: <c>Text="{loc:Str nav.dashboard}"</c>. Live-updates when the language changes.</summary>
[MarkupExtensionReturnType(typeof(object))]
public sealed class StrExtension : MarkupExtension
{
    public StrExtension() { }

    public StrExtension(string key) => Key = key;

    [ConstructorArgument("key")]
    public string Key { get; set; } = string.Empty;

    public override object ProvideValue(IServiceProvider serviceProvider)
    {
        var binding = new Binding("[" + Key + "]")
        {
            Source = LocalizationManager.Instance,
            Mode = BindingMode.OneWay,
        };
        return binding.ProvideValue(serviceProvider);
    }
}
