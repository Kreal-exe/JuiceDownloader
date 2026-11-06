using System.Text.RegularExpressions;

namespace JuiceDownloader.Core;

/// <summary>One file or folder of the API's tree, with its size and the selection kept up to date all the way to the root.</summary>
public sealed class CatalogNode
{
    public required string Name { get; init; }
    public required string Path { get; init; }
    public bool IsDirectory { get; init; }
    public long Size { get; internal set; }
    public int FileCount { get; internal set; }
    public CatalogNode? Parent { get; internal set; }
    public List<CatalogNode> Children { get; } = [];

    public long SelectedBytes { get; internal set; }
    public int SelectedFiles { get; internal set; }

    /// <summary>The name without the API's ordering number: "7. Goodbye &amp; Good Riddance" reads "Goodbye &amp; Good Riddance".</summary>
    public string DisplayName => Catalog.DisplayName(Name);

    public IEnumerable<CatalogNode> Files()
    {
        if (!IsDirectory) { yield return this; yield break; }
        var stack = new Stack<CatalogNode>(Enumerable.Reverse(Children));
        while (stack.Count > 0)
        {
            var node = stack.Pop();
            if (!node.IsDirectory) { yield return node; continue; }
            for (var i = node.Children.Count - 1; i >= 0; i--) stack.Push(node.Children[i]);
        }
    }
}

/// <summary>A page of the sidebar: the folders of the API's tree that belong on it.</summary>
public sealed record CatalogSection(string Id, IReadOnlyList<string> Roots)
{
    public List<CatalogNode> Rows { get; } = [];
    public long Size => Rows.Sum(r => r.Size);
    public int FileCount => Rows.Sum(r => r.FileCount);
    public long SelectedBytes => Rows.Sum(r => r.SelectedBytes);
    public int SelectedFiles => Rows.Sum(r => r.SelectedFiles);
}

public sealed partial class Catalog
{
    /// <summary>Everything the API offers goes on one of these. A folder the API adds later lands on "media", so it is never hidden.</summary>
    public const string FallbackSection = "media";

    private const string ReleasedRoot = "Compilation/1. Released Discography";

    /// <summary>Every real song that never came out officially: no snippets, original files, beats or art.</summary>
    public static IReadOnlyList<string> UnreleasedSections { get; } = ["unofficial", "unreleased", "sessionEdits", "compilations", "remixes"];

    /// <summary>What By Rules takes songs from: every section but snippets and art, which nobody collects as songs.</summary>
    public static IReadOnlyList<string> RuleSections => SectionTable.Select(s => s.Id).Where(id => id != "snippets" && id != FallbackSection).ToList();

    private const string MiscRoot = "Compilation/3. Misc. Discography";
    private static readonly string[] ReleasedNames = ["Goodbye & Good Riddance", "Death Race For Love", "Legends Never Die", "Fighting Demons", "The Party Never Ends", "Too Soon", "The Pre-Party", "Up Next Session"];

    /// <summary>The API files everything he ever put out under "released". What came out and is on the streaming services under his
    /// name is Released: the albums with their editions, the label's EPs and singles, and the one compilation folder Apple
    /// Music lists too. The EPs and singles he uploaded himself never came out.</summary>
    private static void SortReleases(CatalogNode? released, CatalogNode? misc, CatalogSection albums, CatalogSection compilations, CatalogSection unofficial)
    {
        foreach (var child in released?.Children ?? [])
        {
            var name = DisplayName(child.Name);
            if (child.IsDirectory && name.Contains("Singles & Features", StringComparison.OrdinalIgnoreCase))
                foreach (var kind in child.Children) (DisplayName(kind.Name).StartsWith("Mainstream", StringComparison.Ordinal) ? albums : unofficial).Rows.Add(kind);
            else if (ReleasedNames.Any(n => name.StartsWith(n, StringComparison.OrdinalIgnoreCase)) || name.Contains("WRLD ON DRUGS", StringComparison.OrdinalIgnoreCase)) albums.Rows.Add(child);
            else unofficial.Rows.Add(child);
        }
        foreach (var child in misc?.Children ?? [])
            (DisplayName(child.Name).StartsWith("All Girls Are The Same 2", StringComparison.Ordinal) ? albums : compilations).Rows.Add(child);
    }

    public static IReadOnlyList<(string Id, string[] Roots)> SectionTable { get; } =
    [
        ("albums", [ReleasedRoot]),
        ("unofficial", []),
        ("unreleased", ["Compilation/2. Unreleased Discography"]),
        ("compilations", [MiscRoot]),
        ("sessionEdits", ["Session Edits"]),
        ("originals", ["Original Files"]),
        ("studio", ["Studio Sessions"]),
        ("instrumentals", ["Instrumentals"]),
        ("remixes", ["Remixes & Edits"]),
        ("snippets", ["Snippets"]),
        ("media", ["Cover Arts", "Compilation/4. Cover Art", "Footage", "Others"]),
    ];

    public CatalogNode Root { get; }
    public IReadOnlyList<CatalogSection> Sections { get; }
    public long TotalBytes => Root.Size;
    public int TotalFiles => Root.FileCount;
    public long SelectedBytes => Root.SelectedBytes;
    public int SelectedFiles => Root.SelectedFiles;

    private Catalog(CatalogNode root, IReadOnlyList<CatalogSection> sections)
    {
        Root = root;
        Sections = sections;
    }

    public CatalogSection Section(string id) => Sections.First(s => s.Id == id);

    /// <summary>Every section's rows as one: what the Overview's search goes through.</summary>
    public CatalogSection Everything()
    {
        var all = new CatalogSection("everything", []);
        foreach (var section in Sections) all.Rows.AddRange(section.Rows);
        return all;
    }

    public static string DisplayName(string name)
    {
        var stripped = OrderPrefix().Replace(name, "");
        return stripped.Length > 0 ? stripped : name;
    }

    public static Catalog Build(IEnumerable<ApiItem> items)
    {
        var root = new CatalogNode { Name = "", Path = "", IsDirectory = true };
        var folders = new Dictionary<string, CatalogNode>(StringComparer.Ordinal) { [""] = root };

        CatalogNode Folder(string path)
        {
            if (folders.TryGetValue(path, out var existing)) return existing;
            var cut = path.LastIndexOf('/');
            var parent = cut < 0 ? root : Folder(path[..cut]);
            var node = new CatalogNode { Name = path[(cut + 1)..], Path = path, IsDirectory = true, Parent = parent };
            parent.Children.Add(node);
            folders[path] = node;
            return node;
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            var path = item.Path?.Trim('/') ?? "";
            if (path.Length == 0) continue;
            if (item.IsDirectory) continue;   // a folder exists through its files: the API also lists empty ones
            if (!seen.Add(path)) continue;
            var cut = path.LastIndexOf('/');
            var parent = cut < 0 ? root : Folder(path[..cut]);
            parent.Children.Add(new CatalogNode { Name = path[(cut + 1)..], Path = path, Parent = parent, Size = Math.Max(0, item.Size), FileCount = 1 });
        }

        Tally(root);

        var sections = SectionTable.Select(s => new CatalogSection(s.Id, s.Roots)).ToList();
        var fallback = sections.First(s => s.Id == FallbackSection);
        var placed = new HashSet<CatalogNode>();
        foreach (var section in sections)
        {
            foreach (var path in section.Roots)
            {
                if (!folders.TryGetValue(path, out var node)) continue;
                placed.Add(node);
                // The one-root pages list what is inside; the media page keeps its roots as rows, they are what tells them apart.
                if (section.Id == FallbackSection) section.Rows.Add(node);
                else if (path is not (ReleasedRoot or MiscRoot)) section.Rows.AddRange(node.Children);
            }
        }
        SortReleases(folders.GetValueOrDefault(ReleasedRoot), folders.GetValueOrDefault(MiscRoot), sections.First(s => s.Id == "albums"), sections.First(s => s.Id == "compilations"), sections.First(s => s.Id == "unofficial"));

        // Whatever no page claims, such as the compilation's READ ME or a new top-level folder.
        void Unclaimed(CatalogNode folder)
        {
            foreach (var child in folder.Children)
            {
                if (placed.Contains(child)) continue;
                if (child.IsDirectory && placed.Any(p => p.Path.StartsWith(child.Path + "/", StringComparison.Ordinal))) Unclaimed(child);
                else fallback.Rows.Add(child);
            }
        }
        Unclaimed(root);

        return new Catalog(root, sections);
    }

    private static void Tally(CatalogNode node)
    {
        node.Children.Sort(static (a, b) =>
        {
            if (a.IsDirectory != b.IsDirectory) return a.IsDirectory ? -1 : 1;
            return NaturalCompare(a.Name, b.Name);
        });
        foreach (var child in node.Children)
        {
            if (child.IsDirectory) Tally(child);
            node.Size += child.Size;
            node.FileCount += child.FileCount;
        }
    }

    /// <summary>Numbers compare as numbers: the API's "2. affliction" comes before "10. Outsiders".</summary>
    public static int NaturalCompare(string a, string b)
    {
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsAsciiDigit(a[i]) && char.IsAsciiDigit(b[j]))
            {
                var si = i; while (i < a.Length && char.IsAsciiDigit(a[i])) i++;
                var sj = j; while (j < b.Length && char.IsAsciiDigit(b[j])) j++;
                var na = a[si..i].TrimStart('0');
                var nb = b[sj..j].TrimStart('0');
                if (na.Length != nb.Length) return na.Length - nb.Length;
                var c = string.CompareOrdinal(na, nb);
                if (c != 0) return c;
                continue;
            }
            var ca = char.ToUpperInvariant(a[i]);
            var cb = char.ToUpperInvariant(b[j]);
            if (ca != cb) return ca - cb;
            i++; j++;
        }
        return (a.Length - i) - (b.Length - j);
    }

    /// <summary>Selects or clears a file or a whole folder.</summary>
    public static void Select(CatalogNode node, bool selected)
    {
        foreach (var file in node.Files())
        {
            var was = file.SelectedFiles == 1;
            if (was == selected) continue;
            var bytes = selected ? file.Size : -file.Size;
            var count = selected ? 1 : -1;
            for (var n = file; n is not null; n = n.Parent)
            {
                n.SelectedBytes += bytes;
                n.SelectedFiles += count;
            }
        }
    }

    public IEnumerable<CatalogNode> SelectedFilesList() => Root.Files().Where(f => f.SelectedFiles == 1);

    public void ClearSelection() => Select(Root, false);

    [GeneratedRegex(@"^\d+\.\s+")]
    private static partial Regex OrderPrefix();
}
