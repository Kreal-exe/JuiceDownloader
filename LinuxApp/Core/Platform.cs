using System.Diagnostics;

namespace JuiceDownloader.Core;

/// <summary>Desktop integration: opening folders and links with the desktop's default handler.</summary>
public static class Platform
{
    public static void Open(string target)
    {
        if (OperatingSystem.IsMacOS()) Run("open", target);
        else if (!Run("xdg-open", target)) Run("gio", "open", target);
    }

    /// <summary>Shows a file selected in the file manager where the desktop can, else opens its folder.</summary>
    public static void Reveal(string file)
    {
        if (OperatingSystem.IsMacOS()) { Run("open", "-R", file); return; }
        var uri = new Uri(file).AbsoluteUri.Replace("'", "%27");
        var shown = Run("gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1", "--object-path", "/org/freedesktop/FileManager1",
            "--method", "org.freedesktop.FileManager1.ShowItems", $"['{uri}']", "");
        if (!shown) Open(Path.GetDirectoryName(file) ?? file);
    }

    private static bool Run(string file, params string[] args)
    {
        try
        {
            var info = new ProcessStartInfo(file) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var arg in args) info.ArgumentList.Add(arg);
            using var process = Process.Start(info);
            if (process is null) return false;
            // xdg-open may stay alive with the app it started, so only wait briefly.
            if (!process.WaitForExit(3000)) return true;
            return process.ExitCode == 0;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }
}
