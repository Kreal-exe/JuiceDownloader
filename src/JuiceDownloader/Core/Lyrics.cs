using System.Text;
using System.Text.RegularExpressions;

namespace JuiceDownloader.Core;

public enum LyricsMatchKind
{
    /// <summary>The API lists this very file under the song.</summary>
    Path,
    /// <summary>The song's list of file names holds this name.</summary>
    FileName,
    /// <summary>The name is one of the song's titles, once session and credit marks are set aside.</summary>
    Title,
    /// <summary>The same, with every bracket, track number, date and mix mark set aside.</summary>
    Loose,
}

/// <summary>Whether the words are of the recording the file holds, which is not a given: the API's session entry of "734"
/// runs to 22,000 characters of takes, its released entry to 2,000, and only one of them fits a given file.</summary>
public enum LyricsFit
{
    /// <summary>A session file with a session's words, or any other file with a finished song's.</summary>
    SameRecording,
    /// <summary>The nearest the API has: the song's words, but from the other kind of recording.</summary>
    OtherRecording,
}

public sealed record LyricsMatch(Song Song, LyricsMatchKind Kind, LyricsFit Fit = LyricsFit.SameRecording);

/// <summary>
/// Finds the words for a file among the API's songs. Wrong lyrics are worse than none, so a file that names a version
/// never takes another version's words, and a song the API itself lists without words stays without.
/// tests/fixtures/lyrics-match.json holds the cases; the macOS app runs the same ones against its port of this class.
/// </summary>
public sealed partial class LyricsIndex
{
    // With its brackets gone a name can come down to a word that says nothing about which song it is.
    private const int MaxSongLength = 5000;
    private static readonly HashSet<string> Generic = ["freestyle", "intro", "outro", "interlude", "skit", "remix", "untitled", "unknown", "song", "track", "audio", "demo", "session"];

    private readonly Dictionary<string, Song> _byPath = new(StringComparer.Ordinal);
    private readonly Dictionary<string, List<Song>> _byFileName = new(StringComparer.Ordinal);
    private readonly Dictionary<string, List<Song>> _byTitle = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _eraByFolder = new(StringComparer.OrdinalIgnoreCase);

    public int SongCount { get; }
    public int WithLyrics { get; }

    public LyricsIndex(IEnumerable<Song> songs)
    {
        foreach (var song in songs)
        {
            SongCount++;
            if (HasWords(song)) WithLyrics++;
            if (!string.IsNullOrEmpty(song.Path)) _byPath[song.Path] = song;
            foreach (var name in FileNamesOf(song)) Add(_byFileName, Key(name, loose: false), song);

            var titles = new HashSet<string> { song.Name };
            if (song.TrackTitles is not null) titles.UnionWith(song.TrackTitles);
            foreach (var title in titles)
            {
                Add(_byTitle, Key(title, loose: false), song);
                Add(_byTitle, Key(title, loose: true), song);
            }

            if (song.Era is { Name: { Length: > 0 } era, Description: { Length: > 0 } description })
                _eraByFolder[description] = era;
        }
    }

    private static void Add(Dictionary<string, List<Song>> map, string key, Song song)
    {
        if (key.Length == 0) return;
        if (!map.TryGetValue(key, out var list)) map[key] = list = [];
        if (!list.Contains(song)) list.Add(song);
    }

    public static bool HasWords(Song song) => !string.IsNullOrWhiteSpace(song.Lyrics) || !string.IsNullOrWhiteSpace(song.SyncedLyrics);

    /// <summary>A file cut from a studio session. Going by its own name and tree: the catalog's era folders are
    /// called "(Sessions)" too, and what is in those is the finished song.</summary>
    public static bool IsSessionFile(string path)
    {
        path = path.Replace('\\', '/');
        return path.StartsWith("Session Edits/", StringComparison.Ordinal) || path.StartsWith("Studio Sessions/", StringComparison.Ordinal)
               || SessionMark().IsMatch(path[(path.LastIndexOf('/') + 1)..]);
    }

    /// <summary>The song's words for a file: an API path, or any path ending in the file's name for files already on disk.</summary>
    /// <summary>The songs known now: what a row asks for a file's length.</summary>
    public static LyricsIndex? Current { get; set; }

    /// <summary>"3:42", when the API lists this very file with a length.</summary>
    public string? LengthOf(string path) => _byPath.TryGetValue(path, out var song) && !string.IsNullOrEmpty(song.Length) ? song.Length : null;

    /// <summary>For a file from elsewhere: its own name first, then with what uploaders add set aside (see <see cref="PlainName"/>).</summary>
    public LyricsMatch? FindOnDisk(string path)
    {
        if (Find(path) is { } match) return match;
        path = path.Replace('\\', '/');
        var slash = path.LastIndexOf('/');
        var name = path[(slash + 1)..];
        var plain = PlainName(name);
        return plain == name ? null : Find(path[..(slash + 1)] + plain);
    }

    /// <summary>"Juice WRLD _ @channel - Calm_Down Unreleased — copy.mp3" is "Calm Down.mp3": artist, uploader, "Unreleased", a copy mark
    /// and a trailing "with stems", "extended" or "unheard" say nothing about the song. Only for files outside the catalog.</summary>
    public static string PlainName(string name)
    {
        var extension = Extension().Match(name).Value;
        var text = Uploader().Replace(StripExtension(name), " ").Replace('_', ' ');   // the uploader first: underscores can be part of the name
        text = LeadingArtist().Replace(text, "");
        text = CopyMark().Replace(text, "");
        text = UnreleasedWord().Replace(text, " ");
        text = TrailingUploadWord().Replace(text, "");
        text = TrailingCopyNumber().Replace(text, "");
        text = Spaces().Replace(text, " ").Trim();
        return text.Length == 0 ? name : text + extension;
    }

    public LyricsMatch? Find(string path)
    {
        path = path.Replace('\\', '/');
        var name = path[(path.LastIndexOf('/') + 1)..];
        var session = IsSessionFile(path);

        if (_byPath.TryGetValue(path, out var listed))
        {
            if (HasWords(listed)) return new LyricsMatch(listed, LyricsMatchKind.Path);
            // The API often keeps a take twice, the words only on its recording-session entry. Another name of the same
            // take may hold them; another take may not, so "Slasher (v3)" stays without the words of "Slasher (v5)".
            var take = VersionOf(listed.Name);
            var twins = _byTitle.GetValueOrDefault(Key(listed.Name, true))?
                .Where(s => HasWords(s) && VersionOf(s.Name) == take && Key(s.Name, true) == Key(listed.Name, true)).ToList() ?? [];
            var twin = twins.Where(s => !IsSessionSong(s)).OrderBy(s => Key(s.Name, false) == Key(listed.Name, false) ? 0 : 1).ThenBy(s => s.Id).FirstOrDefault();
            if (twin is not null) return new LyricsMatch(twin, LyricsMatchKind.Path);
            var taken = twins.Where(FitsAFinishedSong).OrderBy(s => s.Id).FirstOrDefault();
            return taken is null ? null : new LyricsMatch(taken, LyricsMatchKind.Path, LyricsFit.OtherRecording);
        }

        if (NoVocals().IsMatch(name) || path.StartsWith("Instrumentals/", StringComparison.Ordinal) || path.Contains("/Instrumental/"))
            return null;

        var version = VersionOf(name);
        // The file's own kind of recording first, through every way of matching; the other kind only after that.
        return Search(path, name, version, s => IsSessionSong(s) == session, LyricsFit.SameRecording)
               ?? Joined(path, name, Find)
               ?? Search(path, name, version, s => IsSessionSong(s) != session && (session || FitsAFinishedSong(s)), LyricsFit.OtherRecording);
    }

    private LyricsMatch? Search(string path, string name, int? version, Func<Song, bool> allowed, LyricsFit fit)
    {
        if (Pick(_byFileName, Key(name, false), path, null, allowed) is { } byFile) return new LyricsMatch(byFile, LyricsMatchKind.FileName, fit);
        if (Pick(_byTitle, Key(name, false), path, version, allowed) is { } byTitle) return new LyricsMatch(byTitle, LyricsMatchKind.Title, fit);
        if (Pick(_byTitle, Key(name, true), path, version, allowed) is { } loose) return new LyricsMatch(loose, LyricsMatchKind.Loose, fit);
        // "Drinks In The Air (Stuck) [Session Edit]": the song's other name, in brackets.
        foreach (Match bracket in Bracket().Matches(StripExtension(name)))
        {
            if (Credit().IsMatch(bracket.Value) || Version().IsMatch(bracket.Value)) continue;
            var alias = Fold(bracket.Value);
            if (!Generic.Contains(alias) && Pick(_byTitle, alias, path, version, allowed) is { } other)
                return new LyricsMatch(other, LyricsMatchKind.Loose, fit);
        }
        return null;
    }

    /// <summary>A file that joins songs, "Motions + 365 (Session Edit)" or "Miracle + Shoot For Love (ProTools)": each song's
    /// words in turn. Tried after the whole name has failed, so "Black &amp; White" stays one song.</summary>
    private LyricsMatch? Joined(string path, string name, Func<string, LyricsMatch?> find)
    {
        var parts = JoinMark().Split(StripExtension(name));
        if (parts.Length < 2) return null;
        var folder = path[..(path.LastIndexOf('/') + 1)];
        var marks = Bracket().Matches(parts[^1]).Select(m => m.Value).Where(b => Credit().IsMatch(b)).ToArray();
        var found = new List<LyricsMatch>();
        foreach (var part in parts)
        {
            var named = part.Trim();
            foreach (var mark in marks) if (!named.Contains(mark, StringComparison.Ordinal)) named += " " + mark;
            // What the whole file is, each song in it is.
            if (IsSessionFile(path) && !SessionMark().IsMatch(named)) named += " [Session Edit]";
            if (find(folder + named + System.IO.Path.GetExtension(name)) is not { } match) return null;
            found.Add(match);
        }
        var song = new Song
        {
            Id = found[0].Song.Id,
            Name = string.Join(" + ", found.Select(f => f.Song.Name)),
            Category = found[0].Song.Category,
            Era = found[0].Song.Era,
            Lyrics = string.Join("\n\n", found.Select(f => (f.Song.Lyrics ?? "").Trim())),
        };
        return new LyricsMatch(song, LyricsMatchKind.Loose, found.All(f => f.Fit == LyricsFit.SameRecording) ? LyricsFit.SameRecording : LyricsFit.OtherRecording);
    }

    private static bool IsSessionSong(Song song) => song.Category == "recording_session";

    /// <summary>A session's words stand in for a finished song only if they could be that song, not an hour of takes.</summary>
    private static bool FitsAFinishedSong(Song song) => (song.Lyrics?.Length ?? 0) <= MaxSongLength;

    private Song? Pick(Dictionary<string, List<Song>> map, string key, string path, int? version, Func<Song, bool> allowed)
    {
        if (key.Length == 0 || !map.TryGetValue(key, out var all)) return null;
        var candidates = all.Where(s => HasWords(s) && allowed(s)).ToList();
        if (version is { } wanted)
        {
            // Another take of the song can have other verses. A file that says which take it is gets that take or none;
            // a song the API keeps without takes is the same words whatever the file calls itself.
            if (candidates.Any(s => VersionOf(s.Name) == wanted)) candidates = candidates.Where(s => VersionOf(s.Name) == wanted).ToList();
            else candidates = candidates.Where(s => VersionOf(s.Name) is null).ToList();
        }
        if (candidates.Count == 0) return null;

        var order = path.Contains("Released Discography", StringComparison.Ordinal)
            ? new[] { "released", "unreleased", "unsurfaced", "recording_session" }
            : ["unreleased", "released", "unsurfaced", "recording_session"];
        var era = EraOf(path);
        var words = Qualifiers(path[(path.LastIndexOf('/') + 1)..]);
        return candidates
            .OrderByDescending(s => Score(s, era, words, order, key))
            .ThenBy(s => VersionOf(s.Name) ?? 0)
            .ThenBy(s => s.Id)
            .First();
    }

    private static int Score(Song song, string? era, HashSet<string> fileWords, string[] order, string key)
    {
        var rank = Array.IndexOf(order, song.Category);
        var score = -(rank < 0 ? order.Length : rank);
        if (era is not null && song.Era?.Name == era) score += 10;
        // The name itself beats a second title listed for some other recording.
        if (Key(song.Name, false) == key || Key(song.Name, true) == key) score += 4;
        // "(Live)" or "(Extended Outro)" on the song but not on the file is a different recording of the words.
        score -= 3 * Qualifiers(song.Name).Count(w => !fileWords.Contains(w));
        return score;
    }

    /// <summary>The era a folder like "7. Goodbye &amp; Good Riddance (Sessions)" belongs to, read off the API's own descriptions.</summary>
    private string? EraOf(string path)
    {
        foreach (var segment in path.Split('/'))
        {
            var folder = FolderSuffix().Replace(Catalog.DisplayName(segment), "");
            if (_eraByFolder.TryGetValue(folder, out var era)) return era;
        }
        return null;
    }

    private static IEnumerable<string> FileNamesOf(Song song)
    {
        foreach (var line in (song.FileNames ?? "").Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            // "File Name (1): naruto", "Explicit: 06 Blood on My Jeans", "Session Title: juice 4.ptx", or a bare name.
            var label = FileNameLabel().Match(line);
            if (label.Success && NotAFile().IsMatch(label.Value)) continue;
            var name = line[label.Length..].Trim();
            if (name.Length > 0 && !name.Equals("N/A", StringComparison.OrdinalIgnoreCase)) yield return name;
        }
    }

    private static int? VersionOf(string name)
    {
        var match = Version().Match(name);
        return match.Success ? int.Parse(match.Groups[1].Value) : null;
    }

    private static HashSet<string> Qualifiers(string name)
    {
        var words = new HashSet<string>(StringComparer.Ordinal);
        foreach (Match bracket in Bracket().Matches(StripExtension(name)))
        {
            if (Credit().IsMatch(bracket.Value) || Version().IsMatch(bracket.Value)) continue;
            words.Add(Fold(bracket.Value));
        }
        return words;
    }

    public static string Key(string name, bool loose)
    {
        var text = Credit().Replace(StripExtension(name).Trim(), " ");
        text = TrailingCredit().Replace(text, " ");
        if (loose)
        {
            text = Bracket().Replace(text, " ");
            text = TrackNumber().Replace(text, " ");
            text = DateStamp().Replace(text, " ");
            text = AnyVersion().Replace(text, " ");
            text = ArtistWords().Replace(text, " ");
            text = TrailingMixWord().Replace(text, " ");
        }
        var key = Fold(text);
        return loose && Generic.Contains(key) ? "" : key;
    }

    private static string StripExtension(string name) => Extension().Replace(name, "");

    private static string Fold(string text)
    {
        var folded = new StringBuilder(text.Length);
        foreach (var c in text.Normalize(NormalizationForm.FormKC))
            if (char.IsLetterOrDigit(c)) folded.Append(char.ToLowerInvariant(c));
        return folded.ToString();
    }

    [GeneratedRegex(@"\.[A-Za-z0-9]{2,4}$")] private static partial Regex Extension();
    [GeneratedRegex(@"[\(\[\{][^\)\]\}]*[\)\]\}]")] private static partial Regex Bracket();
    [GeneratedRegex(@"[\(\[\{]\s*(session edit|sessions?|studio session( edit)?|pro ?tools|logic session|multi-?track stems|stems|feat\.?[^\)\]\}]*|ft\.?[^\)\]\}]*|with [^\)\]\}]*|prod\.?[^\)\]\}]*|best|master|mastered|remaster(ed)?|rough|og|og file|explicit|clean|demo)\s*[\)\]\}]", RegexOptions.IgnoreCase)] private static partial Regex Credit();
    [GeneratedRegex(@"\b(feat|ft|prod)\b\.?.*$", RegexOptions.IgnoreCase)] private static partial Regex TrailingCredit();
    [GeneratedRegex(@"^\s*\d{1,2}[\s._-]+")] private static partial Regex TrackNumber();
    [GeneratedRegex(@"\b\d{6,8}\b")] private static partial Regex DateStamp();
    [GeneratedRegex(@"\bv\d+(\.\d+)?\b", RegexOptions.IgnoreCase)] private static partial Regex AnyVersion();
    [GeneratedRegex(@"\bv(\d+)\b(?!\.\d)", RegexOptions.IgnoreCase)] private static partial Regex Version();
    [GeneratedRegex(@"\b(juice\s*wrld|juice\s*world|juicethekidd?)\b", RegexOptions.IgnoreCase)] private static partial Regex ArtistWords();
    [GeneratedRegex(@"@\w+")] private static partial Regex Uploader();
    [GeneratedRegex(@"^\s*(juice\s*(wrld|world)?|juicethekidd?)\s*[-–—]+\s*", RegexOptions.IgnoreCase)] private static partial Regex LeadingArtist();
    [GeneratedRegex(@"(\s*[-–—]\s*(копия|copy)|\s+копия)(\s+\d+)?\s*$", RegexOptions.IgnoreCase)] private static partial Regex CopyMark();
    [GeneratedRegex(@"[\(\[\{]?\bunreleased\b[\)\]\}]?", RegexOptions.IgnoreCase)] private static partial Regex UnreleasedWord();
    [GeneratedRegex(@"[\s.-]+(with\s+)?(stems?|extended|unheard)\s*$", RegexOptions.IgnoreCase)] private static partial Regex TrailingUploadWord();
    [GeneratedRegex(@"(?<=[\)\]\}])\s*\d{1,2}\s*$")] private static partial Regex TrailingCopyNumber();
    [GeneratedRegex(@"\s+")] private static partial Regex Spaces();
    [GeneratedRegex(@"[\s._-]+(final|new|master|mastered|rough|mix|session)[\s._-]*\d*\s*$", RegexOptions.IgnoreCase)] private static partial Regex TrailingMixWord();
    [GeneratedRegex(@"instrumental|\bbeat\b", RegexOptions.IgnoreCase)] private static partial Regex NoVocals();
    [GeneratedRegex(@"session edit|[\(\[\{]\s*(studio )?sessions?\s*[\)\]\}]|\bsession\b(\s+v\d+)?\s*(\.[A-Za-z0-9]{2,4})?$", RegexOptions.IgnoreCase)] private static partial Regex SessionMark();
    [GeneratedRegex(@"\s*\(Sessions\)$")] private static partial Regex FolderSuffix();
    [GeneratedRegex(@"\s+(?:\+|&|and|x)\s+|\s*,\s+", RegexOptions.IgnoreCase)] private static partial Regex JoinMark();
    [GeneratedRegex(@"^\s*[^:]{1,40}:\s*")] private static partial Regex FileNameLabel();
    [GeneratedRegex(@"^\s*(session|folder|instrumental)", RegexOptions.IgnoreCase)] private static partial Regex NotAFile();
}

/// <summary>The API's timed words are "[0:07.04] Yeah"; players expect the LRC form, "[00:07.04]Yeah".</summary>
public static partial class Lrc
{
    public static string? Normalize(string? synced)
    {
        if (string.IsNullOrWhiteSpace(synced)) return null;
        var lines = new List<string>();
        foreach (var raw in synced.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var match = Timed().Match(raw);
            if (!match.Success) continue;
            var fraction = match.Groups[3].Success ? match.Groups[3].Value.PadRight(2, '0')[..2] : "00";
            lines.Add($"[{match.Groups[1].Value.PadLeft(2, '0')}:{match.Groups[2].Value}.{fraction}]{match.Groups[4].Value.Trim()}");
        }
        return lines.Count > 0 ? string.Join('\n', lines) + "\n" : null;
    }

    public static string Plain(string text) => string.Join('\n', text.Split(["\r\n", "\n", "\r"], StringSplitOptions.None)).Trim() + "\n";

    [GeneratedRegex(@"^\s*\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]\s?(.*)$")] private static partial Regex Timed();
}

public sealed record LyricsOptions(bool Embed, bool Sidecar, bool TimedInTag);

public enum LyricsResult { None, Written, AlreadyThere, Failed }

public static class LyricsWriter
{
    /// <summary>
    /// Puts a song's words on a file: in its tag where the format allows, and beside it as name.lrc (timed) or name.txt
    /// (words only). A format this app cannot tag — WAV, M4A, AIFF, a ZIP of a session — always gets the file beside it,
    /// or the words would go nowhere.
    /// </summary>
    public static LyricsResult Apply(string file, Song song, LyricsOptions options) => Apply(file, song.Lyrics, song.SyncedLyrics, options, false);

    /// <param name="replace">Words already there give way: only for better ones, the session's own over the song's.</param>
    public static LyricsResult Apply(string file, string? words, string? synced, LyricsOptions options, bool replace)
    {
        var timed = Lrc.Normalize(synced);
        var plain = !string.IsNullOrWhiteSpace(words) ? Lrc.Plain(words) : timed is null ? null : Lrc.Plain(PlainFromTimed(timed));
        if (plain is null) return LyricsResult.None;

        var result = LyricsResult.AlreadyThere;
        var tagged = false;
        try
        {
            if (options.Embed && Id3Lyrics.CanTag(file))
            {
                tagged = true;
                if (replace || !Id3Lyrics.Has(file))
                {
                    Id3Lyrics.Write(file, options.TimedInTag && timed is not null ? timed : plain);
                    result = LyricsResult.Written;
                }
            }
            var lrc = Path.ChangeExtension(file, ".lrc");
            var txt = Path.ChangeExtension(file, ".txt");
            if (options.Sidecar || !tagged)
            {
                var beside = timed is not null ? lrc : txt;
                if (replace || !File.Exists(lrc) && !File.Exists(txt))
                {
                    File.Delete(lrc);
                    File.Delete(txt);
                    File.WriteAllText(beside, timed ?? plain, new UTF8Encoding(false));
                    result = LyricsResult.Written;
                }
            }
            return result;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            return LyricsResult.Failed;
        }
    }

    /// <summary>Whether a file already carries words, in its tag or beside it.</summary>
    public static bool Has(string file)
    {
        if (File.Exists(Path.ChangeExtension(file, ".lrc")) || File.Exists(Path.ChangeExtension(file, ".txt"))) return true;
        try
        {
            return Id3Lyrics.CanTag(file) && Id3Lyrics.Has(file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            return false;
        }
    }

    private static string PlainFromTimed(string timed) =>
        string.Join('\n', timed.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l[(l.IndexOf(']') + 1)..]));
}
