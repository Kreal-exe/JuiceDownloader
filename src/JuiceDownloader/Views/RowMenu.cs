using System.Windows;
using System.Windows.Controls;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

/// <summary>The right-click menu of a row, built when it opens: rows are recycled, and most never get asked.</summary>
internal static class RowMenu
{
    private const int MaxAlsoIn = 15;

    private static LocalizationManager Loc => LocalizationManager.Instance;

    /// <summary>Opens the menu for the row under a right click, if there is one there.</summary>
    public static bool TryOpen(object? clicked, FrameworkElement owner, MainViewModel? vm, bool searching)
    {
        if (vm is null || clicked is not FrameworkElement { DataContext: IRowNode row }) return false;

        var menu = Build(row.Node, vm, searching);
        menu.PlacementTarget = owner;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        menu.IsOpen = true;
        return true;
    }

    private static ContextMenu Build(CatalogNode node, MainViewModel vm, bool searching)
    {
        var menu = new ContextMenu { FontFamily = (System.Windows.Media.FontFamily)Application.Current.FindResource("Font.Body") };
        var items = menu.Items;

        if (!node.IsDirectory && Library.PreviewOf(node.Name) != PreviewKind.None)
            items.Add(Item("preview.open", () => _ = vm.Preview.OpenAsync(node)));

        if (!node.IsDirectory && Library.IsPlayable(node.Name))
            items.Add(Item("menu.row.play", () => vm.Player.PlayOrToggle(node)));

        var select = node.SelectedFiles < node.FileCount;
        items.Add(Item(select ? "menu.row.select" : "menu.row.deselect", () => vm.SelectNode(node, select)));

        if (node.IsDirectory && node.FileCount > 0)
            items.Add(Item("menu.row.downloadAlbum", () => _ = vm.Download.StartAlbumAsync(node)));

        if (!node.IsDirectory || searching)
            items.Add(Item("menu.row.reveal", () => vm.Reveal(node)));

        if (!node.IsDirectory)
        {
            items.Add(AlsoIn(node, vm));
            items.Add(Item("menu.row.versions", () => vm.FindVersions(node)));
            items.Add(Item("menu.row.lyrics", () => _ = vm.LyricsSheet.ShowAsync(node)));
        }

        items.Add(new Separator());
        items.Add(Item("menu.row.copyPath", () => Copy(node.Path)));
        if (!node.IsDirectory)
        {
            items.Add(Item("menu.row.copyLink", () => Copy(ApiClient.DownloadUrl(node.Path))));
            if (Library.LocalCopy(vm.Settings.Destination, node) is { } local)
                items.Add(Item("menu.row.showFile", () => Shell.RevealFile(local)));
        }
        return menu;
    }

    private static MenuItem AlsoIn(CatalogNode node, MainViewModel vm)
    {
        var parent = new MenuItem { Header = Plain(Loc["menu.row.alsoIn"]) };
        var others = vm.RelationsOf(node);
        if (others.Count == 0)
        {
            parent.Items.Add(new MenuItem { Header = Plain(Loc["menu.row.alsoInNone"]), IsEnabled = false });
            return parent;
        }
        foreach (var other in others.Take(MaxAlsoIn))
        {
            var section = vm.SectionOf(other)?.Title;
            var item = new MenuItem { Header = Plain((section is null ? "" : section + ": ") + CatalogRelations.Place(other)) };
            item.Click += (_, _) => vm.Reveal(other);
            parent.Items.Add(item);
        }
        return parent;
    }

    private static MenuItem Item(string key, Action action)
    {
        var item = new MenuItem { Header = Plain(Loc[key]) };
        item.Click += (_, _) => action();
        return item;
    }

    // A TextBlock, since a string header would read an underscore in a file's name as an access key.
    private static TextBlock Plain(string text) => new() { Text = text };

    private static void Copy(string text)
    {
        try { Clipboard.SetText(text); }
        catch (System.Runtime.InteropServices.ExternalException) { /* another app holds the clipboard */ }
    }
}
