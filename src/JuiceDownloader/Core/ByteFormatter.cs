using System.Globalization;

namespace JuiceDownloader.Core;

/// <summary>Human readable byte sizes ("12.4 GB"), with a number/unit split for styled counters.</summary>
public static class ByteFormatter
{
    private static readonly string[] Units = ["B", "KB", "MB", "GB", "TB", "PB"];

    public static string Format(double bytes, CultureInfo? culture = null)
    {
        var (number, unit) = Split(bytes, culture);
        return number + " " + unit;
    }

    public static (string Number, string Unit) Split(double bytes, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        if (double.IsNaN(bytes) || bytes < 0) bytes = 0;

        var unit = 0;
        var value = bytes;
        while (value >= 1024 && unit < Units.Length - 1)
        {
            value /= 1024;
            unit++;
        }

        var format = unit == 0 ? "0" : value >= 100 ? "0" : value >= 10 ? "0.0" : "0.00";
        return (value.ToString(format, culture), Units[unit]);
    }

    public static string FormatCount(long count, CultureInfo? culture = null)
        => count.ToString("N0", culture ?? CultureInfo.CurrentCulture);
}
