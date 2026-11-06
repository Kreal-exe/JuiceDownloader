using System.Text.Json;

namespace JuiceDownloader.Core;

/// <summary>The last catalog and lyrics seen, so the app opens at once and works out what it can before the network answers.</summary>
public sealed class CatalogCache(string directory)
{
    private string TreePath => Path.Combine(directory, "catalog.json");
    private string SongsPath => Path.Combine(directory, "songs.json");

    public List<ApiItem>? LoadTree() => Load<List<ApiItem>>(TreePath);
    public List<Song>? LoadSongs() => Load<List<Song>>(SongsPath);
    public void SaveTree(List<ApiItem> items) => Save(TreePath, items);
    public void SaveSongs(List<Song> songs) => Save(SongsPath, songs);
    public Dictionary<string, bool> LoadSameAudio() => Load<Dictionary<string, bool>>(Path.Combine(directory, "same-audio.json")) ?? new Dictionary<string, bool>(StringComparer.Ordinal);
    public void SaveSameAudio(Dictionary<string, bool> known) => Save(Path.Combine(directory, "same-audio.json"), known);
    public DateTime? TreeTime => File.Exists(TreePath) ? File.GetLastWriteTimeUtc(TreePath) : null;
    public DateTime? SongsTime => File.Exists(SongsPath) ? File.GetLastWriteTimeUtc(SongsPath) : null;

    private static T? Load<T>(string path) where T : class
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var stream = File.OpenRead(path);
            return JsonSerializer.Deserialize<T>(stream);
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void Save<T>(string path, T value)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var tmp = path + ".tmp";
            using (var stream = File.Create(tmp)) JsonSerializer.Serialize(stream, value);
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // a cache that cannot be written only costs a slower next launch
        }
    }
}
