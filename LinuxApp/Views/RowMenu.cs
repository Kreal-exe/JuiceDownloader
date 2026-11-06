using Avalonia.Controls;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

/// <summary>The right-click menu of a row, on a section's list and on the By Rules page.</summary>
internal static class RowMenu
{
    private const int MaxAlsoIn = 15;

    public static void Show(Control target, CatalogNode node, bool searching)
    {
        if (TopLevel.GetTopLevel(target)?.DataContext is not MainViewModel main) return;
        var loc = LocalizationManager.Instance;
        var items = new List<Control>();
        void Add(string key, Action action) => items.Add(Item(loc[key], action));

        if (node.IsDirectory)
        {
            AddSelect();
            if (node.FileCount > 0) Add("menu.row.downloadAlbum", () => _ = main.Download.StartAlbumAsync(node));
            Add("menu.row.copyPath", () => main.CopyText(node.Path));
            if (searching) Add("menu.row.reveal", () => main.Reveal(node));
        }
        else
        {
            if (Library.PreviewOf(node.Name) != PreviewKind.None) Add("preview.open", () => main.Preview.Open(node));
            if (Library.IsPlayable(node.Name)) Add("menu.row.play", () => main.Player.Toggle(node));
            AddSelect();
            Add("menu.row.reveal", () => main.Reveal(node));
            items.Add(AlsoIn(main, node));
            Add("menu.row.versions", () => main.FindVersions(node));
            Add("menu.row.lyrics", () => main.ViewLyrics(node));
            items.Add(new Separator());
            Add("menu.row.copyPath", () => main.CopyText(node.Path));
            Add("menu.row.copyLink", () => main.CopyText(ApiClient.DownloadUrl(node.Path)));
            if (Library.LocalCopy(main.Settings.Destination, node) is { } local) Add("menu.row.showFile", () => Platform.Reveal(local));
        }

        new ContextMenu { ItemsSource = items }.Open(target);

        void AddSelect()
        {
            var all = node.FileCount > 0 && node.SelectedFiles >= node.FileCount;
            Add(all ? "menu.row.deselect" : "menu.row.select", () => main.SetSelected(node, !all));
        }
    }

    private static MenuItem Item(string text, Action action)
    {
        var item = new MenuItem { Header = text };
        item.Click += (_, _) => action();
        return item;
    }

    private static MenuItem AlsoIn(MainViewModel main, CatalogNode node)
    {
        var loc = LocalizationManager.Instance;
        var parent = new MenuItem { Header = loc["menu.row.alsoIn"] };
        var others = main.RelationsOf(node);
        if (others.Count == 0)
        {
            parent.ItemsSource = new[] { new MenuItem { Header = loc["menu.row.alsoInNone"], IsEnabled = false } };
            return parent;
        }
        parent.ItemsSource = others.Take(MaxAlsoIn)
            .Select(other => Item($"{main.SectionOf(other)?.Title} · {CatalogRelations.Place(other)}", () => main.Reveal(other))).ToList();
        return parent;
    }
}
