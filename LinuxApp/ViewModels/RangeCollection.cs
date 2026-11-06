using System.Collections;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;

namespace JuiceDownloader.ViewModels;

/// <summary>An observable list that takes thousands of rows as one change, so a list view lays out once and keeps its scroll position.</summary>
public sealed class RangeCollection<T> : ObservableCollection<T>
{
    private List<T> List => (List<T>)Items;

    public void ReplaceAll(IEnumerable<T> items)
    {
        CheckReentrancy();
        List.Clear();
        List.AddRange(items);
        Raise(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
    }

    public void InsertRange(int index, IReadOnlyCollection<T> items)
    {
        if (items.Count == 0) return;
        CheckReentrancy();
        List.InsertRange(index, items);
        Raise(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Add, (IList)items.ToList(), index));
    }

    public void RemoveRange(int index, int count)
    {
        if (count == 0) return;
        CheckReentrancy();
        var removed = List.GetRange(index, count);
        List.RemoveRange(index, count);
        Raise(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Remove, (IList)removed, index));
    }

    private void Raise(NotifyCollectionChangedEventArgs change)
    {
        OnPropertyChanged(new PropertyChangedEventArgs(nameof(Count)));
        OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
        OnCollectionChanged(change);
    }
}
