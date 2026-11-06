using System.Windows.Controls;

namespace JuiceDownloader.Controls;

/// <summary>
/// A checkbox that only shows what it is bound to. A click runs its command and leaves the state to the binding: a
/// half-ticked folder goes to fully ticked (a plain CheckBox would clear it), and a selection that takes a moment never
/// shows a state the model does not have.
/// </summary>
public sealed class TriCheck : CheckBox
{
    protected override void OnToggle()
    {
    }
}
