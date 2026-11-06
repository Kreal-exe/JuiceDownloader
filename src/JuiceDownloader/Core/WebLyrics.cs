using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace JuiceDownloader.Core;

public sealed record WebMatch(string Source, string Artist, string Title, string Lyrics, string? Synced, string? Url, LyricsFit Fit);

/// <summary>What the sites said about a file: the words, or the nearest thing refused and the sources that failed.</summary>
public sealed record WebLyricsResult(WebMatch? Match, string? Closest, IReadOnlyList<string> Failed);

/// <summary>
/// The second opinion after the API, ported from Music Organizer's finder: LRCLIB, NetEase and Genius in turn, then
/// lyrics.ovh, which cannot search and only answers about the very name it is given. Everything here is a Juice WRLD
/// song, so a candidate has to be credited to him and carry the name asked for. A title's brackets count: "Stuck (Snippet)"
/// is not "Stuck", and on a session file only a page that says "session" counts as the session's words.
/// </summary>
public sealed partial class WebLyrics(HttpClient http)
{
    private const string Artist = "Juice WRLD";
    private const double SameName = 0.85;

    private readonly Dictionary<string, (SemaphoreSlim Gate, long Next, long Gap)> _pace = new()
    {
        ["LRCLIB"] = (new SemaphoreSlim(1), 0, 250),
        ["NetEase"] = (new SemaphoreSlim(1), 0, 150),
        ["Genius"] = (new SemaphoreSlim(1), 0, 700),
        ["lyrics.ovh"] = (new SemaphoreSlim(1), 0, 400),
    };
    private long _geniusRestsUntil;

    /// <summary>For tests: no waiting between requests.</summary>
    public bool Paced { get; init; } = true;

    public async Task<WebLyricsResult> FindAsync(string path, CancellationToken ct)
    {
        path = path.Replace('\\', '/');
        var name = path[(path.LastIndexOf('/') + 1)..];
        var session = LyricsIndex.IsSessionFile(path);
        var bare = Bare(name);
        if (bare.Length == 0) return new WebLyricsResult(null, null, []);
        var guests = Guests(name);
        var version = VersionOf(name);

        var failed = new List<string>();
        string? closest = null;
        WebMatch? other = null;

        // A session goes by its own name first: a site that has it files it under "... (Sessions)".
        string[] searches = session ? [bare + " session", bare] : [bare];
        foreach (var search in searches)
        {
            foreach (var (source, ask) in Sources())
            {
                if (ct.IsCancellationRequested) ct.ThrowIfCancellationRequested();
                List<Candidate> found;
                try
                {
                    found = await ask(search, bare, guests, ct);
                }
                catch (Exception e) when (!ct.IsCancellationRequested && e is HttpRequestException or TaskCanceledException or IOException or JsonException or InvalidDataException or KeyNotFoundException or InvalidOperationException)
                {
                    var reason = $"{source}: {(e is TaskCanceledException ? "timed out" : e.Message)}";
                    if (!failed.Contains(reason)) failed.Add(reason);
                    continue;
                }

                foreach (var c in found)
                {
                    var verdict = Judge(c, bare, name, guests, version, session);
                    if (verdict == Verdict.Wrong)
                    {
                        closest ??= $"{c.Artist} - {c.Title} ({source})";
                        continue;
                    }
                    var words = Tidy(c.Lyrics);
                    if (words is null) continue;
                    var match = new WebMatch(source, c.Artist, c.Title, words, c.Synced, c.Url, verdict == Verdict.Same ? LyricsFit.SameRecording : LyricsFit.OtherRecording);
                    if (verdict == Verdict.Same) return new WebLyricsResult(match, null, failed);
                    other ??= match;
                }
            }
        }

        if (other is null && !session)
        {
            try
            {
                var ovh = await LyricsOvhAsync(bare, ct);
                if (ovh is not null) return new WebLyricsResult(new WebMatch("lyrics.ovh", Artist, bare, ovh, null, null, version is null ? LyricsFit.SameRecording : LyricsFit.OtherRecording), null, failed);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is HttpRequestException or TaskCanceledException or IOException or JsonException)
            {
                // It is down as often as not, and says nothing about whether the words exist.
            }
        }
        return new WebLyricsResult(other, other is null ? closest : null, failed);
    }

    private enum Verdict { Wrong, Same, Other }

    private sealed record Candidate(string Artist, string Title, string Lyrics, string? Synced, string? Url);

    private delegate Task<List<Candidate>> Ask(string search, string bare, IReadOnlyList<string> guests, CancellationToken ct);

    private IEnumerable<(string, Ask)> Sources()
    {
        yield return ("LRCLIB", LrclibAsync);
        yield return ("NetEase", NeteaseAsync);
        yield return ("Genius", GeniusAsync);
    }

    private static Verdict Judge(Candidate c, string bare, string fileName, IReadOnlyList<string> guests, int? version, bool session)
    {
        if (!CreditsHim(c.Artist, guests)) return Verdict.Wrong;
        if (Similarity(Fold(Bare(c.Title)), Fold(bare)) < SameName) return Verdict.Wrong;
        var take = VersionOf(c.Title);
        if (version is not null && take is not null && take != version) return Verdict.Wrong;

        var fileWords = Fold(fileName);
        var says = false;
        foreach (Match bracket in Bracket().Matches(c.Title))
        {
            if (CreditBracket().IsMatch(bracket.Value) || VersionWord().IsMatch(bracket.Value)) continue;
            if (SessionWord().IsMatch(bracket.Value)) { says = true; continue; }
            // "(Remix)", "(Snippet)", a translation: another recording unless the file says the same.
            if (!fileWords.Contains(Fold(bracket.Value), StringComparison.Ordinal)) return Verdict.Wrong;
        }
        if (SessionWord().IsMatch(c.Title)) says = true;
        if (says && !session) return Verdict.Wrong;
        if (session && !says) return Verdict.Other;
        // A page with no take on it has the song's words, which may not be the words of the take the file names.
        return version is not null && take is null ? Verdict.Other : Verdict.Same;
    }

    private static bool CreditsHim(string artist, IReadOnlyList<string> guests)
    {
        var folded = Fold(artist);
        if (folded.Contains("juicewrld") || folded.Contains("juiceworld") || folded.Contains("juicethekid") || folded.Contains("juicedakid")) return true;
        return guests.Any(g => { var f = Fold(g); return f.Length > 2 && folded.Contains(f); });
    }

    private async Task<List<Candidate>> LrclibAsync(string search, string bare, IReadOnlyList<string> guests, CancellationToken ct)
    {
        foreach (var query in new[]
                 {
                     $"artist_name={Uri.EscapeDataString(Artist)}&track_name={Uri.EscapeDataString(search)}",
                     $"q={Uri.EscapeDataString(Artist + " " + search)}",
                 })
        {
            using var doc = await JsonAsync("LRCLIB", "https://lrclib.net/api/search?" + query, ct, notFoundIsEmpty: true);
            if (doc is null) continue;
            var list = new List<Candidate>();
            foreach (var e in doc.RootElement.EnumerateArray())
            {
                if (e.TryGetProperty("instrumental", out var i) && i.ValueKind == JsonValueKind.True) continue;
                var plain = Str(e, "plainLyrics");
                if (plain.Length == 0) continue;
                list.Add(new Candidate(Str(e, "artistName"), Str(e, "trackName"), plain, Str(e, "syncedLyrics"), null));
            }
            if (list.Count > 0) return list;
        }
        return [];
    }

    private async Task<List<Candidate>> NeteaseAsync(string search, string bare, IReadOnlyList<string> guests, CancellationToken ct)
    {
        using var doc = await JsonAsync("NetEase", $"https://music.163.com/api/search/get?s={Uri.EscapeDataString(Artist + " " + search)}&type=1&limit=8", ct);
        var list = new List<Candidate>();
        if (doc is null || !doc.RootElement.TryGetProperty("result", out var result) || !result.TryGetProperty("songs", out var songs)) return list;
        var opened = 0;
        foreach (var song in songs.EnumerateArray())
        {
            var title = Str(song, "name");
            var artists = song.TryGetProperty("artists", out var a) ? string.Join(" & ", a.EnumerateArray().Select(x => Str(x, "name"))) : "";
            if (!CreditsHim(artists, guests) || Similarity(Fold(Bare(title)), Fold(bare)) < SameName) continue;
            if (++opened > 2) break;
            using var words = await JsonAsync("NetEase", $"https://music.163.com/api/song/lyric?id={song.GetProperty("id").GetInt64()}&lv=1&kv=1&tv=-1", ct);
            if (words is null || !words.RootElement.TryGetProperty("lrc", out var lrc)) continue;
            var (plain, timed) = NeteaseWords(Str(lrc, "lyric"));
            if (plain.Length > 0) list.Add(new Candidate(artists, title, plain, timed, $"https://music.163.com/#/song?id={song.GetProperty("id").GetInt64()}"));
        }
        return list;
    }

    private async Task<List<Candidate>> GeniusAsync(string search, string bare, IReadOnlyList<string> guests, CancellationToken ct)
    {
        if (Environment.TickCount64 < Interlocked.Read(ref _geniusRestsUntil))
            return await GeniusByAddressAsync(bare, ct) ?? throw new InvalidDataException("turning requests away");

        JsonDocument? doc;
        try
        {
            doc = await JsonAsync("Genius", $"https://genius.com/api/search/multi?q={Uri.EscapeDataString(Artist + " " + search)}", ct);
        }
        catch (HttpRequestException e) when (e.StatusCode == HttpStatusCode.Forbidden)
        {
            // It does not want this client: asking again for every track would only be rude.
            Interlocked.Exchange(ref _geniusRestsUntil, Environment.TickCount64 + 600_000);
            throw;
        }
        catch (HttpRequestException e) when (e.StatusCode == HttpStatusCode.TooManyRequests)
        {
            // Every further request only keeps the ban going, but the song pages are still served, at addresses made from the names.
            Interlocked.Exchange(ref _geniusRestsUntil, Environment.TickCount64 + 180_000);
            if (await GeniusByAddressAsync(bare, ct) is { } byAddress) return byAddress;
            throw;
        }

        using (doc)
        {
            var list = new List<Candidate>();
            if (doc is null) return list;
            var seen = new HashSet<string>();
            foreach (var section in doc.RootElement.GetProperty("response").GetProperty("sections").EnumerateArray())
            {
                foreach (var hit in section.GetProperty("hits").EnumerateArray())
                {
                    if (Str(hit, "type") != "song") continue;
                    var r = hit.GetProperty("result");
                    var url = Str(r, "url");
                    var title = Str(r, "title");
                    var artist = Str(r, "artist_names");
                    if (url.Length == 0 || !seen.Add(url)) continue;
                    if (!CreditsHim(artist, guests) || Similarity(Fold(Bare(title)), Fold(bare)) < SameName) continue;
                    var words = await GeniusPageAsync(url, ct);
                    if (words.Length > 0) list.Add(new Candidate(artist, title, words, null, url));
                    if (list.Count >= 3) return list;
                }
            }
            return list;
        }
    }

    private async Task<List<Candidate>?> GeniusByAddressAsync(string bare, CancellationToken ct)
    {
        var slug = Slug(Artist + " " + bare);
        if (slug.Length == 0) return null;
        var url = $"https://genius.com/{slug}-lyrics";
        try
        {
            var words = await GeniusPageAsync(url, ct);
            return words.Length > 0 ? [new Candidate(Artist, bare, words, null, url)] : null;
        }
        catch (HttpRequestException)
        {
            return null;
        }
    }

    private async Task<string> GeniusPageAsync(string url, CancellationToken ct)
    {
        await PaceAsync("Genius", ct);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var response = await http.GetAsync(url, timeout.Token);
        if (response.StatusCode == HttpStatusCode.NotFound) return "";
        if (!response.IsSuccessStatusCode) throw new HttpRequestException($"replied {(int)response.StatusCode}", null, response.StatusCode);
        return GeniusLyrics(await response.Content.ReadAsStringAsync(timeout.Token));
    }

    private async Task<string?> LyricsOvhAsync(string bare, CancellationToken ct)
    {
        using var doc = await JsonAsync("lyrics.ovh", $"https://api.lyrics.ovh/v1/{Uri.EscapeDataString(Artist)}/{Uri.EscapeDataString(bare)}", ct, notFoundIsEmpty: true);
        return doc is null ? null : Tidy(Str(doc.RootElement, "lyrics"));
    }

    private async Task<JsonDocument?> JsonAsync(string source, string url, CancellationToken ct, bool notFoundIsEmpty = false)
    {
        await PaceAsync(source, ct);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Accept.ParseAdd("application/json");
        using var response = await http.SendAsync(request, timeout.Token);
        if (notFoundIsEmpty && response.StatusCode == HttpStatusCode.NotFound) return null;
        if (!response.IsSuccessStatusCode) throw new HttpRequestException($"replied {(int)response.StatusCode}", null, response.StatusCode);
        return JsonDocument.Parse(await response.Content.ReadAsStringAsync(timeout.Token));
    }

    private async Task PaceAsync(string source, CancellationToken ct)
    {
        if (!Paced) return;
        var pace = _pace[source];
        await pace.Gate.WaitAsync(ct);
        try
        {
            var now = Environment.TickCount64;
            var wait = _pace[source].Next - now;
            if (wait > 0) await Task.Delay((int)wait, ct);
            _pace[source] = (pace.Gate, Environment.TickCount64 + pace.Gap, pace.Gap);
        }
        finally
        {
            pace.Gate.Release();
        }
    }

    private static string Str(JsonElement e, string key) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    /// <summary>The song's name with everything that is not its name taken off.</summary>
    public static string Bare(string name)
    {
        var text = Extension().Replace(name.Trim(), "");
        text = Bracket().Replace(text, " ");
        text = TrailingCredit().Replace(text, " ");
        text = SessionWord().Replace(text, " ");
        text = VersionWord().Replace(text, " ");
        return Spaces().Replace(text, " ").Trim(' ', '-', '_');
    }

    private static IReadOnlyList<string> Guests(string name)
    {
        var guests = new List<string>();
        foreach (Match m in GuestCredit().Matches(name))
            guests.AddRange(GuestSplit().Split(m.Groups[1].Value).Select(g => g.Trim()).Where(g => g.Length > 0));
        return guests;
    }

    private static int? VersionOf(string name)
    {
        var m = VersionWord().Match(name);
        return m.Success && int.TryParse(m.Groups[1].Value, out var v) ? v : null;
    }

    private static string Fold(string text)
    {
        var folded = new StringBuilder(text.Length);
        foreach (var c in text.Normalize(NormalizationForm.FormKC))
            if (char.IsLetterOrDigit(c)) folded.Append(char.ToLowerInvariant(c));
        return folded.ToString();
    }

    /// <summary>1 for the same text, 0 for nothing in common: edit distance over the longer length.</summary>
    public static double Similarity(string a, string b)
    {
        if (a.Length == 0 || b.Length == 0) return 0;
        if (a == b) return 1;
        var row = Enumerable.Range(0, b.Length + 1).ToArray();
        for (var i = 1; i <= a.Length; i++)
        {
            var diagonal = row[0];
            row[0] = i;
            for (var j = 1; j <= b.Length; j++)
            {
                var up = row[j];
                row[j] = Math.Min(Math.Min(row[j] + 1, row[j - 1] + 1), diagonal + (a[i - 1] == b[j - 1] ? 0 : 1));
                diagonal = up;
            }
        }
        return 1 - (double)row[b.Length] / Math.Max(a.Length, b.Length);
    }

    /// <summary>Tidied words, or null for an "[Instrumental]" or a stub.</summary>
    public static string? Tidy(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').Select(l => l.TrimEnd(' ', '\t'));
        var tidy = BlankRun().Replace(string.Join('\n', lines), "\n\n").Trim();
        if (tidy.Length < 25 || tidy.Trim('[', ']', '(', ')').Equals("instrumental", StringComparison.OrdinalIgnoreCase)) return null;
        return tidy;
    }

    /// <summary>The text of a Genius song page: one container per section, each a small tree, with adverts marked inside.</summary>
    public static string GeniusLyrics(string page)
    {
        var parts = new List<string>();
        for (var offset = 0; offset < page.Length;)
        {
            var open = Container().Match(page, offset);
            if (!open.Success) break;
            var start = open.Index + open.Length;
            var end = DivEnd(page, start);
            var text = HtmlText(DropExcluded(page[start..end]));
            if (text.Length > 0) parts.Add(text);
            offset = Math.Max(end, start);
            if (end >= page.Length) break;
        }
        return string.Join('\n', parts);
    }

    private static string DropExcluded(string fragment)
    {
        while (true)
        {
            var m = Excluded().Match(fragment);
            if (!m.Success) return fragment;
            var end = DivEnd(fragment, m.Index + m.Length);
            if (end < fragment.Length) end += "</div>".Length;
            fragment = fragment[..m.Index] + fragment[end..];
        }
    }

    private static int DivEnd(string page, int start)
    {
        var depth = 1;
        foreach (Match tag in DivTag().Matches(page, start))
        {
            depth += tag.Groups[1].Length > 0 ? -1 : 1;
            if (depth == 0) return tag.Index;
        }
        return page.Length;
    }

    private static string HtmlText(string fragment)
    {
        var text = LineBreak().Replace(fragment, "\n");
        text = BlockEnd().Replace(text, "\n");
        text = AnyTag().Replace(text, "");
        return WebUtility.HtmlDecode(text).Trim();
    }

    public static (string Plain, string Timed) NeteaseWords(string lrc)
    {
        if (lrc.Contains("纯音乐", StringComparison.Ordinal)) return ("", "");
        var timed = new List<string>();
        var words = new List<string>();
        foreach (var line in lrc.Replace("\r", "").Split('\n'))
        {
            var m = LrcLine().Match(line);
            if (!m.Success) continue;
            var text = m.Groups[2].Value.Trim();
            if (LrcCredit().IsMatch(text)) continue;
            timed.Add(m.Groups[1].Value + text);
            words.Add(text);
        }
        var plain = string.Join('\n', words).Trim();
        return plain.Length == 0 ? ("", "") : (plain, string.Join('\n', timed));
    }

    public static string Slug(string names)
    {
        if (names.Any(c => c > 127 && char.IsLetter(c))) return "";
        var text = names.ToLowerInvariant().Replace("&", " and ").Replace("'", "").Replace("’", "");
        text = SlugBreak().Replace(text, "-").Trim('-');
        return text.Length == 0 ? "" : char.ToUpperInvariant(text[0]) + text[1..];
    }

    [GeneratedRegex(@"\.[A-Za-z0-9]{2,4}$")] private static partial Regex Extension();
    [GeneratedRegex(@"[\(\[\{][^\)\]\}]*[\)\]\}]")] private static partial Regex Bracket();
    [GeneratedRegex(@"[\(\[\{]\s*(feat\.?|ft\.?|with |prod\.?|best|master|remaster|rough|og\b|explicit|clean)", RegexOptions.IgnoreCase)] private static partial Regex CreditBracket();
    [GeneratedRegex(@"\b(feat|ft|prod)\b\.?.*$", RegexOptions.IgnoreCase)] private static partial Regex TrailingCredit();
    [GeneratedRegex(@"\b(studio\s+)?sessions?(\s+edit)?\b", RegexOptions.IgnoreCase)] private static partial Regex SessionWord();
    [GeneratedRegex(@"\bv(\d+)\b(?!\.\d)", RegexOptions.IgnoreCase)] private static partial Regex VersionWord();
    [GeneratedRegex(@"\s+")] private static partial Regex Spaces();
    [GeneratedRegex(@"[\(\[\{]\s*(?:feat\.?|ft\.?|with)\s+([^\)\]\}]*)[\)\]\}]", RegexOptions.IgnoreCase)] private static partial Regex GuestCredit();
    [GeneratedRegex(@"\s*(?:,|&|\band\b)\s*", RegexOptions.IgnoreCase)] private static partial Regex GuestSplit();
    [GeneratedRegex(@"\n{3,}")] private static partial Regex BlankRun();
    [GeneratedRegex(@"<div[^>]*\bdata-lyrics-container=""true""[^>]*>", RegexOptions.IgnoreCase)] private static partial Regex Container();
    [GeneratedRegex(@"<div[^>]*\bdata-exclude-from-selection=""true""[^>]*>", RegexOptions.IgnoreCase)] private static partial Regex Excluded();
    [GeneratedRegex(@"<(/?)div\b", RegexOptions.IgnoreCase)] private static partial Regex DivTag();
    [GeneratedRegex(@"<br\s*/?>", RegexOptions.IgnoreCase)] private static partial Regex LineBreak();
    [GeneratedRegex(@"</(?:div|p)>", RegexOptions.IgnoreCase)] private static partial Regex BlockEnd();
    [GeneratedRegex(@"<[^>]*>")] private static partial Regex AnyTag();
    [GeneratedRegex(@"^\s*((?:\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\])+)\s*(.*)$")] private static partial Regex LrcLine();
    [GeneratedRegex(@"^(?:作词|作曲|编曲|制作人?|混音|母带|录音|和声|监制|出品|发行|企划|统筹|吉他|贝斯|鼓|键盘|弦乐|词|曲|lyricist|lyrics by|composer|composed by|arranger|producer|produced by|mix(?:ed|ing)?(?: by)?|master(?:ed|ing)?(?: by)?|recording)\s*[:：]", RegexOptions.IgnoreCase)] private static partial Regex LrcCredit();
    [GeneratedRegex(@"[^a-z0-9]+")] private static partial Regex SlugBreak();
}
