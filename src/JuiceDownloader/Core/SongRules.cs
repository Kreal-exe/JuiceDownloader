using System.Text;
using System.Text.RegularExpressions;

namespace JuiceDownloader.Core;

/// <summary>What "Download by rules" keeps.</summary>
public sealed record RuleOptions
{
    /// <summary>Section ids to take songs from. The Compilation's trees are the finished songs; the rest of the catalog is raw material.</summary>
    public IReadOnlyList<string> Sections { get; init; } = ["unreleased", "sessionEdits"];
    /// <summary>One file per song, the best of its takes.</summary>
    public bool OneVersion { get; init; } = true;
    /// <summary>Leave out songs that came out officially: their demos are not unreleased music.</summary>
    public bool SkipReleased { get; init; } = true;
    /// <summary>Files the user took out of the folder for good: never offered again.</summary>
    public IReadOnlyCollection<string> NeverOffer { get; init; } = [];
    /// <summary>Leave out what was never finished: hook only, or only ever with a verse left open.</summary>
    public bool SkipUnfinished { get; init; }
    /// <summary>Everything in one folder, not by era.</summary>
    public bool OneFolder { get; init; } = true;
    public string FolderName { get; init; } = "Unreleased";
    /// <summary>Lives, snippets and bits too short to be songs, each as it is, in a folder of their own. Off by default.</summary>
    public bool WithClips { get; init; }
    /// <summary>Files the user called clips by hand: a live with no mark in its name. Left out like any clip, offered with them.</summary>
    public IReadOnlyCollection<string> ClipPaths { get; init; } = [];
    public string ClipsFolderName { get; init; } = "IG Lives & Clips";
}

public sealed record SongVersion(CatalogNode File, Song? Song, int Score, string Why);

/// <summary>One song and its takes: <see cref="Picked"/> is what gets downloaded.</summary>
public sealed class SongGroup(string title, List<SongVersion> versions)
{
    public string Title { get; } = title;
    public List<SongVersion> Versions { get; } = versions;
    public SongVersion Picked { get; set; } = versions[0];
    public bool IsReleasedSong { get; internal set; }
    public bool IsUnfinished { get; internal set; }
    /// <summary>A live, a snippet or a bit too short to be a song: offered only with <see cref="RuleOptions.WithClips"/>.</summary>
    public bool IsClip { get; internal set; }
}

public sealed record RuleResult(IReadOnlyList<SongGroup> Kept, int FilesConsidered, int SkippedVersions, int SkippedReleased, int SkippedUnfinished)
{
    /// <summary>Files left out for having the very same audio as another one kept.</summary>
    public int SkippedCopies { get; init; }

    public long Bytes => Kept.Sum(g => g.Picked.File.Size);
}

/// <summary>
/// Turns the catalog's takes into songs. The Compilation's Unreleased tree holds 1,511 files of about 1,000 songs:
/// "Bad Boy" alone is eleven. A song is its name without credits and take marks; another title of it only counts as
/// the same song when the words agree, since "Lonely Road" and "Hate The Other Side" share a title list but not verses.
/// </summary>
public static partial class SongRules
{
    /// <summary>A song's title alone: no mix, take, credit or extension, so that "Big (TV Mix) [v1].mp3" is the album's "Big".</summary>
    private static string BareTitle(string name)
    {
        var text = Path.GetExtension(name).Length is > 0 and <= 5 ? Path.GetFileNameWithoutExtension(name) : name;
        text = Regex.Replace(text, @"[(\[{][^)\]}]*[)\]}]", " ");
        text = Regex.Replace(text, @"\s(feat\.?|ft\.?|featuring|prod\.?|with)\s.*$", "", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"\s+v\d+\s*$", "", RegexOptions.IgnoreCase);
        return Fold(text);
    }

    /// <summary>The name a song on a self-released EP later came out under: "ALL GIRLS ARE THE SAME 999" is All Girls Are The Same.</summary>
    private static string WithoutEraMark(string key, Song? song)
    {
        if (song is null || !IsUnofficial(song)) return key;
        var mark = Regex.Match(key, "(999|3)$");
        return mark.Success && mark.Index > 0 ? key[..mark.Index] : key;
    }

    private static bool IsUnofficial(Song song) => song.LeakType?.Contains("Unofficial", StringComparison.OrdinalIgnoreCase) == true;

    /// <summary>A file this small with no length known is a clip: the shortest songs kept run 47 seconds and 780 KB.</summary>
    public const long TinyClipBytes = 500_000;

    public static RuleResult Apply(Catalog catalog, IEnumerable<Song> songs, RuleOptions options)
    {
        var all = songs as IList<Song> ?? songs.ToList();
        var byPath = new Dictionary<string, Song>(StringComparer.Ordinal);
        foreach (var s in all) if (!string.IsNullOrEmpty(s.Path)) byPath[s.Path] = s;

        var released = new HashSet<string>(StringComparer.Ordinal);
        // By the name it came out under: its working titles often belong to other songs too, "Motions" among HeMotions's.
        foreach (var s in all.Where(s => s.Category == "released" && !IsUnofficial(s)))
            if (SongKey(s.Name) is { Length: > 0 } k) released.Add(k);

        // The API files an unofficial project under released, in the Compilations folder; its leak type tells the truth.
        // Such a file counts as unreleased, whichever page lists it.
        bool Unofficial(CatalogNode f) => byPath.TryGetValue(f.Path, out var s) && IsUnofficial(s);
        var wantsUnreleased = options.Sections.Contains("unreleased");
        string[] mixedPages = ["compilations", "remixes"];
        var listed = options.Sections.Where(id => !wantsUnreleased || !mixedPages.Contains(id))
            .SelectMany(id => catalog.Section(id).Rows).SelectMany(r => r.Files()).Where(f => !Unofficial(f));
        var files = listed.Where(f => Library.IsAudio(f.Name) && !NotASong().IsMatch(f.Name)).ToList();
        // A mixed page's Live folder holds lives, whatever their names say.
        var liveFolder = mixedPages.SelectMany(id => catalog.Section(id).Rows.Where(r => r.DisplayName == "Live"))
            .SelectMany(r => r.Files()).Select(f => f.Path).ToHashSet(StringComparer.Ordinal);
        // With Unreleased on, a mixed page that is also on gives only what is unreleased: no version of a song from the
        // official discography, no bare vocals or beats, nothing made by AI. A page that is off gives nothing.
        if (wantsUnreleased)
        {
            var official = all.Where(s => s.Path?.StartsWith("Compilation/1.", StringComparison.Ordinal) == true && !IsUnofficial(s))
                .Select(s => BareTitle(s.Name ?? "")).ToHashSet(StringComparer.Ordinal);
            var seen = files.Select(f => f.Path).ToHashSet(StringComparer.Ordinal);
            string[] notSongs = ["Acapella", "Instrumental"];
            files.AddRange(mixedPages.SelectMany(id => catalog.Section(id).Rows.Where(r => !notSongs.Contains(r.DisplayName))
                    .SelectMany(r => r.Files()).Select(f => (Page: id, File: f)))
                .Where(x => !seen.Contains(x.File.Path) && Library.IsAudio(x.File.Name) && !NotASong().IsMatch(x.File.Name))
                .Where(x => Unofficial(x.File) || (options.Sections.Contains(x.Page) && (Clip().IsMatch(x.File.Name) || liveFolder.Contains(x.File.Path) || !official.Contains(BareTitle(x.File.Name))) && !Regex.IsMatch(x.File.Name, @"\bAI\b", RegexOptions.IgnoreCase)))
                .Select(x => x.File));
        }

        // A live or a snippet by its name or folder; a bit of under 45 seconds whatever its folder says, though a session
        // cut of 47 seconds is still a song; and with no length to go by, under 500 KB is ten or twenty seconds at any bitrate.
        bool IsClip(CatalogNode f)
        {
            if (Clip().IsMatch(f.Name) || liveFolder.Contains(f.Path) || options.ClipPaths.Contains(f.Path)) return true;
            var seconds = Seconds(byPath.GetValueOrDefault(f.Path)?.Length);
            return seconds is > 0 and < 45 || (seconds == 0 && f.Size is > 0 and < TinyClipBytes);
        }
        var clips = files.Where(IsClip).Select(f => f.Path).ToHashSet(StringComparer.Ordinal);
        // With clips wanted, a clip the user once took out comes back with the rest of them.
        if (options.WithClips) files.RemoveAll(f => !clips.Contains(f.Path) && options.NeverOffer.Contains(f.Path));
        else files.RemoveAll(f => clips.Contains(f.Path) || options.NeverOffer.Contains(f.Path));

        var groups = new Dictionary<string, List<(CatalogNode File, Song? Song)>>(StringComparer.Ordinal);
        foreach (var file in files)
        {
            byPath.TryGetValue(file.Path, out var song);
            // With no tag to go by, the title alone says which song it is: "(Prod. X)", "(1)" and "(New Remaster)" are versions.
            var key = song is not null ? SongKey(song.Name ?? file.Name) : BareTitle(file.Name);
            // A session is its own recording, with its own words, never a take of the finished song; and every one is wanted.
            // So is every clip: each live is its own night.
            if (key.Length == 0 || LyricsIndex.IsSessionFile(file.Path) || clips.Contains(file.Path)) key = file.Path;
            if (!groups.TryGetValue(key, out var list)) groups[key] = list = [];
            list.Add((file, song));
        }
        MergeOtherTitles(groups);

        var kept = new List<SongGroup>();
        int skippedVersions = 0, skippedReleased = 0, skippedUnfinished = 0;
        foreach (var (_, list) in groups)
        {
            var versions = list.Select(v => Rate(v.File, v.Song)).OrderByDescending(v => v.Score).ThenBy(v => v.File.Name, StringComparer.Ordinal).ToList();
            var isClip = list.All(v => clips.Contains(v.File.Path));
            var group = new SongGroup(Title(list), versions)
            {
                IsClip = isClip,
                IsReleasedSong = !isClip && list.Any(v => !LyricsIndex.IsSessionFile(v.File.Path) && (released.Contains(SongKey(v.Song?.Name ?? v.File.Name)) || released.Contains(WithoutEraMark(SongKey(v.Song?.Name ?? v.File.Name), v.Song)))),
                IsUnfinished = versions.All(v => Unfinished().IsMatch(v.Song?.LeakType ?? "")),
            };
            if (options.SkipReleased && group.IsReleasedSong) { skippedReleased += versions.Count; continue; }
            if (options.SkipUnfinished && group.IsUnfinished) { skippedUnfinished += versions.Count; continue; }
            if (options.OneVersion)
            {
                skippedVersions += versions.Count - 1;
                kept.Add(group);
            }
            else
            {
                foreach (var v in versions) kept.Add(new SongGroup(v.File.Name, [v]) { IsClip = isClip });
            }
        }
        kept.Sort((a, b) => Catalog.NaturalCompare(a.Title, b.Title));
        return new RuleResult(kept, files.Count, skippedVersions, skippedReleased, skippedUnfinished);
    }

    /// <summary>The names a run would fetch, one per line and sorted, for the list on the Download button. Null when there is nothing.</summary>
    public static string? ListOf(IReadOnlyList<DownloadFile> files) =>
        files.Count == 0 ? null : string.Join("\n", files.Select(f => Path.GetFileNameWithoutExtension(f.ApiPath)).Order(StringComparer.CurrentCultureIgnoreCase));

    /// <summary>Where each picked file goes under the download folder: one folder, or the catalog's own.</summary>
    public static List<DownloadFile> Files(RuleResult result, RuleOptions options)
    {
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new List<DownloadFile>();
        foreach (var group in result.Kept)
        {
            var file = group.Picked.File;
            string? target = null;
            if (options.OneFolder)
            {
                var name = file.Name;
                for (var n = 2; !used.Add(name); n++)
                    name = $"{Path.GetFileNameWithoutExtension(file.Name)} {n}{Path.GetExtension(file.Name)}";
                target = (group.IsClip ? options.ClipsFolderName : options.FolderName) + "/" + name;
            }
            files.Add(new DownloadFile(file.Path, file.Size) { Target = target });
        }
        return files;
    }

    /// <summary>The name a song goes by across its takes: no credits, no version, no session marks, but "(Remix)" and "(Pt. 2)" stay: those are other songs.</summary>
    public static string SongKey(string name)
    {
        var text = Extension().Replace(name.Trim(), "");
        text = TakeBracket().Replace(text, " ");
        text = TrailingCredit().Replace(text, " ");
        return Fold(text);
    }

    private static IEnumerable<string> Titles(Song s) => s.TrackTitles is { } t ? t.Append(s.Name) : [s.Name];

    private static void MergeOtherTitles(Dictionary<string, List<(CatalogNode File, Song? Song)>> groups)
    {
        foreach (var key in groups.Keys.ToList())
        {
            if (!groups.TryGetValue(key, out var group)) continue;
            var others = group.Where(v => v.Song is not null).SelectMany(v => Titles(v.Song!)).Select(SongKey)
                .Where(k => k.Length > 0 && k != key).Distinct().ToList();
            foreach (var other in others)
            {
                if (!groups.TryGetValue(other, out var twin) || !SameWords(group, twin)) continue;
                group.AddRange(twin);
                groups.Remove(other);
            }
        }
    }

    private static bool SameWords(List<(CatalogNode File, Song? Song)> a, List<(CatalogNode File, Song? Song)> b)
    {
        var left = WordSet(a);
        var right = WordSet(b);
        if (left.Count == 0 || right.Count == 0) return false;
        var shared = left.Count(right.Contains);
        return shared >= 0.5 * Math.Min(left.Count, right.Count);
    }

    private static HashSet<string> WordSet(List<(CatalogNode File, Song? Song)> group)
    {
        var lines = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (_, song) in group)
            foreach (var line in (song?.Lyrics ?? "").Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
                if (Fold(line) is { Length: > 8 } folded) lines.Add(folded);
        return lines;
    }

    /// <summary>Finished before unfinished, with words before without, real sound before a low bitrate, the fuller take last.</summary>
    private static SongVersion Rate(CatalogNode file, Song? song)
    {
        var score = 0;
        var why = new List<string>();
        var leak = song?.LeakType ?? "";
        if (Complete().IsMatch(leak)) { score += 1000; why.Add("complete"); }
        if (Unfinished().IsMatch(leak)) { score -= 1000; why.Add("unfinished"); }
        else if (OpenVerse().IsMatch(leak)) { score -= 500; why.Add("open verse"); }
        if (Unexported().IsMatch(leak)) { score -= 200; why.Add("unexported"); }
        if (song is not null && LyricsIndex.HasWords(song)) { score += 100; why.Add("has words"); }

        var seconds = Seconds(song?.Length);
        if (seconds > 0)
        {
            var kbps = file.Size * 8 / 1000 / seconds;
            if (kbps >= 256) { score += 50; why.Add("320 kbps"); }
            else if (kbps < 160) score -= 50;
            score += Math.Min(seconds / 30, 15); // a longer take holds more of the song
        }
        score += Math.Min((song?.Lyrics?.Length ?? 0) / 500, 10);
        // A file the API describes beats one it knows nothing about.
        return new SongVersion(file, song, song is null ? score - 3000 : score, string.Join(", ", why));
    }

    private static int Seconds(string? length)
    {
        if (string.IsNullOrWhiteSpace(length)) return 0;
        var parts = length.Trim().Split(':');
        var total = 0;
        foreach (var part in parts)
        {
            if (!int.TryParse(part, out var n)) return 0;
            total = total * 60 + n;
        }
        return total;
    }

    private static string Title(List<(CatalogNode File, Song? Song)> group)
    {
        var name = group[0].Song?.Name ?? Path.GetFileNameWithoutExtension(group[0].File.Name);
        return Spaces().Replace(TakeOnly().Replace(name, " "), " ").Trim();
    }

    private static string Fold(string text)
    {
        var folded = new StringBuilder(text.Length);
        foreach (var c in text.Normalize(NormalizationForm.FormKC))
            if (char.IsLetterOrDigit(c)) folded.Append(char.ToLowerInvariant(c));
        return folded.ToString();
    }

    [GeneratedRegex(@"\.[A-Za-z0-9]{2,4}$")] private static partial Regex Extension();
    [GeneratedRegex(@"[\(\[\{]\s*(feat\.?|ft\.?|with\b|prod\.?|v\d+\b|session|sessions|demo|og\b)[^\)\]\}]*[\)\]\}]", RegexOptions.IgnoreCase)] private static partial Regex TakeBracket();
    [GeneratedRegex(@"[\(\[\{]\s*v\d+\s*[\)\]\}]", RegexOptions.IgnoreCase)] private static partial Regex TakeOnly();
    [GeneratedRegex(@"\b(feat|ft|prod)\b\.?.*$", RegexOptions.IgnoreCase)] private static partial Regex TrailingCredit();
    [GeneratedRegex(@"\s+")] private static partial Regex Spaces();
    [GeneratedRegex(@"instrumental|acapella|a cappella|\bstems?\b|\bbeat\b", RegexOptions.IgnoreCase)] private static partial Regex NotASong();
    [GeneratedRegex(@"\bsnip(pet|et|ept|pept)?\b|\b(ig|insta|instagram)\s+live\b|\(live\b|\blive performance\b", RegexOptions.IgnoreCase)] private static partial Regex Clip();
    [GeneratedRegex(@"\b(complete|completed)\b", RegexOptions.IgnoreCase)] private static partial Regex Complete();
    [GeneratedRegex(@"hook only|empty project|snippet", RegexOptions.IgnoreCase)] private static partial Regex Unfinished();
    [GeneratedRegex(@"open verse", RegexOptions.IgnoreCase)] private static partial Regex OpenVerse();
    [GeneratedRegex(@"unexported|unbounced", RegexOptions.IgnoreCase)] private static partial Regex Unexported();
}

/// <summary>
/// The catalog holds a few files twice under two names: "Break [Session Edit]" and "On And On (Break) [Session Edit]" are one
/// recording. Tags differ, so a file's size or hash says nothing; the audio itself is compared, a piece from its middle.
/// Only files that could be copies are asked about, so this costs a few dozen small requests, not thousands.
/// </summary>
public static class AudioCopies
{
    private const int Sample = 65536;

    /// <param name="same">Remembers answers between runs, by the two paths.</param>
    public static async Task<RuleResult> RemoveAsync(RuleResult result, LyricsIndex index, ApiClient api, Dictionary<string, bool> same, CancellationToken ct)
    {
        var picks = result.Kept.ToList();
        var pairs = new List<(SongGroup A, SongGroup B)>();
        foreach (var group in picks.GroupBy(g => index.Find(g.Picked.File.Path)?.Song.Id ?? -g.Picked.File.Size).Where(g => g.Count() > 1))
        {
            var list = group.ToList();
            for (var i = 0; i < list.Count; i++)
                for (var j = i + 1; j < list.Count; j++)
                    pairs.Add((list[i], list[j]));
        }
        foreach (var group in picks.GroupBy(g => g.Picked.File.Size).Where(g => g.Count() > 1))
        {
            var list = group.ToList();
            for (var i = 0; i < list.Count; i++)
                for (var j = i + 1; j < list.Count; j++)
                    if (!pairs.Contains((list[i], list[j])) && !pairs.Contains((list[j], list[i])))
                        pairs.Add((list[i], list[j]));
        }

        // Side by side: each answer is four small requests, and a first run has dozens of pairs to ask about.
        using var slots = new SemaphoreSlim(16);
        await Task.WhenAll(pairs.Select(async pair =>
        {
            var key = pair.A.Picked.File.Path + "\n" + pair.B.Picked.File.Path;
            lock (same) if (same.ContainsKey(key)) return;
            await slots.WaitAsync(ct);
            try
            {
                var alike = await SameAudioAsync(pair.A.Picked.File, pair.B.Picked.File, api, ct);
                lock (same) same[key] = alike;
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is HttpRequestException or TaskCanceledException or IOException)
            {
                // unknown: keeping a copy costs a few megabytes, losing a song costs the song
            }
            finally
            {
                slots.Release();
            }
        }));

        var gone = new HashSet<SongGroup>();
        foreach (var (a, b) in pairs)
        {
            if (gone.Contains(a) || gone.Contains(b)) continue;
            // The plainer name stays: "Break" over "On And On (Break)".
            if (same.GetValueOrDefault(a.Picked.File.Path + "\n" + b.Picked.File.Path))
                gone.Add(a.Picked.File.Name.Length <= b.Picked.File.Name.Length ? b : a);
        }
        return gone.Count == 0 ? result : result with { Kept = picks.Where(g => !gone.Contains(g)).ToList(), SkippedCopies = gone.Count };
    }

    private static async Task<bool> SameAudioAsync(CatalogNode a, CatalogNode b, ApiClient api, CancellationToken ct)
    {
        var tagA = TagSize(await api.GetBytesAsync(a.Path, 0, 9, ct));
        var tagB = TagSize(await api.GetBytesAsync(b.Path, 0, 9, ct));
        var audioA = a.Size - tagA;
        var audioB = b.Size - tagB;
        if (audioA != audioB || audioA <= 0) return false;
        var middle = Math.Max(0, audioA / 2 - Sample / 2);
        var length = Math.Min(Sample, audioA) - 1;
        var left = await api.GetBytesAsync(a.Path, tagA + middle, tagA + middle + length, ct);
        var right = await api.GetBytesAsync(b.Path, tagB + middle, tagB + middle + length, ct);
        return left.AsSpan().SequenceEqual(right);
    }

    private static long TagSize(byte[] h) =>
        h.Length >= 10 && h[0] == 'I' && h[1] == 'D' && h[2] == '3' ? 10L + ((h[6] << 21) | (h[7] << 14) | (h[8] << 7) | h[9]) + ((h[5] & 0x10) != 0 ? 10 : 0) : 0;
}

/// <summary>A file's other places in the catalog, for "Also in" on a row's menu: the same song, whatever tree it landed in.</summary>
public sealed class CatalogRelations
{
    private readonly Dictionary<string, List<CatalogNode>> _bySong = new(StringComparer.Ordinal);

    public CatalogRelations(Catalog catalog)
    {
        foreach (var file in catalog.Root.Files())
        {
            if (!Library.IsPlayable(file.Name) && !file.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) continue;
            var key = LyricsIndex.Key(file.Name, loose: true);
            if (key.Length == 0) continue;
            if (!_bySong.TryGetValue(key, out var list)) _bySong[key] = list = [];
            list.Add(file);
        }
    }

    public IReadOnlyList<CatalogNode> Of(CatalogNode file) =>
        _bySong.GetValueOrDefault(LyricsIndex.Key(file.Name, loose: true))?.Where(f => !ReferenceEquals(f, file)).ToList() ?? [];

    /// <summary>"Compilation/2. Unreleased Discography/7. Goodbye" reads as the way there, without the ordering numbers.</summary>
    public static string Place(CatalogNode file)
    {
        var names = new List<string>();
        for (var n = file.Parent; n is { Name.Length: > 0 }; n = n.Parent) names.Insert(0, n.DisplayName);
        return string.Join(" › ", names);
    }
}
