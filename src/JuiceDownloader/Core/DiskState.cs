using System.Text;

namespace JuiceDownloader.Core;

/// <summary>
/// What of the catalog is already in a folder, wherever in it: a By Rules download keeps everything in one folder, and a
/// file may have been tagged or given its right extension since. Built by walking the folder once, so ask it freely.
/// </summary>
public sealed class DiskState
{
    private static DiskState? _current;
    private readonly Dictionary<string, string> _paths = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _sections = new(StringComparer.Ordinal);

    /// <summary>The last look at the download folder. Set on the window's thread.</summary>
    public static DiskState? Current
    {
        get => _current;
        set
        {
            _current = value;
            Changed?.Invoke();
        }
    }

    public static event Action? Changed;

    /// <summary>The folder's own files that are in the catalog, each counted once: one file can sit at several catalog paths.</summary>
    public int Files { get; private set; }
    public long Bytes { get; private set; }

    public bool Has(string apiPath) => _paths.ContainsKey(apiPath);
    public string? LocalPathOf(string apiPath) => _paths.GetValueOrDefault(apiPath);
    public int FilesInSection(string id) => _sections.GetValueOrDefault(id);

    public static DiskState Scan(Catalog catalog, string destination)
    {
        var local = new Dictionary<string, List<FileInfo>>(StringComparer.Ordinal);
        foreach (var file in Walk(destination))
        {
            var extension = file.Extension.ToLowerInvariant();
            if (extension is ".part" or ".lrc") continue;
            var key = Key(file.Name);
            if (!local.TryGetValue(key, out var list)) local[key] = list = [];
            list.Add(file);
        }

        var state = new DiskState();
        var used = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var file in catalog.Root.Files())
        {
            var name = LocalPath.Clean(file.Name);
            var extension = Path.GetExtension(name).ToLowerInvariant();
            if (!local.TryGetValue(Key(name), out var candidates)) continue;
            FileInfo? best = null;
            var nearest = long.MaxValue;
            foreach (var candidate in candidates)
            {
                var other = candidate.Extension.ToLowerInvariant();
                if (other != extension && !(IsAudio(other) && IsAudio(extension))) continue;
                var distance = Math.Abs(candidate.Length - file.Size);
                if (!SizeIsNear(candidate.Length, file.Size) || distance >= nearest) continue;
                best = candidate;
                nearest = distance;
            }
            if (best is null) continue;
            state._paths[file.Path] = best.FullName;
            used[best.FullName] = best.Length;
        }

        foreach (var section in catalog.Sections)
            state._sections[section.Id] = section.Rows.SelectMany(r => r.Files()).Count(f => state.Has(f.Path));
        state.Files = used.Count;
        state.Bytes = used.Values.Sum();
        return state;
    }

    private static IEnumerable<FileInfo> Walk(string folder)
    {
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System };
        try
        {
            return Directory.Exists(folder) ? new DirectoryInfo(folder).EnumerateFiles("*", options).ToList() : [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static string Key(string name) => Path.GetFileNameWithoutExtension(name).Normalize(NormalizationForm.FormC).ToLowerInvariant();

    private static bool IsAudio(string extension) => extension == ".webm" || Library.IsAudio("x" + extension);

    /// <summary>
    /// Words and cover art go into a tag after the download, so the size only has to be near; and a file cut of the
    /// silence at its end is smaller, though never by half.
    /// </summary>
    private static bool SizeIsNear(long local, long size) =>
        Math.Abs(local - size) <= Math.Max(2L * 1024 * 1024, size / 20) || (local < size && local >= size / 2);
}
