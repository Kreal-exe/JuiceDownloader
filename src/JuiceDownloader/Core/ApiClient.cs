using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace JuiceDownloader.Core;

public sealed record ApiItem(
    [property: JsonPropertyName("path")] string? Path,
    [property: JsonPropertyName("type")] string? Type,
    [property: JsonPropertyName("size")] long Size)
{
    [JsonIgnore] public bool IsDirectory => Type == "directory";
}

public sealed record SongEra(
    [property: JsonPropertyName("name")] string? Name,
    [property: JsonPropertyName("description")] string? Description);

public sealed record Song
{
    [JsonPropertyName("id")] public long Id { get; init; }
    [JsonPropertyName("name")] public string Name { get; init; } = "";
    [JsonPropertyName("category")] public string Category { get; init; } = "";
    [JsonPropertyName("path")] public string? Path { get; init; }
    [JsonPropertyName("era")] public SongEra? Era { get; init; }
    [JsonPropertyName("track_titles")] public List<string>? TrackTitles { get; init; }
    [JsonPropertyName("file_names")] public string? FileNames { get; init; }
    [JsonPropertyName("leak_type")] public string? LeakType { get; init; }
    [JsonPropertyName("length")] public string? Length { get; init; }
    [JsonPropertyName("lyrics")] public string? Lyrics { get; init; }
    [JsonPropertyName("synced_lyrics")] public string? SyncedLyrics { get; init; }
}

/// <summary>What the catalog needs from juicewrldapi.com. See docs/architecture.md for what was learned about the API.</summary>
public sealed class ApiClient(HttpClient http)
{
    public const string BaseUrl = "https://juicewrldapi.com/juicewrld";
    private const int PageSize = 100;

    /// <summary>The site asks for one second between requests (robots.txt), and the songs are a list of pages.</summary>
    public TimeSpan PageDelay { get; init; } = TimeSpan.FromSeconds(1);
    public TimeSpan BuildingDelay { get; init; } = TimeSpan.FromSeconds(3);

    public static HttpClient CreateHttp(string version)
    {
        var http = new HttpClient(new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            ConnectTimeout = TimeSpan.FromSeconds(20),
            MaxConnectionsPerServer = DownloadOptions.MaxParallel,
        }) { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"JuiceDownloader/{version}");
        return http;
    }

    public static string DownloadUrl(string path) => $"{BaseUrl}/files/download/?path={Uri.EscapeDataString(path)}";

    /// <summary>The whole tree in one request. The server may still be building it, which it says instead of answering.</summary>
    public async Task<List<ApiItem>> FetchTreeAsync(CancellationToken ct)
    {
        for (var attempt = 0; ; attempt++)
        {
            var page = await GetAsync<TreeResponse>($"{BaseUrl}/files/list-all/", ct);
            if (page.Items is { Count: > 0 }) return page.Items;
            if (!page.Building || attempt >= 5) throw new InvalidDataException("The API returned an empty catalog.");
            await Task.Delay(BuildingDelay, ct);
        }
    }

    /// <summary>How many songs the API holds now.</summary>
    public async Task<int> FetchSongCountAsync(CancellationToken ct) =>
        (await GetAsync<SongPage>($"{BaseUrl}/songs/?page=1&page_size=1&omit=lyrics,synced_lyrics", ct)).Count;

    /// <summary>Every song with its lyrics. Pages are counted here: the API's "next" links are http:// and redirect.</summary>
    public async Task<List<Song>> FetchSongsAsync(IProgress<(int Done, int Total)>? progress, CancellationToken ct)
    {
        var songs = new List<Song>();
        for (var page = 1; ; page++)
        {
            var result = await GetAsync<SongPage>($"{BaseUrl}/songs/?page={page}&page_size={PageSize}", ct);
            songs.AddRange(result.Results ?? []);
            progress?.Report((songs.Count, result.Count));
            if (result.Next is null || result.Results is not { Count: > 0 }) return songs;
            await Task.Delay(PageDelay, ct);
        }
    }

    /// <summary>A piece of a file, for telling two files apart without fetching either.</summary>
    public async Task<byte[]> GetBytesAsync(string path, long from, long to, CancellationToken ct)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, DownloadUrl(path));
                request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(from, to);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeout.CancelAfter(TimeSpan.FromSeconds(30));
                using var response = await http.SendAsync(request, timeout.Token);
                response.EnsureSuccessStatusCode();
                return await response.Content.ReadAsByteArrayAsync(timeout.Token);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && attempt < 2 && e is HttpRequestException or TaskCanceledException or IOException)
            {
                await Task.Delay(TimeSpan.FromSeconds(1 << attempt), ct);
            }
        }
    }

    private async Task<T> GetAsync<T>(string url, CancellationToken ct)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeout.CancelAfter(TimeSpan.FromSeconds(120));
                using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                if ((int)response.StatusCode is 429 or >= 500 && attempt < 3)
                {
                    await Task.Delay(TimeSpan.FromSeconds(2 << attempt), ct);
                    continue;
                }
                response.EnsureSuccessStatusCode();
                await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
                return await JsonSerializer.DeserializeAsync<T>(stream, cancellationToken: timeout.Token)
                       ?? throw new InvalidDataException("The API returned nothing.");
            }
            catch (Exception e) when (!ct.IsCancellationRequested && attempt < 3 && e is HttpRequestException or TaskCanceledException or IOException)
            {
                await Task.Delay(TimeSpan.FromSeconds(2 << attempt), ct);
            }
        }
    }

    private sealed record TreeResponse(
        [property: JsonPropertyName("items")] List<ApiItem>? Items,
        [property: JsonPropertyName("building")] bool Building);

    private sealed record SongPage(
        [property: JsonPropertyName("count")] int Count,
        [property: JsonPropertyName("next")] string? Next,
        [property: JsonPropertyName("results")] List<Song>? Results);
}
