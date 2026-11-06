using System.Globalization;
using System.Text.RegularExpressions;
using JuiceDownloader.Localization;

namespace JuiceDownloader.Tests;

public class LocalizationTests
{
    private static readonly Regex Placeholder = new(@"\{(\d+)\}", RegexOptions.Compiled);

    public static IEnumerable<object[]> LanguageCodes()
        => LocalizationManager.Languages.Select(l => new object[] { l.Code });

    [Theory]
    [MemberData(nameof(LanguageCodes))]
    public void Every_language_file_loads_and_matches_english_keys(string code)
    {
        var en = LocalizationManager.Load("en");
        var lang = LocalizationManager.Load(code);

        Assert.NotNull(en);
        Assert.NotNull(lang);

        var missing = en!.Keys.Except(lang!.Keys).ToList();
        var extra = lang.Keys.Except(en.Keys).ToList();
        Assert.True(missing.Count == 0, $"{code} is missing: {string.Join(", ", missing)}");
        Assert.True(extra.Count == 0, $"{code} has unknown keys: {string.Join(", ", extra)}");
    }

    [Theory]
    [MemberData(nameof(LanguageCodes))]
    public void Placeholders_match_english(string code)
    {
        var en = LocalizationManager.Load("en")!;
        var lang = LocalizationManager.Load(code)!;

        foreach (var (key, value) in en)
        {
            if (!lang.TryGetValue(key, out var translated)) continue;
            var expected = Placeholder.Matches(value).Select(m => m.Value).OrderBy(x => x).ToList();
            var actual = Placeholder.Matches(translated).Select(m => m.Value).OrderBy(x => x).ToList();
            Assert.True(expected.SequenceEqual(actual), $"{code}:{key} placeholders differ ('{value}' vs '{translated}')");
        }
    }

    [Theory]
    [MemberData(nameof(LanguageCodes))]
    public void No_empty_strings(string code)
    {
        var lang = LocalizationManager.Load(code)!;
        Assert.All(lang, kv => Assert.False(string.IsNullOrWhiteSpace(kv.Value), $"{code}:{kv.Key} is empty"));
    }

    [Theory]
    [InlineData("en-US", "en")]
    [InlineData("en-GB", "en")]
    [InlineData("ru-RU", "ru")]
    [InlineData("fi-FI", "en")]
    [InlineData("zh-CN", "en")]
    public void System_culture_maps_to_best_language(string culture, string expected)
        => Assert.Equal(expected, LocalizationManager.Match(CultureInfo.GetCultureInfo(culture)));

    [Fact]
    public void Unknown_key_is_visible_rather_than_blank()
        => Assert.Equal("[no.such.key]", LocalizationManager.Instance["no.such.key"]);
}
