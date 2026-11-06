namespace JuiceDownloader.Core;

/// <summary>One line of a section page's list: a folder that opens in place, or a file.</summary>
public sealed record LibraryRow(CatalogNode Node, int Depth, bool Expanded);

/// <summary>
/// What a section page shows, flattened to a list so the views can virtualize it: the Photos folder alone holds
/// 9,481 files. A search lists the matching files and folders of the section, whatever their depth.
/// </summary>
public sealed class LibraryRows(CatalogSection section)
{
    private readonly HashSet<CatalogNode> _expanded = [];

    public CatalogSection Section { get; } = section;
    public string Query { get; set; } = "";

    public bool Toggle(CatalogNode folder)
    {
        if (!folder.IsDirectory) return false;
        if (!_expanded.Remove(folder)) _expanded.Add(folder);
        return true;
    }

    /// <summary>Clears the search and opens the folders down to a file, so it can be scrolled to.</summary>
    public void Reveal(CatalogNode node)
    {
        Query = "";
        for (var n = node.Parent; n is not null; n = n.Parent) _expanded.Add(n);
    }

    public List<LibraryRow> Rows()
    {
        var rows = new List<LibraryRow>();
        var query = Query.Trim();
        if (query.Length > 0)
        {
            foreach (var top in Section.Rows)
                Search(top, query, rows);
            return rows;
        }
        foreach (var top in Section.Rows) Add(top, 0, rows);
        return rows;
    }

    private void Add(CatalogNode node, int depth, List<LibraryRow> rows)
    {
        var open = _expanded.Contains(node);
        rows.Add(new LibraryRow(node, depth, open));
        if (!open) return;
        foreach (var child in node.Children) Add(child, depth + 1, rows);
    }

    private void Search(CatalogNode node, string query, List<LibraryRow> rows)
    {
        if (node.Name.Contains(query, StringComparison.OrdinalIgnoreCase))
        {
            // A folder that matches stands for everything inside it.
            Add(node, 0, rows);
            return;
        }
        foreach (var child in node.Children) Search(child, query, rows);
    }
}
