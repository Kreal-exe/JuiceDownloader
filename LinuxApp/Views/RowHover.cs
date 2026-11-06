using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;

namespace JuiceDownloader.Views;

/// <summary>
/// A row of a virtualized list is hovered only while the pointer is on it now. The system's pointer-over state follows
/// pointer moves, so it lags behind a list that scrolls or recycles a row under a still pointer; this works it out from
/// where the pointer last was, whenever the rows or the pointer move, and puts .hot on the row's button.
/// </summary>
internal sealed class RowHover
{
    private readonly ListBox _list;
    private readonly Action<object?>? _hovered;
    private Point? _pointer;

    private RowHover(ListBox list, Action<object?>? hovered)
    {
        _list = list;
        _hovered = hovered;
        list.AddHandler(InputElement.PointerMovedEvent, (_, e) => { _pointer = e.GetPosition(list); Update(); }, RoutingStrategies.Tunnel, handledEventsToo: true);
        list.AddHandler(InputElement.PointerEnteredEvent, (_, e) => { _pointer = e.GetPosition(list); Update(); }, RoutingStrategies.Direct, handledEventsToo: true);
        list.PointerExited += (_, _) => { _pointer = null; Update(); };
        list.ContainerPrepared += (_, _) => Update();
        list.ContainerClearing += (_, _) => Update();
        list.AddHandler(ScrollViewer.ScrollChangedEvent, (_, _) => Update(), RoutingStrategies.Bubble, handledEventsToo: true);
        list.LayoutUpdated += (_, _) => Update();
    }

    /// <summary>The callback hears which row's data the pointer is on, or null.</summary>
    public static void Attach(ListBox list, Action<object?>? hovered = null) => _ = new RowHover(list, hovered);

    public static Button? RowOf(Control container) =>
        container.GetVisualDescendants().OfType<Button>().FirstOrDefault(b => b.Classes.Contains("listed"));

    private void Update()
    {
        object? on = null;
        foreach (var container in _list.GetRealizedContainers())
        {
            if (RowOf(container) is not { } row) continue;
            var hot = _pointer is { } p && row.TranslatePoint(default, _list) is { } at && new Rect(at, row.Bounds.Size).Contains(p);
            if (hot) on = row.DataContext;
            if (hot != row.Classes.Contains("hot")) row.Classes.Set("hot", hot);
        }
        _hovered?.Invoke(on);
    }
}
