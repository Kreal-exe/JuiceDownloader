using System.IO;
using System.Net.Http;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using JuiceDownloader.Core;
using JuiceDownloader.Localization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

/// <summary>
/// A look at a photo, video or text before it is downloaded. What is not on disk yet comes to a temporary file first,
/// since neither MediaElement nor a BitmapImage can send the app's User-Agent; the file goes with the next look or the close.
/// </summary>
public sealed partial class PreviewViewModel : ObservableObject
{
    private const long AskAbove = 200L * 1024 * 1024;
    private const int MaxText = 1 << 20;

    private static LocalizationManager Loc => LocalizationManager.Instance;
    private static readonly string TempFolder = Path.Combine(Path.GetTempPath(), "JuiceDownloader", "preview");

    private readonly HttpClient _http;
    private readonly SettingsViewModel _settings;
    private readonly PlayerViewModel _player;
    private readonly IDialogService _dialogs;
    private readonly MainViewModel _owner;
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;

    private CancellationTokenSource? _loading;
    private CatalogNode? _current;
    private string? _temp;
    private string? _videoFromLocal;
    private bool _isSelected;

    public PreviewViewModel(HttpClient http, SettingsViewModel settings, PlayerViewModel player, IDialogService dialogs, MainViewModel owner)
    {
        _http = http;
        _settings = settings;
        _player = player;
        _dialogs = dialogs;
        _owner = owner;
    }

    [ObservableProperty] private bool _isVisible;
    [ObservableProperty] private string _title = string.Empty;
    [ObservableProperty] private string _place = string.Empty;
    [ObservableProperty] private string _countText = string.Empty;
    [ObservableProperty] private bool _hasPrevious;
    [ObservableProperty] private bool _hasNext;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string _loadingText = string.Empty;
    [ObservableProperty] private string _errorText = string.Empty;
    [ObservableProperty] private ImageSource? _image;
    [ObservableProperty] private string _text = string.Empty;
    /// <summary>The file for the view's MediaElement to play; null stops it.</summary>
    [ObservableProperty] private string? _videoFile;

    public bool IsVideo => VideoFile is not null;
    public bool HasText => Text.Length > 0;

    /// <summary>The room the picture has, in device pixels: it is never decoded larger. The view keeps this up to date.</summary>
    public int RoomWidth { get; set; } = 1920;
    public int RoomHeight { get; set; } = 1200;

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (!SetProperty(ref _isSelected, value) || _current is not { } file) return;
            _owner.SelectNode(file, value);
        }
    }

    partial void OnVideoFileChanged(string? value) => OnPropertyChanged(nameof(IsVideo));
    partial void OnTextChanged(string value) => OnPropertyChanged(nameof(HasText));

    public async Task OpenAsync(CatalogNode file)
    {
        // Only what would have to come over the network is worth a question. Whatever is showing stays until the answer is yes.
        if (file.Size > AskAbove && Library.LocalCopy(_settings.Destination, file) is null && !await _dialogs.ConfirmAsync(Loc["preview.title"], Loc.Format("preview.tooBig", ByteFormatter.Format(file.Size)), Loc["preview.open"], danger: false))
            return;

        _loading?.Cancel();
        var loading = new CancellationTokenSource(); // stays cancellable after this method ends, for the video it started
        _loading = loading;

        Clear();
        _current = file;
        Title = file.Name;
        Place = CatalogRelations.Place(file);
        _isSelected = file.SelectedFiles == 1;
        OnPropertyChanged(nameof(IsSelected));
        var (files, at) = Neighbours();
        CountText = Loc.Format("preview.count", ByteFormatter.FormatCount(at + 1), ByteFormatter.FormatCount(files.Count));
        HasPrevious = at > 0;
        HasNext = at >= 0 && at < files.Count - 1;
        LoadingText = Loc["preview.loading"];
        IsLoading = true;
        IsVisible = true;

        try
        {
            var kind = Library.PreviewOf(file.Name);
            var destination = _settings.Destination;
            var local = await Task.Run(() => Library.LocalCopy(destination, file), loading.Token);
            var source = local ?? await FetchAsync(file, loading.Token);

            switch (kind)
            {
                case PreviewKind.Image:
                    var (width, height) = (RoomWidth, RoomHeight);
                    var picture = await Task.Run(() => Decode(source, width, height), loading.Token);
                    loading.Token.ThrowIfCancellationRequested();
                    Image = picture;
                    break;
                case PreviewKind.Text:
                    var text = await Task.Run(() => ReadText(source), loading.Token);
                    loading.Token.ThrowIfCancellationRequested();
                    Text = text;
                    break;
                case PreviewKind.Video:
                    loading.Token.ThrowIfCancellationRequested();
                    _player.Pause();
                    _videoFromLocal = local;
                    VideoFile = source;
                    break;
                default:
                    throw new NotSupportedException(file.Name);
            }
            IsLoading = false;
        }
        catch (OperationCanceledException) when (loading.IsCancellationRequested)
        {
            // another file was asked for, or the sheet was closed
        }
        catch (Exception e)
        {
            // Anything a broken file or an absent codec can throw belongs on the sheet, not in the user's way.
            if (!loading.IsCancellationRequested) Fail(e.Message);
        }
    }

    /// <summary>The view's MediaElement could not play it. A path it cannot read as a URL, such as one with a '#', gets one more try from a plain name.</summary>
    public async void VideoFailed(string reason)
    {
        if (_videoFromLocal is not { } local)
        {
            Fail(reason);
            return;
        }

        _videoFromLocal = null;
        var token = _loading?.Token ?? CancellationToken.None;
        VideoFile = null;
        try
        {
            var temp = NewTemp(local);
            _temp = temp;
            await Task.Run(() =>
            {
                Directory.CreateDirectory(TempFolder);
                File.Copy(local, temp, overwrite: true);
            }, token);
            if (!token.IsCancellationRequested) VideoFile = temp;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Fail(e.Message);
        }
    }

    private void Fail(string reason)
    {
        IsLoading = false;
        VideoFile = null;
        ErrorText = Loc.Format("preview.failed", reason);
    }

    private async Task<string> FetchAsync(CatalogNode file, CancellationToken ct)
    {
        var temp = NewTemp(file.Name);
        _temp = temp;
        var total = ByteFormatter.Format(file.Size);
        var progress = new Latest<long>(_dispatcher, done =>
        {
            if (IsLoading && !ct.IsCancellationRequested)
                LoadingText = Loc["preview.loading"] + " " + Loc.Format("download.progress", ByteFormatter.Format(done), total);
        });
        await MediaFetch.ToFileAsync(_http, ApiClient.DownloadUrl(file.Path), temp, progress, ct);
        return temp;
    }

    /// <summary>Decoded to no more than there is room for, on the longer side of the fit, and frozen so it can cross threads.</summary>
    private static BitmapSource Decode(string file, int roomWidth, int roomHeight)
    {
        using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
        var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).Frames[0];
        var (width, height) = (frame.PixelWidth, frame.PixelHeight);
        stream.Position = 0;

        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
        if (width > roomWidth || height > roomHeight)
        {
            // Setting one side keeps the proportions.
            if ((double)width / roomWidth >= (double)height / roomHeight) image.DecodePixelWidth = roomWidth;
            else image.DecodePixelHeight = roomHeight;
        }
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
    }

    private static string ReadText(string file)
    {
        using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
        var buffer = new byte[MaxText];
        var read = stream.ReadAtLeast(buffer, MaxText, throwOnEndOfStream: false);
        return Encoding.UTF8.GetString(buffer, 0, read);
    }

    private (List<CatalogNode> Files, int At) Neighbours()
    {
        if (_current?.Parent is not { } parent) return ([], -1);
        var files = parent.Children.Where(n => !n.IsDirectory && Library.PreviewOf(n.Name) != PreviewKind.None).ToList();
        return (files, files.IndexOf(_current));
    }

    [RelayCommand]
    private void Previous() => Step(-1);

    [RelayCommand]
    private void Next() => Step(1);

    private void Step(int step)
    {
        var (files, at) = Neighbours();
        if (at < 0) return;
        at += step;
        if (at >= 0 && at < files.Count) _ = OpenAsync(files[at]);
    }

    [RelayCommand]
    private void Close()
    {
        _loading?.Cancel();
        Clear();
        _current = null;
        IsLoading = false;
        IsVisible = false;
    }

    /// <summary>Drops what was showing, the memory and the file with it.</summary>
    private void Clear()
    {
        Image = null;
        Text = string.Empty;
        VideoFile = null;
        ErrorText = string.Empty;
        _videoFromLocal = null;
        if (_temp is not { } temp) return;
        _temp = null;
        _ = Task.Run(async () =>
        {
            await Task.Delay(500); // the media stack lets go of it a moment after it stops
            MediaFetch.TryDelete(temp);
        });
    }

    /// <summary>When the window closes: removes the temporary file and what is left of earlier runs.</summary>
    public void Shutdown()
    {
        _loading?.Cancel();
        VideoFile = null;
        MediaFetch.Sweep(TempFolder);
    }

    private static string NewTemp(string name) => Path.Combine(TempFolder, Guid.NewGuid().ToString("N") + Path.GetExtension(name).ToLowerInvariant());
}
