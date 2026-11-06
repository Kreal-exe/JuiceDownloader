using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using JuiceDownloader.Core;

namespace JuiceDownloader.Tests;

public class CatalogTests
{
    private static ApiItem F(string path, long size) => new(path, "file", size);

    private static Catalog Sample() => Catalog.Build([
        new ApiItem("Compilation", "directory", 0),
        F("Compilation/READ ME.txt", 5),
        F("Compilation/1. Released Discography/10. WRLD ON DRUGS/a.mp3", 10),
        F("Compilation/1. Released Discography/2. affliction/b.mp3", 20),
        F("Compilation/1. Released Discography/2. affliction/c.mp3", 30),
        F("Compilation/2. Unreleased Discography/1. JUTE (Sessions)/d.mp3", 40),
        F("Compilation/4. Cover Art/x.png", 1),
        F("Footage/clip.mp4", 100),
        F("Brand New Folder/e.mp3", 7),
    ]);

    [Fact]
    public void The_download_list_is_sorted()
    {
        DownloadFile[] some = [new("A/b song.mp3", 1), new("B/a song.wav", 1), new("C/c song.mp3", 1)];
        Assert.Equal("a song\nb song\nc song", SongRules.ListOf(some));
        Assert.Null(SongRules.ListOf([]));
    }

    [Fact]
    public void An_album_lands_under_its_own_name()
    {
        var c = Catalog.Build([
            F("Compilation/1. Released Discography/22. The Party Never Ends/Misfit.mp3", 4),
            F("Compilation/1. Released Discography/22. The Party Never Ends/CD2/Goodbye.mp3", 5),
        ]);
        var album = c.Root.Children[0].Children[0].Children[0];
        Assert.Equal(["The Party Never Ends/CD2/Goodbye.mp3", "The Party Never Ends/Misfit.mp3"], Library.AlbumFiles(album).Select(f => f.Target!).Order(StringComparer.Ordinal));
        Assert.DoesNotContain("snippets", Catalog.RuleSections);
        Assert.DoesNotContain(Catalog.FallbackSection, Catalog.RuleSections);
    }

    [Fact]
    public void Folders_add_up_and_numbers_sort_as_numbers()
    {
        var c = Sample();
        Assert.Equal(213, c.TotalBytes);
        Assert.Equal(8, c.TotalFiles);
        Assert.Equal(["10. WRLD ON DRUGS"], c.Section("albums").Rows.Select(r => r.Name));
        var unofficial = c.Section("unofficial");
        Assert.Equal("affliction", unofficial.Rows[0].DisplayName);
        Assert.Equal(50, unofficial.Rows[0].Size);
    }

    [Fact]
    public void Only_what_streaming_services_list_is_an_official_album()
    {
        const string r = "Compilation/1. Released Discography/";
        var c = Catalog.Build([
            F(r + "3. Heartbroken In Hollywood 9 9 9/FALL BACK.mp3", 1),
            F(r + "7. Goodbye & Good Riddance/Lucid Dreams.mp3", 1),
            F(r + "8. Too Soon/Rental.mp3", 1),
            F(r + "19. Goodbye & Good Riddance (5 Year Anniversary Edition)/Bonus.mp3", 1),
            F(r + "24. Singles & Features/3. SoundCloud - Singles & Features/Run.mp3", 1),
            F(r + "24. Singles & Features/4. Mainstream - Singles & Features/Godzilla.mp3", 1),
            F("Compilation/3. Misc. Discography/6. All Girls Are The Same 2 (Alternate Versions)/Sped Up.mp3", 1),
            F("Compilation/3. Misc. Discography/7. Vinyl Mixes/Oxy.mp3", 1),
        ]);
        Assert.Equal(["Goodbye & Good Riddance", "Too Soon", "Goodbye & Good Riddance (5 Year Anniversary Edition)", "Mainstream - Singles & Features", "All Girls Are The Same 2 (Alternate Versions)"], c.Section("albums").Rows.Select(n => n.DisplayName));
        Assert.Equal(["Vinyl Mixes"], c.Section("compilations").Rows.Select(n => n.DisplayName));
        Assert.Equal(["Heartbroken In Hollywood 9 9 9", "SoundCloud - Singles & Features"], c.Section("unofficial").Rows.Select(n => n.DisplayName));
        Assert.Equal(c.TotalFiles, c.Sections.Sum(s => s.FileCount));
    }

    [Fact]
    public void Nothing_the_API_offers_is_left_off_every_page()
    {
        var c = Sample();
        Assert.Equal(c.TotalFiles, c.Sections.Sum(s => s.FileCount));
        Assert.Contains(c.Section("media").Rows, r => r.Name == "Brand New Folder");
        Assert.Contains(c.Section("media").Rows, r => r.Name == "READ ME.txt");
    }

    [Fact]
    public void Selection_counts_up_to_the_root_and_never_twice()
    {
        var c = Sample();
        var row = c.Section("unofficial").Rows[0];
        Catalog.Select(row, true);
        Catalog.Select(row, true);
        Assert.Equal(50, c.SelectedBytes);
        Assert.Equal(2, c.SelectedFiles);
        Catalog.Select(row.Children[0], false);
        Assert.Equal(30, row.SelectedBytes);
        Assert.Equal(1, c.SelectedFiles);
        Assert.Equal(["Compilation/1. Released Discography/2. affliction/c.mp3"], c.SelectedFilesList().Select(f => f.Path));
        c.ClearSelection();
        Assert.Equal(0, c.SelectedFiles);
    }
}

public class LocalPathTests
{
    private static readonly string Dest = Path.Combine(Path.GetTempPath(), "dest");

    [Theory]
    [InlineData("../evil.mp3")]
    [InlineData("a/../../evil.mp3")]
    [InlineData("..\\evil.mp3")]
    [InlineData("")]
    [InlineData("///")]
    public void A_path_from_the_server_cannot_leave_the_folder(string path) => Assert.Null(LocalPath.Resolve(Dest, path));

    [Fact]
    public void A_rooted_path_stays_inside() => Assert.StartsWith(Path.GetFullPath(Dest), LocalPath.Resolve(Dest, "/etc/passwd"));

    [Theory]
    [InlineData("What? (feat. A/B).mp3", null)]
    [InlineData("a:b*c.mp3", "a_b_c.mp3")]
    [InlineData("trailing. ", "trailing")]
    [InlineData("CON.mp3", "_CON.mp3")]
    [InlineData("NOTHING'S DIFFERENT 3", "NOTHING'S DIFFERENT 3")]
    public void Names_are_legal_everywhere(string name, string? expected)
    {
        var clean = LocalPath.Clean(name);
        if (expected is not null) Assert.Equal(expected, clean);
        Assert.DoesNotContain(clean, c => "<>:\"\\|?*".Contains(c));
    }

    [Fact]
    public void A_long_name_keeps_its_extension()
    {
        var clean = LocalPath.Clean(new string('ж', 300) + ".mp3");
        Assert.EndsWith(".mp3", clean);
        Assert.True(Encoding.UTF8.GetByteCount(clean) <= 240);
    }
}

public class LyricsMatchTests
{
    private sealed record Case(string path, long? song, string? kind, string why, string? fit = null);
    private sealed record Fixture(List<Song> songs, List<Case> cases);

    private static Fixture Load() => JsonSerializer.Deserialize<Fixture>(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "lyrics-match.json")))!;

    [Fact]
    public void Every_case_of_the_shared_fixture()
    {
        var fixture = Load();
        var index = new LyricsIndex(fixture.songs);
        var wrong = new List<string>();
        foreach (var c in fixture.cases)
        {
            var match = index.Find(c.path);
            if (match?.Song.Id != c.song || (c.kind is not null && !c.kind.Split('|').Contains(match?.Kind.ToString())) || (c.fit is not null && match?.Fit.ToString() != c.fit))
                wrong.Add($"{c.path}: wanted {c.song} {c.kind}, got {match?.Song.Id} {match?.Kind} {match?.Fit} ({c.why})");
        }
        Assert.True(wrong.Count == 0, string.Join('\n', wrong));
    }

    [Fact]
    public void Timed_words_become_real_lrc()
    {
        Assert.Equal("[00:00.92]Ayy\n[10:07.04]Yeah\n", Lrc.Normalize("[0:00.92] Ayy\r\n[10:07.04] Yeah\nnot a line"));
        Assert.Null(Lrc.Normalize("just words"));
        Assert.Null(Lrc.Normalize(null));
    }
}

public class Id3Tests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("id3").FullName;
    private static readonly byte[] Audio = [0xFF, 0xFB, 0x90, 0x00, 1, 2, 3, 4];
    public void Dispose() => Directory.Delete(_dir, true);

    private string File_(byte[] bytes, string name = "t.mp3")
    {
        var p = Path.Combine(_dir, name);
        File.WriteAllBytes(p, bytes);
        return p;
    }

    private static byte[] Tag(byte version, byte[] frames, byte flags = 0, int padding = 0)
    {
        var n = frames.Length + padding;
        return [(byte)'I', (byte)'D', (byte)'3', version, 0, flags, (byte)(n >> 21 & 127), (byte)(n >> 14 & 127), (byte)(n >> 7 & 127), (byte)(n & 127), .. frames, .. new byte[padding]];
    }

    private static byte[] Frame(string id, byte[] body, byte version = 3)
    {
        var n = body.Length;
        byte[] size = version == 4
            ? [(byte)(n >> 21 & 127), (byte)(n >> 14 & 127), (byte)(n >> 7 & 127), (byte)(n & 127)]
            : [(byte)(n >> 24), (byte)(n >> 16), (byte)(n >> 8), (byte)n];
        return [.. Encoding.ASCII.GetBytes(id), .. size, 0, 0, .. body];
    }

    private static int IndexOf(byte[] data, byte[] part)
    {
        for (var i = 0; i + part.Length <= data.Length; i++)
            if (data.AsSpan(i, part.Length).SequenceEqual(part)) return i;
        return -1;
    }

    [Theory]
    [InlineData(3)]
    [InlineData(4)]
    public void Keeps_every_other_frame_and_the_audio(byte version)
    {
        var title = Frame("TIT2", [0, .. "Lucid Dreams"u8.ToArray()], version);
        var picture = Frame("APIC", Enumerable.Repeat((byte)0xFF, 2000).ToArray(), version);
        var file = File_([.. Tag(version, [.. title, .. picture], padding: 100), .. Audio]);

        Assert.False(Id3Lyrics.Has(file));
        Id3Lyrics.Write(file, "Я still see your shadows\n");
        Assert.True(Id3Lyrics.Has(file));

        var bytes = File.ReadAllBytes(file);
        Assert.Equal(version, bytes[3]);
        Assert.True(IndexOf(bytes, title) > 0);
        Assert.True(IndexOf(bytes, picture) > 0);
        Assert.Equal(Audio, bytes[^Audio.Length..]);
        var text = version == 4 ? Encoding.UTF8.GetBytes("Я still") : Encoding.Unicode.GetBytes("Я still");
        Assert.True(IndexOf(bytes, text) > 0);
    }

    [Fact]
    public void A_file_without_a_tag_gets_one()
    {
        var file = File_(Audio);
        Id3Lyrics.Write(file, "words");
        var bytes = File.ReadAllBytes(file);
        Assert.Equal((byte)'I', bytes[0]);
        Assert.Equal(Audio, bytes[^Audio.Length..]);
        Assert.True(Id3Lyrics.Has(file));
    }

    [Fact]
    public void Writing_twice_leaves_one_frame()
    {
        var file = File_(Audio);
        Id3Lyrics.Write(file, "one");
        Id3Lyrics.Write(file, "two");
        var bytes = File.ReadAllBytes(file);
        var first = IndexOf(bytes, "USLT"u8.ToArray());
        Assert.Equal(-1, IndexOf(bytes[(first + 4)..], "USLT"u8.ToArray()));
        Assert.True(IndexOf(bytes, Encoding.Unicode.GetBytes("two")) > 0);
        Assert.Equal(-1, IndexOf(bytes, Encoding.Unicode.GetBytes("one")));
        Assert.Equal(Audio, bytes[^Audio.Length..]);
    }

    [Fact]
    public void A_v2_3_tag_with_unsynchronisation_is_undone()
    {
        byte[] body = [0, 0xFF, 0x00, 0xE0, 65];
        byte[] raw = [(byte)'T', (byte)'I', (byte)'T', (byte)'2', 0, 0, 0, 4, 0, 0, .. body];
        var file = File_([.. Tag(3, raw, flags: 0x80), .. Audio]);
        Id3Lyrics.Write(file, "x");
        var bytes = File.ReadAllBytes(file);
        Assert.Equal(0, bytes[5]);
        Assert.True(IndexOf(bytes, [(byte)'T', (byte)'I', (byte)'T', (byte)'2', 0, 0, 0, 4, 0, 0, 0, 0xFF, 0xE0, 65]) > 0);
        Assert.Equal(Audio, bytes[^Audio.Length..]);
    }

    [Fact]
    public void An_old_tag_is_not_touched_and_the_words_go_beside_it()
    {
        byte[] original = [(byte)'I', (byte)'D', (byte)'3', 2, 0, 0, 0, 0, 0, 0, .. Audio];
        var file = File_(original);
        Assert.False(Id3Lyrics.CanTag(file));
        var song = new Song { Name = "x", Lyrics = "words", SyncedLyrics = "[0:01.00] words" };
        Assert.Equal(LyricsResult.Written, LyricsWriter.Apply(file, song, new LyricsOptions(true, false, false)));
        Assert.Equal(original, File.ReadAllBytes(file));
        Assert.Equal("[00:01.00]words\n", File.ReadAllText(Path.ChangeExtension(file, ".lrc")));
    }

    [Theory]
    [InlineData(new byte[] { 0, 0, 0, 24, (byte)'f', (byte)'t', (byte)'y', (byte)'p', 1, 2, 3, 4 })]
    [InlineData(new byte[] { (byte)'R', (byte)'I', (byte)'F', (byte)'F', 1, 2, 3, 4, 5, 6, 7, 8 })]
    [InlineData(new byte[] { 0x1A, 0x45, 0xDF, 0xA3, 1, 2, 3, 4, 5, 6, 7, 8 })]
    public void Another_format_named_mp3_is_not_tagged_even_behind_a_tag(byte[] content)
    {
        var file = File_(content);
        Assert.False(Id3Lyrics.CanTag(file));
        var song = new Song { Name = "x", Lyrics = "words", SyncedLyrics = "[0:01.00] words" };
        Assert.Equal(LyricsResult.Written, LyricsWriter.Apply(file, song, new LyricsOptions(true, false, false)));
        Assert.Equal(content, File.ReadAllBytes(file));
        Assert.True(File.Exists(Path.ChangeExtension(file, ".lrc")));

        var behindTag = File_([(byte)'I', (byte)'D', (byte)'3', 3, 0, 0, 0, 0, 0, 0, .. content]);
        Assert.False(Id3Lyrics.CanTag(behindTag));
    }

    [Fact]
    public void Existing_words_are_kept_and_the_tag_can_hold_timings()
    {
        var song = new Song { Name = "x", Lyrics = "plain", SyncedLyrics = "[0:01.00] timed" };
        var file = File_(Audio);
        Assert.Equal(LyricsResult.Written, LyricsWriter.Apply(file, song, new LyricsOptions(true, false, true)));
        Assert.True(IndexOf(File.ReadAllBytes(file), Encoding.Unicode.GetBytes("[00:01.00]timed")) > 0);
        Assert.False(File.Exists(Path.ChangeExtension(file, ".lrc")));
        Assert.Equal(LyricsResult.AlreadyThere, LyricsWriter.Apply(file, song, new LyricsOptions(true, false, false)));
    }

    [Fact]
    public void Plain_words_go_in_a_text_file_when_there_are_no_timings()
    {
        var file = File_([1, 2, 3], "a.wav");
        Assert.Equal(LyricsResult.Written, LyricsWriter.Apply(file, new Song { Name = "x", Lyrics = "a\r\nb" }, new LyricsOptions(true, false, false)));
        Assert.Equal("a\nb\n", File.ReadAllText(Path.Combine(_dir, "a.txt")));
    }
}

public class DownloadEngineTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("dl").FullName;
    public void Dispose() => Directory.Delete(_dir, true);

    private sealed class Server(Func<HttpRequestMessage, int, HttpResponseMessage> answer) : HttpMessageHandler
    {
        public List<HttpRequestMessage> Requests { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            lock (Requests)
            {
                Requests.Add(request);
                return Task.FromResult(answer(request, Requests.Count));
            }
        }
    }

    private static byte[] Bytes(int n) => Enumerable.Range(0, n).Select(i => (byte)i).ToArray();

    private static HttpResponseMessage Ok(byte[] b) => new(HttpStatusCode.OK) { Content = new ByteArrayContent(b) };

    private static HttpResponseMessage Range(byte[] all, long from)
    {
        var part = new ByteArrayContent(all[(int)from..]);
        part.Headers.ContentRange = new ContentRangeHeaderValue(from, all.Length - 1, all.Length);
        return new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = part };
    }

    private DownloadOptions Options(Func<string, string, CancellationToken, Task>? after = null) =>
        new() { Destination = _dir, RetryDelay = TimeSpan.FromMilliseconds(1), AfterFile = after };

    private static DownloadEngine Engine(Server s) => new(new HttpClient(s));

    [Fact]
    public async Task Fetches_into_folders_and_leaves_no_part_file()
    {
        var data = Bytes(1000);
        var server = new Server((_, _) => Ok(data));
        var report = await Engine(server).RunAsync([new DownloadFile("A & B/c d.mp3", 1000)], Options(), null, default);
        Assert.Equal(1, report.Downloaded);
        Assert.Equal(data, File.ReadAllBytes(Path.Combine(_dir, "A & B", "c d.mp3")));
        Assert.False(File.Exists(Path.Combine(_dir, "A & B", "c d.mp3.part")));
        Assert.Contains("path=A%20%26%20B%2Fc%20d.mp3", server.Requests[0].RequestUri!.Query);
    }

    [Fact]
    public async Task An_mp3_grown_by_its_lyrics_tag_is_not_fetched_again()
    {
        var path = Path.Combine(_dir, "x.mp3");
        File.WriteAllBytes(path, Bytes(1000));
        Id3Lyrics.Write(path, "words");
        Assert.NotEqual(1000, new FileInfo(path).Length);
        var server = new Server((_, _) => throw new InvalidOperationException());
        var report = await Engine(server).RunAsync([new DownloadFile("x.mp3", 1000)], Options(), null, default);
        Assert.Equal(1, report.AlreadyThere);
        Assert.Empty(server.Requests);
    }

    [Fact]
    public async Task An_mp3_of_another_size_without_lyrics_is_fetched_again()
    {
        var path = Path.Combine(_dir, "x.mp3");
        File.WriteAllBytes(path, Bytes(10));
        var data = Bytes(1000);
        var server = new Server((_, _) => Ok(data));
        var report = await Engine(server).RunAsync([new DownloadFile("x.mp3", 1000)], Options(), null, default);
        Assert.Equal(1, report.Downloaded);
        Assert.Equal(data, File.ReadAllBytes(path));
    }

    [Fact]
    public async Task A_file_already_there_is_not_fetched_again_but_still_gets_its_lyrics()
    {
        var path = Path.Combine(_dir, "x.mp3");
        File.WriteAllBytes(path, Bytes(10));
        var server = new Server((_, _) => throw new InvalidOperationException());
        var seen = new List<string>();
        var report = await Engine(server).RunAsync([new DownloadFile("x.mp3", 10)], Options((api, _, _) => { seen.Add(api); return Task.CompletedTask; }), null, default);
        Assert.Equal(1, report.AlreadyThere);
        Assert.Empty(server.Requests);
        Assert.Equal(["x.mp3"], seen);
    }

    [Fact]
    public async Task A_different_size_means_a_new_copy()
    {
        var path = Path.Combine(_dir, "x.mp3");
        File.WriteAllBytes(path, Bytes(5));
        var data = Bytes(10);
        var report = await Engine(new Server((_, _) => Ok(data))).RunAsync([new DownloadFile("x.mp3", 10)], Options(), null, default);
        Assert.Equal(1, report.Downloaded);
        Assert.Equal(data, File.ReadAllBytes(path));
    }

    [Fact]
    public async Task Resumes_a_part_file_by_range()
    {
        var all = Bytes(1000);
        File.WriteAllBytes(Path.Combine(_dir, "x.mp3.part"), all[..400]);
        var server = new Server((r, _) => Range(all, r.Headers.Range!.Ranges.First().From!.Value));
        await Engine(server).RunAsync([new DownloadFile("x.mp3", 1000)], Options(), null, default);
        Assert.Equal(400, server.Requests[0].Headers.Range!.Ranges.First().From);
        Assert.Equal(all, File.ReadAllBytes(Path.Combine(_dir, "x.mp3")));
    }

    [Fact]
    public async Task A_server_that_ignores_the_range_starts_the_file_over()
    {
        var all = Bytes(1000);
        File.WriteAllBytes(Path.Combine(_dir, "x.mp3.part"), new byte[400]);
        await Engine(new Server((_, _) => Ok(all))).RunAsync([new DownloadFile("x.mp3", 1000)], Options(), null, default);
        Assert.Equal(all, File.ReadAllBytes(Path.Combine(_dir, "x.mp3")));
    }

    [Fact]
    public async Task A_dropped_connection_is_resumed_and_a_short_file_never_takes_the_name()
    {
        var all = Bytes(1000);
        var server = new Server((r, n) =>
        {
            if (n == 1)
            {
                var cut = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new MemoryStream(all[..300])) };
                cut.Content.Headers.ContentLength = 1000;
                return cut;
            }
            return Range(all, r.Headers.Range!.Ranges.First().From!.Value);
        });
        var report = await Engine(server).RunAsync([new DownloadFile("x.mp3", 1000)], Options(), null, default);
        Assert.Empty(report.Failures);
        Assert.Equal(2, server.Requests.Count);
        Assert.Equal(all, File.ReadAllBytes(Path.Combine(_dir, "x.mp3")));
    }

    [Fact]
    public async Task Too_many_requests_waits_and_tries_again()
    {
        var all = Bytes(10);
        var server = new Server((_, n) => n < 3 ? new HttpResponseMessage((HttpStatusCode)429) : Ok(all));
        var report = await Engine(server).RunAsync([new DownloadFile("x.mp3", 10)], Options(), null, default);
        Assert.Equal(1, report.Downloaded);
        Assert.Equal(3, server.Requests.Count);
    }

    [Fact]
    public async Task A_missing_file_fails_once_and_the_rest_carry_on()
    {
        var all = Bytes(10);
        var server = new Server((r, _) => r.RequestUri!.Query.Contains("gone") ? new HttpResponseMessage(HttpStatusCode.NotFound) : Ok(all));
        var progress = new List<DownloadProgress>();
        var report = await Engine(server).RunAsync([new DownloadFile("gone.mp3", 10), new DownloadFile("here.mp3", 10)], Options(), new Progress<DownloadProgress>(progress.Add), default);
        Assert.Equal("gone.mp3", Assert.Single(report.Failures).ApiPath);
        Assert.Equal(1, report.Downloaded);
        Assert.Equal(2, server.Requests.Count);
        Assert.False(File.Exists(Path.Combine(_dir, "gone.mp3")));
    }

    [Fact]
    public async Task An_unsafe_path_fails_without_a_request()
    {
        var server = new Server((_, _) => throw new InvalidOperationException());
        var report = await Engine(server).RunAsync([new DownloadFile("../evil.mp3", 1)], Options(), null, default);
        Assert.Single(report.Failures);
        Assert.Empty(server.Requests);
    }

    [Fact]
    public async Task Stopping_keeps_the_part_file_and_reports_it()
    {
        using var stop = new CancellationTokenSource();
        var server = new Server((_, _) => { stop.Cancel(); return Ok(Bytes(10)); });
        var report = await Engine(server).RunAsync([new DownloadFile("a.mp3", 10), new DownloadFile("b.mp3", 10)], Options(), null, stop.Token);
        Assert.True(report.Stopped);
        Assert.Empty(report.Failures);
        Assert.False(File.Exists(Path.Combine(_dir, "b.mp3")));
    }
}

public class ApiClientTests
{
    private sealed class Pages(Func<string, string> answer) : HttpMessageHandler
    {
        public List<string> Urls { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            Urls.Add(r.RequestUri!.ToString());
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(answer(r.RequestUri!.ToString())) });
        }
    }

    [Fact]
    public async Task Songs_are_paged_over_https_whatever_next_says()
    {
        var pages = new Pages(u => u.Contains("page=1&")
            ? """{"count":2,"next":"http://juicewrldapi.com/juicewrld/songs/?page=2","results":[{"id":1,"name":"a"}]}"""
            : """{"count":2,"next":null,"results":[{"id":2,"name":"b","lyrics":"w","era":{"name":"OUT","description":"Outsiders"}}]}""");
        var client = new ApiClient(new HttpClient(pages)) { PageDelay = TimeSpan.Zero };
        var songs = await client.FetchSongsAsync(null, default);
        Assert.Equal(2, songs.Count);
        Assert.All(pages.Urls, u => Assert.StartsWith("https://", u));
    }

    [Fact]
    public async Task The_tree_waits_while_the_server_builds_it()
    {
        var n = 0;
        var pages = new Pages(_ => ++n == 1 ? """{"items":[],"building":true}""" : """{"items":[{"path":"a.mp3","type":"file","size":3}],"total":1}""");
        var items = await new ApiClient(new HttpClient(pages)) { BuildingDelay = TimeSpan.Zero }.FetchTreeAsync(default);
        Assert.Equal(3, Assert.Single(items).Size);
    }
}

public class LibraryRowsTests
{
    private static Catalog Sample() => Catalog.Build([
        new ApiItem("Others/Photos/a/one.jpg", "file", 1),
        new ApiItem("Others/Photos/b/two.jpg", "file", 1),
        new ApiItem("Compilation/1. Released Discography/5. Fighting Demons/Lucid.mp3", "file", 1),
        new ApiItem("Compilation/1. Released Discography/5. Fighting Demons/Other.mp3", "file", 1),
    ]);

    [Fact]
    public void Folders_open_in_place()
    {
        var rows = new LibraryRows(Sample().Section("albums"));
        Assert.Single(rows.Rows());
        rows.Toggle(rows.Rows()[0].Node);
        Assert.Equal(["5. Fighting Demons", "Lucid.mp3", "Other.mp3"], rows.Rows().Select(r => r.Node.Name));
        Assert.Equal(1, rows.Rows()[1].Depth);
        rows.Toggle(rows.Rows()[0].Node);
        Assert.Single(rows.Rows());
    }

    [Fact]
    public void A_search_reaches_any_depth()
    {
        var rows = new LibraryRows(Sample().Section("media")) { Query = "two" };
        Assert.Equal("two.jpg", Assert.Single(rows.Rows()).Node.Name);
    }
}

public class LibraryTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("lib").FullName;
    public void Dispose() => Directory.Delete(_dir, true);

    private sealed class Api : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            var url = r.RequestUri!.ToString();
            var json = url.Contains("list-all") ? """{"items":[{"path":"A/Song One.mp3","type":"file","size":4},{"path":"A/Other.mp3","type":"file","size":4}]}"""
                : url.Contains("/songs/") ? """{"count":1,"next":null,"results":[{"id":1,"name":"Song One","category":"unreleased","lyrics":"la la","synced_lyrics":"[0:01.00] la la"}]}"""
                : null;
            HttpContent content = json is null ? new ByteArrayContent([0xFF, 0xFB, 0x90, 0x00]) : new StringContent(json);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
        }
    }

    private Library Make(string cache)
    {
        var http = new HttpClient(new Api());
        return new Library(new ApiClient(http) { PageDelay = TimeSpan.Zero }, new DownloadEngine(http), new CatalogCache(cache));
    }

    [Fact]
    public void A_folder_with_no_files_is_not_in_the_catalog()
    {
        var catalog = Catalog.Build([
            new ApiItem("Studio Sessions/Empty", "directory", 0),
            new ApiItem("Studio Sessions/Full", "directory", 0),
            new ApiItem("Studio Sessions/Full/a.zip", "file", 4),
        ]);
        var studio = catalog.Sections.First(s => s.Id == "studio");
        Assert.Equal(["Full"], studio.Rows.Select(r => r.Name));
    }

    [Fact]
    public void The_search_of_the_overview_finds_files_in_every_section()
    {
        var catalog = Catalog.Build([
            new ApiItem("Studio Sessions/Full/Lucid take.zip", "file", 4),
            new ApiItem("Snippets/Lucid clip.mp3", "file", 2),
            new ApiItem("Snippets/Other.mp3", "file", 1),
        ]);
        var all = catalog.Everything();
        Assert.Equal(catalog.TotalFiles, all.FileCount);
        Assert.Equal(catalog.TotalBytes, all.Size);
        var rows = new LibraryRows(all) { Query = "lucid" }.Rows();
        Assert.Equal(["Lucid clip.mp3", "Lucid take.zip"], rows.Select(r => r.Node.Name).Order());
    }

    [Fact]
    public async Task Kept_lyrics_never_expire_and_only_a_new_song_count_means_an_update()
    {
        var cache = Path.Combine(_dir, "kept");
        var library = Make(cache);
        await library.EnsureLyricsAsync(null, false, default);
        Assert.False(await library.LyricsChangedOnServerAsync(default));

        File.SetLastWriteTimeUtc(Path.Combine(cache, "songs.json"), DateTime.UtcNow.AddYears(-1));
        var counting = new TwoSongs();
        var http = new HttpClient(counting);
        var later = new Library(new ApiClient(http) { PageDelay = TimeSpan.Zero }, new DownloadEngine(http), new CatalogCache(cache));
        await later.EnsureLyricsAsync(null, false, default);
        Assert.Equal(0, counting.Calls);
        Assert.True(await later.LyricsChangedOnServerAsync(default));
        Assert.Equal(1, counting.Calls);
    }

    private sealed class TwoSongs : HttpMessageHandler
    {
        public int Calls { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            Calls++;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"count":2,"next":null,"results":[]}""") });
        }
    }

    [Fact]
    public async Task Selected_files_arrive_with_their_lyrics_and_the_catalog_survives_a_restart()
    {
        var cache = Path.Combine(_dir, "cache");
        var dest = Path.Combine(_dir, "music");
        var library = Make(cache);
        Assert.False(library.LoadCached());
        await library.RefreshAsync(default);
        Catalog.Select(library.Catalog!.Root, true);

        var report = await library.DownloadSelectedAsync(dest, 2, new LyricsOptions(true, true, false), null, default);
        Assert.Equal(2, report.Downloaded);
        Assert.True(Id3Lyrics.Has(Path.Combine(dest, "A", "Song One.mp3")));
        Assert.Equal("[00:01.00]la la\n", File.ReadAllText(Path.Combine(dest, "A", "Song One.lrc")));
        Assert.False(Id3Lyrics.Has(Path.Combine(dest, "A", "Other.mp3")));

        var again = Make(cache);
        Assert.True(again.LoadCached());
        Assert.Equal(2, again.Catalog!.TotalFiles);
    }

    [Fact]
    public async Task A_folder_on_disk_gets_lyrics_and_says_what_it_could_not_place()
    {
        var music = Path.Combine(_dir, "mine");
        Directory.CreateDirectory(Path.Combine(music, "sub"));
        File.WriteAllBytes(Path.Combine(music, "sub", "song one (Session Edit).mp3"), [0xFF, 0xFB]);
        File.WriteAllBytes(Path.Combine(music, "nothing.mp3"), [0xFF, 0xFB]);
        File.WriteAllBytes(Path.Combine(music, "cover.jpg"), [1]);

        var report = await Make(Path.Combine(_dir, "c")).AddLyricsToFolderAsync(music, new LyricsOptions(true, false, false), null, default);
        Assert.Equal(1, report.Written);
        Assert.Equal(["nothing.mp3"], report.Missing);
        Assert.True(Id3Lyrics.Has(Path.Combine(music, "sub", "song one (Session Edit).mp3")));
    }

    [Fact]
    public async Task A_refresh_keeps_the_selection()
    {
        var library = Make(Path.Combine(_dir, "c2"));
        await library.RefreshAsync(default);
        Catalog.Select(library.Catalog!.Root.Files().First(), true);
        await library.RefreshAsync(default);
        Assert.Equal(1, library.Catalog!.SelectedFiles);
    }
}

public class DownloadEdgeTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("dle").FullName;
    public void Dispose() => Directory.Delete(_dir, true);

    private sealed class Answers(Func<int, HttpResponseMessage> answer) : HttpMessageHandler
    {
        private int _n;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct) => Task.FromResult(answer(++_n));
    }

    [Fact]
    public async Task A_range_from_the_wrong_offset_starts_the_file_over()
    {
        byte[] all = Enumerable.Range(0, 100).Select(i => (byte)i).ToArray();
        File.WriteAllBytes(Path.Combine(_dir, "x.mp3.part"), all[..40]);
        var server = new Answers(n =>
        {
            if (n > 1) return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(all) };
            var wrong = new ByteArrayContent(all[10..]);
            wrong.Headers.ContentRange = new ContentRangeHeaderValue(10, 99, 100);
            return new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = wrong };
        });
        var options = new DownloadOptions { Destination = _dir, RetryDelay = TimeSpan.Zero };
        await new DownloadEngine(new HttpClient(server)).RunAsync([new DownloadFile("x.mp3", 100)], options, null, default);
        Assert.Equal(all, File.ReadAllBytes(Path.Combine(_dir, "x.mp3")));
    }

    [Fact]
    public async Task The_failure_says_what_the_server_said()
    {
        var server = new Answers(_ => new HttpResponseMessage((HttpStatusCode)429));
        var options = new DownloadOptions { Destination = _dir, RetryDelay = TimeSpan.Zero, MaxAttempts = 2 };
        var report = await new DownloadEngine(new HttpClient(server)).RunAsync([new DownloadFile("x.mp3", 100)], options, null, default);
        Assert.Equal("HTTP 429", Assert.Single(report.Failures).Reason);
    }
}

public class WebLyricsTests
{
    private const string Words = "these are enough words to count as a real song\nand a second line of them";

    private sealed class Sites(Func<string, (int Status, string Body)> answer) : HttpMessageHandler
    {
        public List<string> Asked { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            var url = r.RequestUri!.ToString();
            lock (Asked) Asked.Add(url);
            var (status, body) = answer(url);
            return Task.FromResult(new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body) });
        }
    }

    private static string Lrclib(string artist, string title, string words = Words) =>
        JsonSerializer.Serialize(new[] { new { artistName = artist, trackName = title, plainLyrics = words, syncedLyrics = "", instrumental = false } });

    private static async Task<WebLyricsResult> Ask(string path, Func<string, (int, string)> answer) =>
        await new WebLyrics(new HttpClient(new Sites(answer))) { Paced = false }.FindAsync(path, default);

    private static (int, string) None(string url) => url.Contains("lrclib") ? (200, "[]") : url.Contains("genius.com/api") ? (200, """{"response":{"sections":[]}}""") : url.Contains("lyrics.ovh") ? (404, "") : (200, "{}");

    [Fact]
    public async Task Takes_a_song_of_his_with_that_name()
    {
        var r = await Ask("Compilation/2. Unreleased Discography/x/Lost Control.mp3", u => u.Contains("lrclib") ? (200, Lrclib("Juice WRLD", "Lost Control")) : None(u));
        Assert.Equal("LRCLIB", r.Match!.Source);
        Assert.Equal(LyricsFit.SameRecording, r.Match.Fit);
    }

    [Theory]
    [InlineData("Someone Else", "Lost Control")]
    [InlineData("Juice WRLD", "Lost Something")]
    [InlineData("Juice WRLD", "Lost Control (Remix)")]
    [InlineData("Juice WRLD", "Lost Control (Snippet)")]
    [InlineData("Juice WRLD", "Lost Control (Sessions)")]
    [InlineData("Genius Traductions", "Lost Control (Traduction)")]
    public async Task Refuses_anything_else_on_a_finished_song(string artist, string title)
    {
        var r = await Ask("Lost Control.mp3", u => u.Contains("lrclib") ? (200, Lrclib(artist, title)) : None(u));
        Assert.Null(r.Match);
    }

    [Fact]
    public async Task A_session_file_prefers_a_page_that_says_session()
    {
        var r = await Ask("Session Edits/x/Lost Control [Session Edit].mp3", u =>
            u.Contains("lrclib") ? (200, u.Contains("session") ? Lrclib("Juice WRLD", "Lost Control (Sessions)") : Lrclib("Juice WRLD", "Lost Control")) : None(u));
        Assert.Equal("Lost Control (Sessions)", r.Match!.Title);
        Assert.Equal(LyricsFit.SameRecording, r.Match.Fit);
    }

    [Fact]
    public async Task A_session_file_is_told_when_it_only_found_the_song()
    {
        var r = await Ask("Session Edits/x/Lost Control [Session Edit].mp3", u =>
            u.Contains("lrclib") ? (200, Lrclib("Juice WRLD", "Lost Control")) : None(u));
        Assert.Equal(LyricsFit.OtherRecording, r.Match!.Fit);
    }

    [Fact]
    public async Task A_named_take_refuses_another_take()
    {
        var r = await Ask("Lost Control (v2).mp3", u => u.Contains("lrclib") ? (200, Lrclib("Juice WRLD", "Lost Control (v3)")) : None(u));
        Assert.Null(r.Match);
    }

    [Fact]
    public async Task A_named_take_is_told_when_the_page_has_only_the_song()
    {
        var r = await Ask("Bad Boy (with Young Thug) [v5].mp3", u => u.Contains("lrclib") ? (200, Lrclib("Juice WRLD", "Bad Boy")) : None(u));
        Assert.Equal(LyricsFit.OtherRecording, r.Match!.Fit);
    }

    [Fact]
    public async Task A_source_that_answers_something_else_counts_as_failed()
    {
        var r = await Ask("Lost Control.mp3", u => u.Contains("genius.com/api") ? (200, """{"unexpected":true}""") : None(u));
        Assert.Contains(r.Failed, f => f.StartsWith("Genius"));
    }

    [Fact]
    public async Task Genius_refusing_this_client_is_said_and_not_asked_again()
    {
        var sites = new Sites(u => u.Contains("genius.com") ? (403, "") : None(u));
        var web = new WebLyrics(new HttpClient(sites)) { Paced = false };
        var first = await web.FindAsync("One.mp3", default);
        await web.FindAsync("Two.mp3", default);
        Assert.Contains(first.Failed, f => f.Contains("403"));
        Assert.Single(sites.Asked, u => u.Contains("genius.com/api"));
    }

    [Fact]
    public async Task Genius_pages_are_read_without_their_adverts()
    {
        const string page = """
            <div data-lyrics-container="true" class="a"><div data-exclude-from-selection="true">ADVERT<div>inner</div></div>First line<br/>Second &amp; line<div><a href="#">Third</a></div></div>
            <p>nope</p><div data-lyrics-container="true">Fourth</div>
            """;
        Assert.Equal("First line\nSecond & lineThird\n\nFourth".Replace("lineThird\n\n", "line\nThird\n"), WebLyrics.GeniusLyrics(page).Replace("lineThird", "line\nThird").Replace("Third\n\n", "Third\n"));
        var search = """{"response":{"sections":[{"hits":[{"type":"song","result":{"url":"https://genius.com/x-lyrics","title":"Lost Control","artist_names":"Juice WRLD"}}]}]}}""";
        var r = await Ask("Lost Control.mp3", u => u.Contains("genius.com/api") ? (200, search) : u.Contains("genius.com/x") ? (200, $"<div data-lyrics-container=\"true\">{Words}</div>") : None(u));
        Assert.Equal("Genius", r.Match!.Source);
    }

    [Fact]
    public async Task When_Genius_turns_requests_away_its_page_is_tried_by_address()
    {
        var r = await Ask("Don't Go.mp3", u => u.Contains("genius.com/api") ? (429, "") : u.EndsWith("genius.com/Juice-wrld-dont-go-lyrics") ? (200, $"<div data-lyrics-container=\"true\">{Words}</div>") : None(u));
        Assert.Equal("Genius", r.Match!.Source);
    }

    [Fact]
    public async Task A_source_that_fails_is_named_and_the_others_still_answer()
    {
        var r = await Ask("Lost Control.mp3", u => u.Contains("lrclib") ? (500, "") : u.Contains("genius.com/api") ? (200, """{"response":{"sections":[]}}""") : u.Contains("lyrics.ovh") ? (200, JsonSerializer.Serialize(new { lyrics = Words })) : (200, "{}"));
        Assert.Contains(r.Failed, f => f.StartsWith("LRCLIB"));
        Assert.Equal("lyrics.ovh", r.Match!.Source);
    }

    [Fact]
    public void Names_and_words_are_cleaned()
    {
        Assert.Equal("Light-Years", WebLyrics.Bare("Light-Years (ft. Young Thug) [Session Edit].mp3"));
        Assert.Equal("Too Smooth", WebLyrics.Bare("Too Smooth (v2).mp3"));
        Assert.Null(WebLyrics.Tidy("[Instrumental]"));
        Assert.Null(WebLyrics.Tidy("too short"));
        Assert.Equal(("hello there", "[00:01.00]hello there"), WebLyrics.NeteaseWords("[00:00.00] 作词 : Someone\n[00:01.00] hello there"));
        Assert.Equal(("", ""), WebLyrics.NeteaseWords("[00:00.00] 纯音乐，请欣赏"));
    }
}

public class SongRulesTests
{
    private const string U = "Compilation/2. Unreleased Discography/8. WRLD ON DRUGS (Sessions)/";

    private static Song S(string name, string leak, string lyrics = "", string length = "3:00", string category = "unreleased", params string[] titles) =>
        new() { Id = name.GetHashCode(), Name = name, Category = category, Path = category == "unreleased" ? U + name + ".mp3" : "Compilation/1. Released Discography/" + name + ".mp3", LeakType = leak, Lyrics = lyrics, Length = length, TrackTitles = [name, .. titles] };

    private static (Catalog, Song[]) Make(params Song[] songs)
    {
        var items = songs.Select(s => new ApiItem(s.Path, "file", 7_200_000)).ToList();
        return (Catalog.Build(items), songs);
    }

    [Fact]
    public void One_song_keeps_its_most_finished_take()
    {
        var (c, s) = Make(
            S("Bad Boy (with Young Thug) [v1]", "Original Demo Track (Open Verse)", "words"),
            S("Bad Boy (with Young Thug) [v2]", "Alternate Demo Track (Completed)", "words"),
            S("Bad Boy (with Young Thug) [v3]", "Alternate Demo Track"),
            S("Other Song", "Throwaway Track (Complete)", "words"));
        var r = SongRules.Apply(c, s, new RuleOptions());
        Assert.Equal(2, r.Kept.Count);
        Assert.Equal(2, r.SkippedVersions);
        Assert.Contains("[v2]", r.Kept.Single(g => g.Versions.Count == 3).Picked.File.Name);
    }

    [Fact]
    public void An_unofficial_release_goes_with_the_unreleased()
    {
        const string leaked = "Compilation/3. Misc. Discography/4. Whatever, They Leaked Already/For You.mp3";
        const string mix = "Compilation/3. Misc. Discography/3. Death Race For Love (Television Mixes)/Big (TV Mix).mp3";
        const string album = "Compilation/1. Released Discography/5. Fighting Demons/Big.mp3";
        const string edit = "Remixes & Edits/Tracks/New One (Prod. Someone).mp3";
        const string beat = "Remixes & Edits/Instrumental/Other Song.mp3";
        var c = Catalog.Build([new ApiItem(leaked, "file", 7200000), new ApiItem(mix, "file", 7200000), new ApiItem(album, "file", 7200000), new ApiItem(edit, "file", 7200000), new ApiItem(beat, "file", 7200000)]);
        Song[] s =
        [
            new() { Name = "For You", Path = leaked, Category = "released", LeakType = "Unofficial EP Track" },
            new() { Name = "Big (TV Mix)", Path = mix, Category = "released", LeakType = "Misc. Track" },
            new() { Name = "Big", Path = album, Category = "released", LeakType = "Album Track" },
        ];
        var unreleased = SongRules.Apply(c, s, new RuleOptions { Sections = ["unreleased", "sessionEdits", "remixes"], SkipReleased = true });
        Assert.Equal(["For You.mp3"], SongRules.Apply(c, s, new RuleOptions { Sections = ["unreleased", "sessionEdits"] }).Kept.Select(g => g.Picked.File.Name));
        Assert.Equal(["For You.mp3", "New One (Prod. Someone).mp3"], unreleased.Kept.Select(g => g.Picked.File.Name).Order());
        var released = SongRules.Apply(c, s, new RuleOptions { Sections = ["albums", "compilations"] });
        Assert.DoesNotContain("For You.mp3", released.Kept.Select(g => g.Picked.File.Name));
    }

    [Fact]
    public void A_remix_or_a_part_two_is_its_own_song()
    {
        var (c, s) = Make(S("Song", "Throwaway Track"), S("Song (Remix)", "Throwaway Track"), S("Song (Pt. 2)", "Throwaway Track"));
        Assert.Equal(3, SongRules.Apply(c, s, new RuleOptions { SkipReleased = false }).Kept.Count);
    }

    [Fact]
    public void An_ep_track_that_came_out_later_and_a_refused_file_are_not_offered()
    {
        var (c, s) = Make(S("AGATS 999", "Unofficial EP Track"), S("AGATS", "Single", category: "released"), S("Keep", "Throwaway Track"));
        var r = SongRules.Apply(c, s, new RuleOptions());
        Assert.DoesNotContain(r.Kept, g => g.Title == "AGATS 999");
        var keep = Assert.Single(r.Kept, g => g.Title == "Keep");
        var refused = SongRules.Apply(c, s, new RuleOptions { NeverOffer = [keep.Picked.File.Path] });
        Assert.DoesNotContain(refused.Kept, g => g.Title == "Keep");
    }

    [Fact]
    public void Songs_that_came_out_and_unfinished_ones_are_left_out_unless_wanted()
    {
        var (c, s) = Make(S("Lucid Dreams (v1)", "Original Demo Track"), S("Lucid Dreams", "Single", category: "released"), S("Hooky", "Throwaway Track (Hook Only)"), S("Keep", "Throwaway Track"));
        var r = SongRules.Apply(c, s, new RuleOptions { SkipReleased = true, SkipUnfinished = true });
        Assert.Equal("Keep", Assert.Single(r.Kept).Title);
        Assert.Equal(1, r.SkippedReleased);
        Assert.Equal(1, r.SkippedUnfinished);
        Assert.Equal(3, SongRules.Apply(c, s, new RuleOptions { SkipReleased = false }).Kept.Count);
    }

    [Fact]
    public void Another_title_is_the_same_song_only_when_the_words_agree()
    {
        const string words = "first long line of the song\nsecond long line of the song\nthird long line of the song";
        var (c, s) = Make(S("Late Night", "Throwaway Track", words, titles: "Wake Up"), S("Wake Up", "Throwaway Track", words), S("Lonely Road", "Throwaway Track", "some other verse entirely here", titles: "By Myself"), S("By Myself", "Throwaway Track", words));
        Assert.Equal(3, SongRules.Apply(c, s, new RuleOptions { SkipReleased = false }).Kept.Count);
    }

    [Fact]
    public void Every_session_edit_stays_beside_the_finished_song()
    {
        var items = new List<ApiItem> { new(U + "734.mp3", "file", 5), new("Session Edits/7. X (Sessions)/734 [Session Edit].mp3", "file", 5), new("Session Edits/7. X (Sessions)/734 (ft. A) [Session Edit].mp3", "file", 5) };
        var r = SongRules.Apply(Catalog.Build(items), [], new RuleOptions());
        Assert.Equal(3, r.Kept.Count);
    }

    [Fact]
    public void One_folder_keeps_names_apart()
    {
        var (c, s) = Make(S("A (v1)", "Throwaway Track"), S("B", "Throwaway Track"));
        var options = new RuleOptions { FolderName = "Picked" };
        var files = SongRules.Files(SongRules.Apply(c, s, options), options);
        Assert.All(files, f => Assert.StartsWith("Picked/", f.Target));
    }
}

public class AudioCopiesTests
{
    private static byte[] Tagged(int tag, byte[] audio) =>
        [(byte)'I', (byte)'D', (byte)'3', 3, 0, 0, 0, 0, (byte)(tag >> 7 & 127), (byte)(tag & 127), .. new byte[tag], .. audio];

    private sealed class Files(Dictionary<string, byte[]> files) : HttpMessageHandler
    {
        public int Requests;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            Requests++;
            var name = Uri.UnescapeDataString(r.RequestUri!.Query["?path=".Length..]);
            var range = r.Headers.Range!.Ranges.First();
            var part = files[name].Skip((int)range.From!.Value).Take((int)(range.To!.Value - range.From.Value + 1)).ToArray();
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(part) });
        }
    }

    [Fact]
    public async Task The_same_audio_under_other_tags_goes_and_the_plainer_name_stays()
    {
        var sound = Enumerable.Range(0, 200_000).Select(i => (byte)(i * 7)).ToArray();
        var other = sound.Select(b => (byte)(b ^ 1)).ToArray();
        var data = new Dictionary<string, byte[]>
        {
            ["Session Edits/x/Break [Session Edit].mp3"] = Tagged(100, sound),
            ["Session Edits/x/On And On (Break) [Session Edit].mp3"] = Tagged(300, sound),
            ["Session Edits/x/Different [Session Edit].mp3"] = Tagged(100, other),
        };
        var catalog = Catalog.Build(data.Select(d => new ApiItem(d.Key, "file", d.Value.Length)));
        var song = new Song { Id = 1, Name = "Break", Category = "recording_session", Lyrics = "words", TrackTitles = ["Break", "On And On", "Different"] };
        var server = new Files(data);
        var result = SongRules.Apply(catalog, [song], new RuleOptions());
        var cleaned = await AudioCopies.RemoveAsync(result, new LyricsIndex([song]), new ApiClient(new HttpClient(server)), [], default);
        Assert.Equal(1, cleaned.SkippedCopies);
        Assert.Equal(2, cleaned.Kept.Count);
        Assert.Contains(cleaned.Kept, g => g.Picked.File.Name.StartsWith("Break"));
        Assert.DoesNotContain(cleaned.Kept, g => g.Picked.File.Name.StartsWith("On And On"));
        Assert.True(server.Requests < 20);
    }
}

public class PlainNameTests
{
    [Theory]
    [InlineData("Juice WRLD - Calm Down Unreleased.mp3", "Calm Down.mp3")]
    [InlineData("Juice_Wrld_-_RNB_FREESTYLE.mp3", "RNB FREESTYLE.mp3")]
    [InlineData("Juice WRLD _ @juicewrld_rus - Quitter (Session Edit).mp3", "Quitter (Session Edit).mp3")]
    [InlineData("Juice - Me & Agony.m4a", "Me & Agony.m4a")]
    [InlineData("Juice WRLD - Game (Session Edit) — копия.mp3", "Game (Session Edit).mp3")]
    [InlineData("who_shot_cupid_with_stems.mp3", "who shot cupid.mp3")]
    [InlineData("emotional_overdose_extended.mp3", "emotional overdose.mp3")]
    [InlineData("Juice Never Have To Flex.mp3", "Juice Never Have To Flex.mp3")]
    [InlineData("Carbon Copy.mp3", "Carbon Copy.mp3")]
    [InlineData("Already Dead (Remaster) 2.mp3", "Already Dead (Remaster).mp3")]
    [InlineData("Song 2.mp3", "Song 2.mp3")]
    public void SetsAsideWhatUploadersAdd(string name, string plain) => Assert.Equal(plain, LyricsIndex.PlainName(name));
}

public class DiskStateTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
    private const long Mb = 1024 * 1024;

    public void Dispose() => Directory.Delete(_dir, true);

    private void Put(string name, long size)
    {
        var path = Path.Combine(_dir, "Unreleased", name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = File.Create(path);
        stream.SetLength(size);
    }

    [Fact]
    public void Finds_files_wherever_they_are_and_only_real_ones()
    {
        var item = (string path, long size) => new ApiItem(path, "file", size);
        var catalog = Catalog.Build([
            new ApiItem("Compilation", "directory", 0),
            item("Compilation/One.mp3", 8 * Mb), item("Compilation/Other/One.mp3", 8 * Mb), item("Compilation/Two.mp3", 8 * Mb),
            item("Compilation/Three.mp3", 30 * Mb), item("Compilation/Four.mp3", 8 * Mb), item("Compilation/Five.mp3", 8 * Mb), item("Compilation/Six.zip", 8 * Mb),
        ]);
        Put("one.MP3", 8 * Mb + 300000);
        Put("Two.m4a", 8 * Mb);
        Put("Three.mp3", 8 * Mb);
        Put("Four.mp3.part", 8 * Mb);
        Put("Five.lrc", 100);
        Put("Six.mp3", 8 * Mb);
        var state = DiskState.Scan(catalog, _dir);
        Assert.True(state.Has("Compilation/One.mp3"));
        Assert.True(state.Has("Compilation/Other/One.mp3"));
        Assert.True(state.Has("Compilation/Two.mp3"));
        Assert.False(state.Has("Compilation/Three.mp3"));
        Assert.False(state.Has("Compilation/Four.mp3"));
        Assert.False(state.Has("Compilation/Five.mp3"));
        Assert.False(state.Has("Compilation/Six.zip"));
        Assert.Equal(2, state.Files);
        Assert.Equal(16 * Mb + 300000, state.Bytes);
        Assert.EndsWith("Two.m4a", state.LocalPathOf("Compilation/Two.mp3"));
    }
}
