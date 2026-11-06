using System.Text.Json;
using System.Text.Json.Serialization;
using JuiceDownloader.Core;

namespace JuiceDownloader.Settings;

public sealed class AppSettings
{
    /// <summary>"auto" or a language code from <see cref="Localization.LocalizationManager.Languages"/>.</summary>
    public string Language { get; set; } = "auto";

    /// <summary>"dark", "light" or "system".</summary>
    public string Theme { get; set; } = "dark";

    public bool Animations { get; set; } = true;

    /// <summary>Windows only; kept so a settings file reads the same everywhere.</summary>
    public bool Backdrop { get; set; } = true;

    public string Destination { get; set; } = DefaultDestination;
    public int Parallel { get; set; } = DefaultParallel;
    public bool ConfirmDownloads { get; set; } = true;
    public bool RefreshOnLaunch { get; set; } = true;

    public bool LyricsEnabled { get; set; }
    public bool LyricsEmbed { get; set; } = true;
    public bool LyricsSidecar { get; set; } = true;
    public bool LyricsTimedInTag { get; set; }

    public double PlayerVolume { get; set; } = 0.8;

    // What the engine's rules default to, so there is one place that says it.
    private static readonly RuleOptions RuleDefaults = new();
    public bool RulesOneVersion { get; set; } = RuleDefaults.OneVersion;
    public bool RulesSkipReleased { get; set; } = RuleDefaults.SkipReleased;
    public bool RulesSkipUnfinished { get; set; } = RuleDefaults.SkipUnfinished;
    public bool RulesOneFolder { get; set; } = RuleDefaults.OneFolder;
    public List<string> RulesSections { get; set; } = [.. RuleDefaults.Sections];
    public List<string> RulesNeverOffer { get; set; } = [];

    public double WindowWidth { get; set; }
    public double WindowHeight { get; set; }
    public bool WindowMaximized { get; set; }

    public const int DefaultParallel = 8;
    public static readonly int[] ParallelChoices = [1, 2, 4, 8, 16, 32];

    public static string DefaultDestination =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Music", "Juice WRLD");
}

public static class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    /// <summary>$XDG_CONFIG_HOME, or ~/.config where it is not set.</summary>
    private static string ConfigHome =>
        Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") is { Length: > 0 } xdg
            ? xdg
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");

    // JUICEDOWNLOADER_SETTINGS may point at an alternative settings file (portable use, testing).
    public static string FilePath { get; } =
        Environment.GetEnvironmentVariable("JUICEDOWNLOADER_SETTINGS") is { Length: > 0 } custom
            ? Path.GetFullPath(custom)
            : Path.Combine(ConfigHome, "JuiceDownloader", "settings.json");

    public static string Directory { get; } = Path.GetDirectoryName(FilePath)!;

    public static string CacheDirectory => Path.Combine(Directory, "cache");

    public static AppSettings Load()
    {
        var settings = new AppSettings();
        try
        {
            if (File.Exists(FilePath))
                settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Options) ?? settings;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // corrupt settings fall back to defaults
        }

        if (string.IsNullOrWhiteSpace(settings.Destination)) settings.Destination = AppSettings.DefaultDestination;
        // A value from before the choices were these: the nearest below it.
        settings.Parallel = AppSettings.ParallelChoices.LastOrDefault(c => c <= settings.Parallel, 1);
        settings.PlayerVolume = Math.Clamp(settings.PlayerVolume, 0, 1);
        return settings;
    }

    public static void Save(AppSettings settings)
    {
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(settings, Options));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // never crash because of settings
        }
    }
}
