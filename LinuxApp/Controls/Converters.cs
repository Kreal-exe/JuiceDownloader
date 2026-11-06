using System.Globalization;
using Avalonia.Data;
using Avalonia.Data.Converters;
using Avalonia.Media.Transformation;
using JuiceDownloader.Core;
using JuiceDownloader.ViewModels;
using Material.Icons;

namespace JuiceDownloader.Controls;

/// <summary>An icon name from the catalog or a view model ("FolderOutline") as a Material icon.</summary>
public sealed class IconConverter : IValueConverter
{
    public static readonly IconConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => Parse(value as string);

    public static MaterialIconKind Parse(string? name)
        => Enum.TryParse<MaterialIconKind>(name, out var kind) ? kind : MaterialIconKind.FolderOutline;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class EqualsConverter : IValueConverter
{
    public static readonly EqualsConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => Equals(value?.ToString(), parameter?.ToString());

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => BindingOperations.DoNothing;
}

public sealed class BytesConverter : IValueConverter
{
    public static readonly BytesConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        long l => ByteFormatter.Format(l),
        int i => ByteFormatter.Format(i),
        double d => ByteFormatter.Format(d),
        _ => string.Empty,
    };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>The sidebar's sliding indicator: one nav row (36 px) per page.</summary>
public sealed class PageOffsetConverter : IValueConverter
{
    public const int RowStep = 36;

    public static readonly PageOffsetConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => TransformOperations.Parse($"translateY({(value is AppPage page ? (int)page * RowStep : 0)}px)");

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}
