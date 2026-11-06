using Avalonia;

namespace JuiceDownloader;

internal static class Program
{
    /// <summary>"--page albums" opens that page: overview, albums, unreleased, compilations, sessionEdits, originals, studio, instrumentals, remixes, snippets, media, lyrics, settings, about.</summary>
    public static string? StartPage { get; private set; }

    [STAThread]
    public static int Main(string[] args)
    {
        var page = Array.IndexOf(args, "--page");
        if (page >= 0 && page + 1 < args.Length) StartPage = args[page + 1];
        return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .With(new X11PlatformOptions { WmClass = "JuiceDownloader" })
            .LogToTrace();
}
