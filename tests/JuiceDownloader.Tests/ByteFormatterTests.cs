using System.Globalization;
using JuiceDownloader.Core;

namespace JuiceDownloader.Tests;

public class ByteFormatterTests
{
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

    [Theory]
    [InlineData(0, "0 B")]
    [InlineData(512, "512 B")]
    [InlineData(1024, "1.00 KB")]
    [InlineData(1536, "1.50 KB")]
    [InlineData(10 * 1024, "10.0 KB")]
    [InlineData(100 * 1024, "100 KB")]
    [InlineData(1024L * 1024, "1.00 MB")]
    [InlineData(1024L * 1024 * 1024 * 48, "48.0 GB")]
    [InlineData(1024L * 1024 * 1024 * 1024 * 2, "2.00 TB")]
    public void Formats_with_three_significant_digits(long bytes, string expected)
        => Assert.Equal(expected, ByteFormatter.Format(bytes, Invariant));

    [Fact]
    public void Negative_and_nan_clamp_to_zero()
    {
        Assert.Equal("0 B", ByteFormatter.Format(-5, Invariant));
        Assert.Equal("0 B", ByteFormatter.Format(double.NaN, Invariant));
    }

    [Fact]
    public void Split_returns_number_and_unit_separately()
    {
        var (number, unit) = ByteFormatter.Split(1024d * 1024 * 1024 * 12.4, Invariant);
        Assert.Equal("12.4", number);
        Assert.Equal("GB", unit);
    }

    [Fact]
    public void Respects_culture_decimal_separator()
    {
        var ru = CultureInfo.GetCultureInfo("ru-RU");
        Assert.Equal("1,50 KB", ByteFormatter.Format(1536, ru));
    }
}
