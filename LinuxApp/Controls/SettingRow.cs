using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;

namespace JuiceDownloader.Controls;

/// <summary>A settings line: icon, title and description on the left, the control (its Content) on the right.</summary>
public sealed class SettingRow : ContentControl
{
    public static readonly StyledProperty<string?> GlyphProperty = AvaloniaProperty.Register<SettingRow, string?>(nameof(Glyph));
    public static readonly StyledProperty<string?> TitleProperty = AvaloniaProperty.Register<SettingRow, string?>(nameof(Title));
    public static readonly StyledProperty<string?> DescriptionProperty = AvaloniaProperty.Register<SettingRow, string?>(nameof(Description));

    public string? Glyph { get => GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }
    public string? Title { get => GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string? Description { get => GetValue(DescriptionProperty); set => SetValue(DescriptionProperty, value); }
}
