using System.Text;

namespace JuiceDownloader.Core;

/// <summary>
/// Turns a path the API sent into a file under the chosen folder. The path comes from a server, so nothing in it may
/// climb out of that folder, and it has to be a legal name on all three systems: the same download folder may be
/// shared or moved between them, and the catalog really does hold names Windows refuses.
/// </summary>
public static class LocalPath
{
    private const int MaxComponentBytes = 240; // leaves room for ".part" and ".lrc" under the 255 of most file systems
    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>The file for an API path, or null when the path holds nothing usable.</summary>
    public static string? Resolve(string destination, string apiPath)
    {
        var parts = new List<string>();
        foreach (var raw in apiPath.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (raw is "." or "..") return null;
            parts.Add(Clean(raw));
        }
        if (parts.Count == 0) return null;

        var root = Path.GetFullPath(destination);
        var full = Path.GetFullPath(Path.Combine([root, .. parts]));
        var prefix = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;
        return full.StartsWith(prefix, StringComparison.Ordinal) ? full : null;
    }

    public static string Clean(string component)
    {
        var text = new StringBuilder(component.Length);
        foreach (var c in component)
            text.Append(c < 32 || "<>:\"/\\|?*".Contains(c) ? '_' : c);
        var name = text.ToString().TrimEnd(' ', '.').TrimStart(' ');
        if (name.Length == 0) name = "_";

        var stem = name.Split('.')[0];
        if (Reserved.Contains(stem)) name = "_" + name;

        if (Encoding.UTF8.GetByteCount(name) <= MaxComponentBytes) return name;
        var extension = Path.GetExtension(name);
        if (Encoding.UTF8.GetByteCount(extension) > 16) extension = "";
        var keep = name[..^extension.Length];
        while (Encoding.UTF8.GetByteCount(keep) + Encoding.UTF8.GetByteCount(extension) > MaxComponentBytes)
            keep = keep[..^(char.IsLowSurrogate(keep[^1]) ? 2 : 1)];
        return keep.TrimEnd(' ', '.') + extension;
    }
}
