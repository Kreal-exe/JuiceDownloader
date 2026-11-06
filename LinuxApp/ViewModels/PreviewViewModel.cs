using System.Text;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;

namespace JuiceDownloader.ViewModels;

/// <summary>The preview sheet: a look at a photo, a clip or a text before downloading it, walking the files of its folder.</summary>
public sealed partial class PreviewViewModel : ObservableObject, IDisposable
{
    private const long AskAbove = 200L * 1024 * 1024;
    private const int MaxText = 1024 * 1024;
    private const int ImageWidth = 1600;

    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly SettingsViewModel _settings;
    private readonly PlayerViewModel _player;
    private readonly IDialogService _dialogs;
    private readonly HttpClient _http;
    private readonly Action _selectionChanged;
    private readonly MpvVideo _video;
    private List<CatalogNode> _files = [];
    private int _index;
    private CancellationTokenSource? _cts;
    private Task _videoWork = Task.CompletedTask;

    public PreviewViewModel(string userAgent, SettingsViewModel settings, PlayerViewModel player, IDialogService dialogs, HttpClient http, Action selectionChanged)
    {
        _settings = settings;
        _player = player;
        _dialogs = dialogs;
        _http = http;
        _selectionChanged = selectionChanged;
        _video = new MpvVideo(userAgent);
    }

    [ObservableProperty] private bool _isOpen;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private Bitmap? _image;
    [ObservableProperty] private string? _text;
    [ObservableProperty] private bool _isVideo;
    [ObservableProperty] private string? _message;
    [ObservableProperty] private CatalogNode? _current;

    public string Name => Current?.Name ?? "";
    public string Place => Current is { } node ? CatalogRelations.Place(node) : "";
    public string CountText => Loc.Format("preview.count", ByteFormatter.FormatCount(_index + 1), ByteFormatter.FormatCount(_files.Count));
    public bool HasPrevious => _index > 0;
    public bool HasNext => _index < _files.Count - 1;
    public bool HasImage => Image is not null;
    public bool HasText => Text is not null;
    public bool HasMessage => !string.IsNullOrEmpty(Message);
    public bool IsSelected => Current is { SelectedFiles: > 0 };
    public string SelectText => Loc[IsSelected ? "preview.selected" : "preview.select"];

    partial void OnImageChanged(Bitmap? value) => OnPropertyChanged(nameof(HasImage));
    partial void OnTextChanged(string? value) => OnPropertyChanged(nameof(HasText));
    partial void OnMessageChanged(string? value) => OnPropertyChanged(nameof(HasMessage));

    partial void OnCurrentChanged(CatalogNode? value)
    {
        OnPropertyChanged(nameof(Name));
        OnPropertyChanged(nameof(Place));
        OnPropertyChanged(nameof(CountText));
        OnPropertyChanged(nameof(HasPrevious));
        OnPropertyChanged(nameof(HasNext));
        RaiseSelected();
    }

    private void RaiseSelected()
    {
        OnPropertyChanged(nameof(IsSelected));
        OnPropertyChanged(nameof(SelectText));
    }

    public void Open(CatalogNode file)
    {
        _files = file.Parent?.Children.Where(c => !c.IsDirectory && Library.PreviewOf(c.Name) != PreviewKind.None).ToList() ?? [file];
        _index = Math.Max(0, _files.FindIndex(f => ReferenceEquals(f, file)));
        IsOpen = true;
        _ = ShowAsync();
    }

    [RelayCommand]
    public void Next() => Step(1);

    [RelayCommand]
    public void Previous() => Step(-1);

    private void Step(int by)
    {
        if (!IsOpen || _index + by < 0 || _index + by >= _files.Count) return;
        _index += by;
        _ = ShowAsync();
    }

    [RelayCommand]
    public void Close()
    {
        IsOpen = false;
        Clear();
        Current = null;
    }

    [RelayCommand]
    private void ToggleSelect()
    {
        if (Current is not { } node) return;
        Catalog.Select(node, node.SelectedFiles == 0);
        _selectionChanged();
        RaiseSelected();
    }

    /// <summary>The selection changed elsewhere, or by this sheet: the checkbox follows it.</summary>
    public void OnSelectionChanged() => RaiseSelected();

    private void Clear()
    {
        _cts?.Cancel();
        _cts = null;
        // In order: a clip that starts next must not be stopped by this.
        if (IsVideo) _videoWork = _videoWork.ContinueWith(_ => _video.Stop(), TaskScheduler.Default);
        IsVideo = false;
        IsLoading = false;
        Text = null;
        Message = null;
        // Only the picture on screen stays in memory.
        var previous = Image;
        Image = null;
        previous?.Dispose();
    }

    private async Task ShowAsync()
    {
        Clear();
        var file = _files[_index];
        Current = file;
        var cts = _cts = new CancellationTokenSource();

        var local = Library.LocalCopy(_settings.Destination, file);
        // Only what would have to come over the network is worth a question.
        if (local is null && file.Size > AskAbove)
        {
            var go = await _dialogs.ConfirmAsync(Loc["preview.title"], Loc.Format("preview.tooBig", ByteFormatter.Format(file.Size)), Loc["preview.open"], danger: false);
            if (cts.IsCancellationRequested) return;
            if (!go)
            {
                Message = Loc.Format("preview.tooBig", ByteFormatter.Format(file.Size));
                return;
            }
        }

        var kind = Library.PreviewOf(file.Name);
        IsLoading = kind != PreviewKind.Video;
        try
        {
            switch (kind)
            {
                case PreviewKind.Image:
                    var image = await Task.Run(() => LoadImageAsync(local, file, cts.Token));
                    if (cts.IsCancellationRequested) image.Dispose();
                    else Image = image;
                    break;
                case PreviewKind.Text:
                    var text = await Task.Run(() => LoadTextAsync(local, file, cts.Token));
                    if (!cts.IsCancellationRequested) Text = text;
                    break;
                case PreviewKind.Video:
                    // Its picture has a window of its own, so the music stops for it.
                    if (_player.IsPlaying) _player.PlayPauseCommand.Execute(null);
                    IsVideo = true;
                    var source = local ?? ApiClient.DownloadUrl(file.Path);
                    var play = _videoWork.ContinueWith(_ => _video.Play(source, file.Name), TaskScheduler.Default);
                    _videoWork = play;
                    var started = await play;
                    if (cts.IsCancellationRequested) return;
                    if (!started)
                    {
                        IsVideo = false;
                        Message = Loc["preview.noVideo"];
                    }
                    break;
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception e) when (e is HttpRequestException or IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or NullReferenceException)
        {
            // A format the decoder does not know ends here too.
            if (!cts.IsCancellationRequested) Message = Loc.Format("preview.failed", e is NullReferenceException ? "" : e.Message).Trim();
        }
        if (!cts.IsCancellationRequested) IsLoading = false;
    }

    private async Task<Bitmap> LoadImageAsync(string? local, CatalogNode file, CancellationToken ct)
    {
        await using var stream = local is not null ? File.OpenRead(local) : await DownloadAsync(file, ct);
        ct.ThrowIfCancellationRequested();
        return Bitmap.DecodeToWidth(stream, ImageWidth);
    }

    private async Task<Stream> DownloadAsync(CatalogNode file, CancellationToken ct)
    {
        using var response = await _http.GetAsync(ApiClient.DownloadUrl(file.Path), HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        var memory = new MemoryStream();
        await response.Content.CopyToAsync(memory, ct);
        memory.Position = 0;
        return memory;
    }

    private async Task<string> LoadTextAsync(string? local, CatalogNode file, CancellationToken ct)
    {
        var buffer = new byte[MaxText];
        var length = 0;
        if (local is not null)
        {
            await using var stream = File.OpenRead(local);
            length = await stream.ReadAtLeastAsync(buffer, MaxText, throwOnEndOfStream: false, ct);
        }
        else
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, ApiClient.DownloadUrl(file.Path));
            request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(0, MaxText - 1);
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();
            await using var stream = await response.Content.ReadAsStreamAsync(ct);
            length = await stream.ReadAtLeastAsync(buffer, MaxText, throwOnEndOfStream: false, ct);
        }
        return Encoding.UTF8.GetString(buffer, 0, length);
    }

    public void OnLanguageChanged()
    {
        OnPropertyChanged(nameof(CountText));
        OnPropertyChanged(nameof(SelectText));
    }

    public void Dispose() => _video.Stop();
}
