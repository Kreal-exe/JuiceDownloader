using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using JuiceDownloader.Core;

namespace JuiceDownloader.Controls;

/// <summary>Looks up a brush from application resources by prefix and value ("Brush.Cat.albums" …). Parameter "Soft" picks the tinted variant.</summary>
public sealed class ResourceBrushConverter : IValueConverter
{
    public string Prefix { get; set; } = "Brush.Cat.";

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is null) return Brushes.Transparent;
        var key = Prefix + value + (parameter is string s && s.Length > 0 ? "." + s : string.Empty);
        return Application.Current?.TryFindResource(key) as Brush ?? Brushes.Transparent;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }
    public bool Collapse { get; set; } = true;

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var b = value is true;
        if (Invert) b = !b;
        return b ? Visibility.Visible : (Collapse ? Visibility.Collapsed : Visibility.Hidden);
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class NullToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var present = value is not null && !(value is string s && s.Length == 0);
        if (Invert) present = !present;
        return present ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class BytesConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value switch
        {
            long l => ByteFormatter.Format(l),
            double d => ByteFormatter.Format(d),
            int i => ByteFormatter.Format(i),
            _ => string.Empty,
        };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class CountConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value switch
        {
            long l => ByteFormatter.FormatCount(l),
            int i => ByteFormatter.FormatCount(i),
            _ => string.Empty,
        };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Formats a localized string with the bound value: ConverterParameter is the key.</summary>
public sealed class LocFormatConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var key = parameter as string ?? string.Empty;
        var arg = value switch
        {
            long l => ByteFormatter.FormatCount(l),
            int i => ByteFormatter.FormatCount(i),
            _ => value?.ToString() ?? string.Empty,
        };
        return Localization.LocalizationManager.Instance.Format(key, arg);
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class EqualsConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => Equals(value?.ToString(), parameter?.ToString());

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is true ? parameter! : Binding.DoNothing;
}

public sealed class GreaterThanZeroConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value switch
        {
            long l => l > 0,
            int i => i > 0,
            double d => d > 0,
            _ => false,
        };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class BoolToDoubleConverter : IValueConverter
{
    public double True { get; set; } = 1;
    public double False { get; set; } = 0;

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is true ? True : False;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}
