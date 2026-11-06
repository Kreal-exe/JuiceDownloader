using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace JuiceDownloader.Settings;

public sealed class AppSettings
{
    /// <summary>"auto" or a language code from <see cref="Localization.LocalizationManager.Languages"/>.</summary>
    public string Language { get; set; } = "auto";

    /// <summary>"dark", "light" or "system".</summary>
    public string Theme { get; set; } = "dark";

    public bool Animations { get; set; } = true;
    public bool Backdrop { get; set; } = true;

    public string Destination { get; set; } = DefaultDestination;
    public int Parallel { get; set; } = DefaultParallel;
    public bool ConfirmDownloads { get; set; } = true;
    public bool RefreshOnLaunch { get; set; } = true;

    public bool LyricsEnabled { get; set; }
    public bool LyricsEmbed { get; set; } = true;
    public bool LyricsSidecar { get; set; } = true;
    public bool LyricsTimedInTag { get; set; }

    public double WindowWidth { get; set; }
    public double WindowHeight { get; set; }
    public bool WindowMaximized { get; set; }

    public double PlayerVolume { get; set; } = DefaultPlayerVolume;

    // The engine says what the rules start as.
    public bool RulesOneVersion { get; set; } = RuleDefaults.OneVersion;
    public bool RulesSkipReleased { get; set; } = RuleDefaults.SkipReleased;
    public bool RulesSkipUnfinished { get; set; } = RuleDefaults.SkipUnfinished;
    public bool RulesOneFolder { get; set; } = RuleDefaults.OneFolder;
    public bool RulesWithClips { get; set; } = RuleDefaults.WithClips;
    public List<string> RulesSections { get; set; } = [.. RuleDefaults.Sections];
    public List<string> RulesNeverOffer { get; set; } = [];
    /// <summary>Files called clips by hand: lives with no mark in their names.</summary>
    public List<string> RulesClipPaths { get; set; } = [];

    public static readonly Core.RuleOptions RuleDefaults = new();

    public const int DefaultParallel = 8;
    public const double DefaultPlayerVolume = 0.8;

    /// <summary>What the Settings page offers.</summary>
    public static readonly int[] ParallelChoices = [1, 2, 4, 8, 16, 32];

    public static string DefaultDestination => Path.Combine(MusicFolder(), "Juice WRLD");

    private static string MusicFolder()
    {
        var music = Environment.GetFolderPath(Environment.SpecialFolder.MyMusic);
        return music.Length > 0 ? music : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Music");
    }
}

public static class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    // JUICEDOWNLOADER_SETTINGS may point at an alternative settings file (portable use, testing).
    public static string FilePath { get; } =
        Environment.GetEnvironmentVariable("JUICEDOWNLOADER_SETTINGS") is { Length: > 0 } custom
            ? Path.GetFullPath(custom)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "JuiceDownloader", "settings.json");

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
        catch
        {
            // corrupt settings fall back to defaults
        }

        if (string.IsNullOrWhiteSpace(settings.Destination)) settings.Destination = AppSettings.DefaultDestination;
        settings.Parallel = AppSettings.ParallelChoices.LastOrDefault(n => n <= settings.Parallel, AppSettings.ParallelChoices[0]);
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
        catch
        {
            // never crash because of settings
        }
    }
}
