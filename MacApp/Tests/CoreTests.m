// Core tests for the macOS app, the counterpart of tests/JuiceDownloader.Core.Tests: byte formatting, catalog and
// selection, local paths, every case of tests/fixtures/lyrics-match.json, LRC, ID3, the API client, the download engine
// against a local stub (an NSURLProtocol), the library, settings and localization. Run by ./build.sh --test.
#import <Foundation/Foundation.h>
#import "CCCatalog.h"
#import "CCCore.h"
#import "CCDownload.h"
#import "CCLibrary.h"
#import "CCLyrics.h"
#import "CCSettings.h"
#import "CCWebLyrics.h"

static int gFailed = 0, gPassed = 0;

#define CHECK(cond, ...)                                                                   \
    do {                                                                                   \
        if (cond) gPassed++;                                                               \
        else {                                                                             \
            gFailed++;                                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); \
        }                                                                                  \
    } while (0)

#define EQUAL(a, b)                                                                        \
    do {                                                                                   \
        id _a = (a), _b = (b);                                                             \
        CHECK((_a == nil && _b == nil) || [_a isEqual:_b], @"%@ != %@", _a, _b);           \
    } while (0)

static NSFileManager *FM(void) { return NSFileManager.defaultManager; }

static NSString *Scratch(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [FM() createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *Join(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }
static BOOL Exists(NSString *path) { return [FM() fileExistsAtPath:path]; }
static NSData *Bytes(NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithLength:n];
    uint8_t *p = d.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) p[i] = (uint8_t)i;
    return d;
}
static NSString *TextOf(NSString *path) { return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]; }

// ───────────── formatting ─────────────

static void TestFormatting(void) {
    CCSetFormatLocale([NSLocale localeWithLocaleIdentifier:@"en_US"]);
    EQUAL(CCFormatBytes(0), @"0 B");
    EQUAL(CCFormatBytes(1023), @"1023 B");
    EQUAL(CCFormatBytes(1024), @"1.00 KB");
    EQUAL(CCFormatBytes(10.5 * 1024 * 1024), @"10.5 MB");
    EQUAL(CCFormatBytes(150.0 * 1024 * 1024 * 1024), @"150 GB");
    EQUAL(CCFormatBytes(-5), @"0 B");
    EQUAL(CCFormatCount(133697), @"133,697");
    CCSetFormatLocale([NSLocale localeWithLocaleIdentifier:@"ru"]);
    EQUAL(CCFormatBytes(1536), @"1,50 KB");
    EQUAL(CCFormatDecimal(0.4), @"0,4");
    CCSetFormatLocale([NSLocale localeWithLocaleIdentifier:@"en_US"]);
}

// ───────────── catalog ─────────────

static CCApiItem *F(NSString *path, long long size) { return [CCApiItem path:path type:@"file" size:size]; }

static CCCatalog *Sample(void) {
    return [CCCatalog build:@[
        [CCApiItem path:@"Compilation" type:@"directory" size:0],
        F(@"Compilation/READ ME.txt", 5),
        F(@"Compilation/1. Released Discography/10. WRLD ON DRUGS/a.mp3", 10),
        F(@"Compilation/1. Released Discography/2. affliction/b.mp3", 20),
        F(@"Compilation/1. Released Discography/2. affliction/c.mp3", 30),
        F(@"Compilation/2. Unreleased Discography/1. JUTE (Sessions)/d.mp3", 40),
        F(@"Compilation/4. Cover Art/x.png", 1),
        F(@"Footage/clip.mp4", 100),
        F(@"Brand New Folder/e.mp3", 7),
    ]];
}

static void TestCatalog(void) {
    CCCatalog *c = Sample();
    CHECK(c.totalBytes == 213, @"total %lld", c.totalBytes);
    CHECK(c.totalFiles == 8, @"files %d", c.totalFiles);
    EQUAL([[c section:@"albums"].rows valueForKey:@"name"], (@[ @"10. WRLD ON DRUGS" ]));
    CCCatalogSection *unofficial = [c section:@"unofficial"];
    EQUAL(unofficial.rows[0].displayName, @"affliction");
    CHECK(unofficial.rows[0].size == 50, @"folder size");
    NSString *r = @"Compilation/1. Released Discography/";
    CCCatalog *sorted = [CCCatalog build:@[
        F([r stringByAppendingString:@"3. Heartbroken In Hollywood 9 9 9/FALL BACK.mp3"], 1),
        F([r stringByAppendingString:@"7. Goodbye & Good Riddance/Lucid Dreams.mp3"], 1),
        F([r stringByAppendingString:@"8. Too Soon/Rental.mp3"], 1),
        F([r stringByAppendingString:@"24. Singles & Features/3. SoundCloud - Singles & Features/Run.mp3"], 1),
        F([r stringByAppendingString:@"24. Singles & Features/4. Mainstream - Singles & Features/Godzilla.mp3"], 1),
        F(@"Compilation/3. Misc. Discography/6. All Girls Are The Same 2 (Alternate Versions)/Sped Up.mp3", 1),
        F(@"Compilation/3. Misc. Discography/7. Vinyl Mixes/Oxy.mp3", 1),
    ]];
    EQUAL([[sorted section:@"albums"].rows valueForKey:@"displayName"], (@[ @"Goodbye & Good Riddance", @"Too Soon", @"Mainstream - Singles & Features", @"All Girls Are The Same 2 (Alternate Versions)" ]));
    EQUAL([[sorted section:@"compilations"].rows valueForKey:@"displayName"], (@[ @"Vinyl Mixes" ]));
    EQUAL([[sorted section:@"unofficial"].rows valueForKey:@"displayName"], (@[ @"Heartbroken In Hollywood 9 9 9", @"SoundCloud - Singles & Features" ]));

    // Nothing the API offers is left off every page.
    int sum = 0;
    for (CCCatalogSection *s in c.sections) sum += s.fileCount;
    CHECK(sum == c.totalFiles, @"sections hold %d of %d", sum, c.totalFiles);
    CHECK(c.sections.count == 11, @"sections");
    NSArray *media = [[c section:@"media"].rows valueForKey:@"name"];
    CHECK([media containsObject:@"Brand New Folder"], @"new folder not on media");
    CHECK([media containsObject:@"READ ME.txt"], @"loose file not on media");

    // Selection counts up to the root and never twice.
    CCCatalogNode *row = unofficial.rows[0];
    [CCCatalog select:row selected:YES];
    [CCCatalog select:row selected:YES];
    CHECK(c.selectedBytes == 50 && c.selectedFiles == 2, @"selected %lld / %d", c.selectedBytes, c.selectedFiles);
    CHECK(unofficial.selectedBytes == 50, @"section selected");
    [CCCatalog select:row.children[0] selected:NO];
    CHECK(row.selectedBytes == 30 && c.selectedFiles == 1, @"after clearing one");
    EQUAL([c.selectedFilesList valueForKey:@"path"], @[ @"Compilation/1. Released Discography/2. affliction/c.mp3" ]);
    [c clearSelection];
    CHECK(c.selectedFiles == 0 && c.selectedBytes == 0, @"cleared");

    // Natural sort.
    CHECK([CCCatalog naturalCompare:@"2. a" with:@"10. a"] < 0, @"2 before 10");
    CHECK([CCCatalog naturalCompare:@"track 007" with:@"Track 7"] == 0, @"leading zeros and case");
    CHECK([CCCatalog naturalCompare:@"abc" with:@"abcd"] < 0, @"prefix first");
    EQUAL([CCCatalog displayName:@"7. Goodbye & Good Riddance"], @"Goodbye & Good Riddance");
    EQUAL([CCCatalog displayName:@"10.5 mix"], @"10.5 mix");

    // A folder of 20,000 files selects without a walk per ancestor per file taking long.
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 20000; i++) [many addObject:F([NSString stringWithFormat:@"Others/Photos/f%d/%d.jpg", i % 40, i], 3)];
    CCCatalog *big = [CCCatalog build:many];
    NSDate *start = [NSDate date];
    [CCCatalog select:big.root selected:YES];
    NSTimeInterval spent = -start.timeIntervalSinceNow;
    CHECK(big.selectedFiles == 20000 && big.selectedBytes == 60000, @"big selection");
    CHECK(spent < 0.05, @"selecting 20,000 files took %.3f s", spent);
}

static void TestLibraryRows(void) {
    CCCatalog *c = [CCCatalog build:@[
        F(@"Others/Photos/a/one.jpg", 1),
        F(@"Others/Photos/b/two.jpg", 1),
        F(@"Compilation/1. Released Discography/5. Fighting Demons/Lucid.mp3", 1),
        F(@"Compilation/1. Released Discography/5. Fighting Demons/Other.mp3", 1),
    ]];
    CCLibraryRows *rows = [[CCLibraryRows alloc] initWithSection:[c section:@"albums"]];
    CHECK(rows.rows.count == 1, @"one row");
    [rows toggle:rows.rows[0].node];
    NSArray *r = rows.rows;
    EQUAL([r valueForKeyPath:@"node.name"], (@[ @"5. Fighting Demons", @"Lucid.mp3", @"Other.mp3" ]));
    CHECK(((CCLibraryRow *)r[1]).depth == 1, @"depth");
    CHECK(((CCLibraryRow *)r[0]).expanded, @"expanded");
    CHECK(![rows toggle:((CCLibraryRow *)r[1]).node], @"a file does not open");
    [rows toggle:rows.rows[0].node];
    CHECK(rows.rows.count == 1, @"closed again");

    CCLibraryRows *search = [[CCLibraryRows alloc] initWithSection:[c section:@"media"]];
    search.query = @"TWO ";
    EQUAL([search.rows valueForKeyPath:@"node.name"], @[ @"two.jpg" ]);
    search.query = @"photos";
    CHECK(search.rows.count == 1 && search.rows[0].depth == 0, @"a matching folder stands for what is in it");

    // The Overview's search goes through every section at once.
    CCCatalogSection *everything = c.everything;
    CHECK(everything.fileCount == c.totalFiles && everything.size == c.totalBytes, @"everything holds %d files", everything.fileCount);
    CCLibraryRows *all = [[CCLibraryRows alloc] initWithSection:everything];
    all.query = @"two";
    EQUAL([all.rows valueForKeyPath:@"node.name"], @[ @"two.jpg" ]);
    all.query = @"lucid";
    EQUAL([all.rows valueForKeyPath:@"node.name"], @[ @"Lucid.mp3" ]);
}

// ───────────── local paths ─────────────

static void TestLocalPath(void) {
    NSString *dest = Join(NSTemporaryDirectory(), @"dest");
    for (NSString *bad in @[ @"../evil.mp3", @"a/../../evil.mp3", @"..\\evil.mp3", @"", @"///" ])
        CHECK([CCLocalPath resolve:bad under:dest] == nil, @"%@ resolved", bad);
    NSString *rooted = [CCLocalPath resolve:@"/etc/passwd" under:dest];
    CHECK([rooted hasPrefix:dest] && [rooted hasSuffix:@"/etc/passwd"], @"rooted path left: %@", rooted);
    NSString *trailing = [CCLocalPath resolve:@"a/.. /b.mp3" under:dest];
    CHECK([trailing hasPrefix:dest] && [trailing hasSuffix:@"/a/_/b.mp3"], @"dots-and-space folder: %@", trailing);
    CHECK([[CCLocalPath resolve:@"a/b.mp3" under:@"/x/y/"] isEqualToString:@"/x/y/a/b.mp3"], @"trailing slash on the folder");

    EQUAL([CCLocalPath clean:@"a:b*c.mp3"], @"a_b_c.mp3");
    EQUAL([CCLocalPath clean:@"trailing. "], @"trailing");
    EQUAL([CCLocalPath clean:@"CON.mp3"], @"_CON.mp3");
    EQUAL([CCLocalPath clean:@"lpt1"], @"_lpt1");
    EQUAL([CCLocalPath clean:@"NOTHING'S DIFFERENT 3"], @"NOTHING'S DIFFERENT 3");
    EQUAL([CCLocalPath clean:@"..."], @"_");
    EQUAL([CCLocalPath clean:@"  x"], @"x");
    NSString *illegal = [CCLocalPath clean:@"What? (feat. A/B)<>|\"\\.mp3"];
    CHECK([illegal rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"<>:\"\\|?*/"]].location == NSNotFound, @"illegal kept: %@", illegal);
    EQUAL([CCLocalPath clean:@"a\tb"], @"a_b");

    NSString *longName = [[@"" stringByPaddingToLength:300 withString:@"ж" startingAtIndex:0] stringByAppendingString:@".mp3"];
    NSString *clean = [CCLocalPath clean:longName];
    CHECK([clean hasSuffix:@".mp3"], @"long name lost its extension");
    CHECK([clean lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 240, @"long name too long");
    NSString *emoji = [[@"" stringByPaddingToLength:200 withString:@"\U0001F3B5" startingAtIndex:0] stringByAppendingString:@".wav"];
    NSString *cut = [CCLocalPath clean:emoji];
    CHECK([cut dataUsingEncoding:NSUTF8StringEncoding] != nil && [cut hasSuffix:@".wav"], @"a surrogate pair was split");
}

// ───────────── lyrics ─────────────

static CCSong *Song(NSString *lyrics, NSString *synced) {
    CCSong *s = [CCSong new];
    s.name = @"x";
    s.category = @"unreleased";
    s.lyrics = lyrics;
    s.syncedLyrics = synced;
    return s;
}

static void TestLyricsFixture(void) {
    const char *dir = getenv("JUICEDOWNLOADER_FIXTURES");
    CHECK(dir != NULL, @"JUICEDOWNLOADER_FIXTURES is not set");
    if (!dir) return;
    NSData *data = [NSData dataWithContentsOfFile:Join([NSString stringWithUTF8String:dir], @"lyrics-match.json")];
    CHECK(data != nil, @"no fixture");
    if (!data) return;
    NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSMutableArray *songs = [NSMutableArray array];
    for (id json in fixture[@"songs"]) [songs addObject:[CCSong fromJSON:json]];
    CCLyricsIndex *index = [[CCLyricsIndex alloc] initWithSongs:songs];
    NSInteger cases = 0;
    for (NSDictionary *c in fixture[@"cases"]) {
        cases++;
        NSString *path = c[@"path"];
        id wanted = c[@"song"], kind = c[@"kind"], fit = c[@"fit"];
        CCLyricsMatch *match = [index find:path];
        BOOL songOK = wanted == NSNull.null ? match == nil : match && match.song.identifier == [wanted longLongValue];
        CHECK(songOK, @"%@: wanted %@, got %lld (%@)", path, wanted, match ? match.song.identifier : -1, c[@"why"]);
        if (kind != NSNull.null && kind != nil) {
            NSString *got = match ? CCLyricsMatchKindName(match.kind) : @"none";
            CHECK([[kind componentsSeparatedByString:@"|"] containsObject:got], @"%@: wanted kind %@, got %@ (%@)", path, kind, got, c[@"why"]);
        }
        if (fit != NSNull.null && fit != nil) EQUAL(match ? CCLyricsFitName(match.fit) : @"none", fit);
    }
    CHECK(cases >= 25, @"only %ld cases ran", (long)cases);
}

static void TestLyricsMatcher(void) {
    CHECK([CCLyricsIndex isSessionFile:@"Session Edits/x/a.mp3"], @"tree");
    CHECK([CCLyricsIndex isSessionFile:@"Studio Sessions/x/a.zip"], @"tree");
    CHECK([CCLyricsIndex isSessionFile:@"Hey Wonderland [Session Edit].mp3"], @"name");
    CHECK([CCLyricsIndex isSessionFile:@"x/MOTIONS AND 365 SESSION v2.mp3"], @"name at the end");
    CHECK(![CCLyricsIndex isSessionFile:@"Compilation/2. Unreleased Discography/1. JUTE (Sessions)/a.mp3"], @"an era folder is no session");

    CCSong *(^make)(long long, NSString *, NSString *, NSString *) = ^CCSong *(long long identifier, NSString *name, NSString *category, NSString *words) {
        CCSong *s = Song(words, nil);
        s.identifier = identifier;
        s.name = name;
        s.category = category;
        return s;
    };
    NSString *hour = [@"" stringByPaddingToLength:6000 withString:@"take " startingAtIndex:0];
    CCLyricsIndex *index = [[CCLyricsIndex alloc] initWithSongs:@[
        make(1, @"Finished", @"released", @"song words"),
        make(2, @"Finished", @"recording_session", @"session words"),
        make(3, @"Hour", @"recording_session", hour),
        make(4, @"Short", @"recording_session", @"few words"),
        make(5, @"Stuck", @"recording_session", @"stuck words"),
    ]];
    CCLyricsMatch *m = [index find:@"Finished.mp3"];
    CHECK(m.song.identifier == 1 && m.fit == CCLyricsFitSameRecording, @"a finished file takes the song");
    m = [index find:@"Finished [Session Edit].mp3"];
    CHECK(m.song.identifier == 2 && m.fit == CCLyricsFitSameRecording, @"a session file takes the session");
    CHECK([index find:@"Hour.mp3"] == nil, @"an hour of takes does not stand in for a finished song");
    m = [index find:@"Short.mp3"];
    CHECK(m.song.identifier == 4 && m.fit == CCLyricsFitOtherRecording, @"short session words stand in, marked");
    m = [index find:@"Drinks In The Air (Stuck) [Session Edit].mp3"];
    CHECK(m.song.identifier == 5 && m.kind == CCLyricsMatchLoose, @"a bracket alias");
    m = [index find:@"Finished + Stuck [Session Edit].mp3"];
    CHECK(m.song.identifier == 2 && [m.song.lyrics isEqualToString:@"session words\n\nstuck words"], @"joined: %@", m.song.lyrics);
    CHECK([index find:@"Finished + Nowhere.mp3"] == nil, @"a joined file needs every song");
}

static void TestLrc(void) {
    EQUAL([CCLrc normalize:@"[0:00.92] Ayy\r\n[10:07.04] Yeah\nnot a line"], @"[00:00.92]Ayy\n[10:07.04]Yeah\n");
    EQUAL([CCLrc normalize:@"[1:02] whole second\n[1:03.5] half\n[1:04.123] long\n[1:05:40] colon"],
          @"[01:02.00]whole second\n[01:03.50]half\n[01:04.12]long\n[01:05.40]colon\n");
    CHECK([CCLrc normalize:@"just words"] == nil, @"words are not timed");
    CHECK([CCLrc normalize:nil] == nil, @"nil");
    CHECK([CCLrc normalize:@" \n "] == nil, @"blank");
    EQUAL([CCLrc plain:@"  a\r\nb\rc  "], @"a\nb\nc\n");
}

// ───────────── ID3 ─────────────

static NSData *Audio(void) {
    const uint8_t a[] = { 0xFF, 0xFB, 0x90, 0x00, 1, 2, 3, 4 };
    return [NSData dataWithBytes:a length:sizeof a];
}

static NSData *Tag(uint8_t version, NSData *frames, uint8_t flags, NSUInteger padding) {
    NSUInteger n = frames.length + padding;
    uint8_t h[10] = { 'I', 'D', '3', version, 0, flags, (n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127 };
    NSMutableData *d = [NSMutableData dataWithBytes:h length:10];
    [d appendData:frames];
    [d increaseLengthBy:padding];
    return d;
}

static NSData *Frame(const char *identifier, NSData *body, uint8_t version) {
    NSUInteger n = body.length;
    NSMutableData *d = [NSMutableData dataWithBytes:identifier length:4];
    uint8_t size[6] = { 0 };
    if (version == 4) {
        size[0] = (n >> 21) & 127; size[1] = (n >> 14) & 127; size[2] = (n >> 7) & 127; size[3] = n & 127;
    } else {
        size[0] = (n >> 24) & 255; size[1] = (n >> 16) & 255; size[2] = (n >> 8) & 255; size[3] = n & 255;
    }
    [d appendBytes:size length:6];
    [d appendData:body];
    return d;
}

static BOOL Contains(NSData *data, NSData *part) { return [data rangeOfData:part options:0 range:NSMakeRange(0, data.length)].location != NSNotFound; }
static BOOL EndsWith(NSData *data, NSData *tail) {
    return data.length >= tail.length && [[data subdataWithRange:NSMakeRange(data.length - tail.length, tail.length)] isEqualToData:tail];
}
static NSData *Concat(NSData *a, NSData *b) {
    NSMutableData *d = [a mutableCopy];
    [d appendData:b];
    return d;
}
static NSString *WriteFile(NSString *dir, NSString *name, NSData *data) {
    NSString *p = Join(dir, name);
    [data writeToFile:p atomically:NO];
    return p;
}
static BOOL Has(NSString *f) { return [CCId3Lyrics has:f error:nil]; }
static NSData *Utf16(NSString *s) { return [s dataUsingEncoding:NSUTF16LittleEndianStringEncoding]; }
static NSData *Utf8(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }

static void TestId3(void) {
    NSString *dir = Scratch();
    // v2.3 and v2.4 keep every other frame and the audio.
    for (uint8_t version = 3; version <= 4; version++) {
        NSMutableData *titleBody = [NSMutableData dataWithLength:1];
        [titleBody appendData:Utf8(@"Lucid Dreams")];
        NSData *title = Frame("TIT2", titleBody, version);
        NSMutableData *pictureBody = [NSMutableData dataWithLength:2000];
        memset(pictureBody.mutableBytes, 0xFF, 2000);
        NSData *picture = Frame("APIC", pictureBody, version);
        NSString *file = WriteFile(dir, [NSString stringWithFormat:@"v%d.mp3", version], Concat(Tag(version, Concat(title, picture), 0, 100), Audio()));
        CHECK(![CCId3Lyrics has:file error:nil], @"v2.%d: no words yet", version);
        CHECK([CCId3Lyrics canTag:file error:nil], @"v2.%d can be tagged", version);
        CHECK([CCId3Lyrics write:@"Я still see your shadows\n" to:file error:nil], @"v2.%d write", version);
        CHECK(Has(file), @"v2.%d has words", version);
        NSData *bytes = [NSData dataWithContentsOfFile:file];
        CHECK(((const uint8_t *)bytes.bytes)[3] == version, @"v2.%d: version kept", version);
        CHECK(Contains(bytes, title), @"v2.%d: title kept byte for byte", version);
        CHECK(Contains(bytes, picture), @"v2.%d: picture kept byte for byte", version);
        CHECK(EndsWith(bytes, Audio()), @"v2.%d: audio kept", version);
        CHECK(Contains(bytes, version == 4 ? Utf8(@"Я still") : Utf16(@"Я still")), @"v2.%d: words encoded", version);
        CHECK(!Exists([file stringByAppendingString:@".tagging"]), @"temporary file left");
    }

    // Another format named .mp3 is left alone, with or without a tag in front.
    for (NSData *head in @[ [NSData dataWithBytes:"\0\0\0\x18" "ftypM4A " length:12],
                            [NSData dataWithBytes:"RIFF\1\2\3\4WAVE" length:12],
                            [NSData dataWithBytes:"\x1A\x45\xDF\xA3\1\2\3\4\5\6\7\x08" length:12] ]) {
        CHECK(![CCId3Lyrics canTag:WriteFile(dir, @"other.mp3", head) error:nil], @"other format refused");
        NSMutableData *tagged = [NSMutableData dataWithBytes:"ID3\3\0\0\0\0\0\0" length:10];
        [tagged appendData:head];
        CHECK(![CCId3Lyrics canTag:WriteFile(dir, @"other2.mp3", tagged) error:nil], @"other format behind a tag refused");
    }

    // No tag: gets one.
    NSString *none = WriteFile(dir, @"none.mp3", Audio());
    CHECK([CCId3Lyrics canTag:none error:nil], @"no tag can be tagged");
    CHECK([CCId3Lyrics write:@"one" to:none error:nil], @"write");
    NSData *noneBytes = [NSData dataWithContentsOfFile:none];
    CHECK(((const uint8_t *)noneBytes.bytes)[0] == 'I', @"a tag is first");
    CHECK(EndsWith(noneBytes, Audio()), @"audio kept");
    CHECK(Has(none), @"words there");

    // Writing twice leaves one frame.
    CHECK([CCId3Lyrics write:@"two" to:none error:nil], @"second write");
    noneBytes = [NSData dataWithContentsOfFile:none];
    NSData *uslt = Utf8(@"USLT");
    NSRange first = [noneBytes rangeOfData:uslt options:0 range:NSMakeRange(0, noneBytes.length)];
    NSRange second = [noneBytes rangeOfData:uslt options:0 range:NSMakeRange(NSMaxRange(first), noneBytes.length - NSMaxRange(first))];
    CHECK(second.location == NSNotFound, @"two USLT frames");
    CHECK(Contains(noneBytes, Utf16(@"two")) && !Contains(noneBytes, Utf16(@"one")), @"the new words replaced the old");
    CHECK(EndsWith(noneBytes, Audio()), @"audio kept");

    // A v2.3 tag with unsynchronisation is undone.
    const uint8_t synced[] = { 'T', 'I', 'T', '2', 0, 0, 0, 4, 0, 0, 0, 0xFF, 0x00, 0xE0, 65 };
    NSString *unsync = WriteFile(dir, @"unsync.mp3", Concat(Tag(3, [NSData dataWithBytes:synced length:sizeof synced], 0x80, 0), Audio()));
    CHECK([CCId3Lyrics write:@"x" to:unsync error:nil], @"write over unsync");
    NSData *unsyncBytes = [NSData dataWithContentsOfFile:unsync];
    CHECK(((const uint8_t *)unsyncBytes.bytes)[5] == 0, @"flag cleared");
    const uint8_t plainFrame[] = { 'T', 'I', 'T', '2', 0, 0, 0, 4, 0, 0, 0, 0xFF, 0xE0, 65 };
    CHECK(Contains(unsyncBytes, [NSData dataWithBytes:plainFrame length:sizeof plainFrame]), @"frame not resynchronised");
    CHECK(EndsWith(unsyncBytes, Audio()), @"audio kept");

    // v2.2 is not touched and the words go beside it.
    NSMutableData *old = [NSMutableData dataWithBytes:(const uint8_t[]){ 'I', 'D', '3', 2, 0, 0, 0, 0, 0, 0 } length:10];
    [old appendData:Audio()];
    NSString *v22 = WriteFile(dir, @"old.mp3", old);
    CHECK(![CCId3Lyrics canTag:v22 error:nil], @"v2.2 refused");
    CCLyricsResult result = [CCLyricsWriter apply:Song(@"words", @"[0:01.00] words") to:v22 options:[CCLyricsOptions embed:YES sidecar:NO timedInTag:NO]];
    CHECK(result == CCLyricsResultWritten, @"v2.2 result %ld", (long)result);
    CHECK([[NSData dataWithContentsOfFile:v22] isEqualToData:old], @"v2.2 file changed");
    EQUAL(TextOf(Join(dir, @"old.lrc")), @"[00:01.00]words\n");
    NSError *v22Error = nil;
    CHECK(![CCId3Lyrics write:@"x" to:v22 error:&v22Error] && v22Error != nil, @"writing v2.2 must fail");

    // Existing words are kept, and the tag can hold timings.
    CCSong *both = Song(@"plain", @"[0:01.00] timed");
    NSString *timed = WriteFile(dir, @"timed.mp3", Audio());
    CHECK([CCLyricsWriter apply:both to:timed options:[CCLyricsOptions embed:YES sidecar:NO timedInTag:YES]] == CCLyricsResultWritten, @"timed written");
    CHECK(Contains([NSData dataWithContentsOfFile:timed], Utf16(@"[00:01.00]timed")), @"timed words in the tag");
    CHECK(!Exists(Join(dir, @"timed.lrc")), @"no file beside it was asked for");
    CHECK([CCLyricsWriter apply:both to:timed options:[CCLyricsOptions embed:YES sidecar:NO timedInTag:NO]] == CCLyricsResultAlreadyThere, @"already there");

    // Plain words go in a text file when there are no timings; a format without tags always gets the file beside it.
    NSString *wav = WriteFile(dir, @"a.wav", Bytes(3));
    CHECK([CCLyricsWriter apply:Song(@"a\r\nb", nil) to:wav options:[CCLyricsOptions embed:YES sidecar:NO timedInTag:NO]] == CCLyricsResultWritten, @"wav");
    EQUAL(TextOf(Join(dir, @"a.txt")), @"a\nb\n");
    NSString *noWords = WriteFile(dir, @"b.mp3", Audio());
    CHECK([CCLyricsWriter apply:Song(nil, nil) to:noWords options:[CCLyricsOptions embed:YES sidecar:YES timedInTag:NO]] == CCLyricsResultNone, @"no words");
    // A damaged tag fails without harm.
    NSString *damaged = WriteFile(dir, @"d.mp3", [NSData dataWithBytes:(const uint8_t[]){ 'I', 'D', '3', 3, 0, 0, 0, 0, 0x7F, 0x7F, 1 } length:11]);
    NSData *damagedBefore = [NSData dataWithContentsOfFile:damaged];
    CHECK([CCLyricsWriter apply:Song(@"w", nil) to:damaged options:[CCLyricsOptions embed:YES sidecar:NO timedInTag:NO]] == CCLyricsResultFailed, @"damaged tag");
    CHECK([[NSData dataWithContentsOfFile:damaged] isEqualToData:damagedBefore], @"damaged file changed");

    // Replace: only then do words already there give way, in the tag and beside it.
    NSString *better = WriteFile(dir, @"better.mp3", Audio());
    CCLyricsOptions *full = [CCLyricsOptions embed:YES sidecar:YES timedInTag:NO];
    CHECK(![CCLyricsWriter has:better], @"no words yet");
    CHECK([CCLyricsWriter applyWords:@"old words" synced:@"[0:01.00] old" to:better options:full replace:NO] == CCLyricsResultWritten, @"first words");
    CHECK([CCLyricsWriter has:better], @"has them");
    EQUAL(TextOf(Join(dir, @"better.lrc")), @"[00:01.00]old\n");
    CHECK([CCLyricsWriter applyWords:@"new words" synced:nil to:better options:full replace:NO] == CCLyricsResultAlreadyThere, @"kept without replace");
    CHECK(Contains([NSData dataWithContentsOfFile:better], Utf16(@"old words")), @"tag kept");
    CHECK([CCLyricsWriter applyWords:@"new words" synced:nil to:better options:full replace:YES] == CCLyricsResultWritten, @"replaced");
    CHECK(Contains([NSData dataWithContentsOfFile:better], Utf16(@"new words")) && !Contains([NSData dataWithContentsOfFile:better], Utf16(@"old words")), @"tag replaced");
    CHECK(!Exists(Join(dir, @"better.lrc")), @"the old file beside it went");
    EQUAL(TextOf(Join(dir, @"better.txt")), @"new words\n");
    NSString *zip = WriteFile(dir, @"session.zip", Bytes(4));
    CHECK([CCLyricsWriter apply:Song(@"words", nil) to:zip options:[CCLyricsOptions embed:YES sidecar:NO timedInTag:NO]] == CCLyricsResultWritten, @"a zip gets them beside it");
    CHECK([CCLyricsWriter has:zip], @"has them beside it");
    [FM() removeItemAtPath:dir error:nil];
}

// ───────────── the stub server ─────────────

/// What the stub does with a request: the n-th it has seen, counting from 1.
typedef void (^CCStubHandler)(NSURLRequest *request, NSInteger n, id<NSURLProtocolClient> client, NSURLProtocol *protocol);

static NSLock *gStubLock;
static CCStubHandler gStub;
static NSMutableArray<NSURLRequest *> *gRequests;

@interface CCStubProtocol : NSURLProtocol
@end

@implementation CCStubProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    [gStubLock lock];
    [gRequests addObject:self.request];
    NSInteger n = (NSInteger)gRequests.count;
    CCStubHandler handler = gStub;
    [gStubLock unlock];
    handler(self.request, n, self.client, self);
}
- (void)stopLoading {}
@end

static NSURLSessionConfiguration *StubConfiguration(void) {
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.protocolClasses = @[ CCStubProtocol.class ];
    return c;
}

static void Serve(CCStubHandler handler) {
    [gStubLock lock];
    gStub = [handler copy];
    gRequests = [NSMutableArray array];
    [gStubLock unlock];
}

static NSArray<NSURLRequest *> *Requests(void) {
    [gStubLock lock];
    NSArray *r = [gRequests copy];
    [gStubLock unlock];
    return r;
}

static void Answer(NSURLRequest *r, id<NSURLProtocolClient> client, NSURLProtocol *p, NSInteger status, NSDictionary *headers, NSData *body) {
    NSMutableDictionary *h = [headers ?: @{} mutableCopy];
    // Without a telling type the loader holds a short answer back to sniff it.
    h[@"Content-Type"] = @"audio/mpeg";
    if (!h[@"Content-Length"] && !h[@"Content-Range"]) h[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:r.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:h];
    [client URLProtocol:p didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (body.length) [client URLProtocol:p didLoadData:body];
    [client URLProtocolDidFinishLoading:p];
}

static long long RangeFrom(NSURLRequest *r) {
    NSString *range = [r valueForHTTPHeaderField:@"Range"];
    long long from = -1;
    if (range) sscanf(range.UTF8String, "bytes=%lld-", &from);
    return from;
}

static void AnswerRange(NSURLRequest *r, id<NSURLProtocolClient> client, NSURLProtocol *p, NSData *all) {
    long long from = RangeFrom(r);
    NSData *part = [all subdataWithRange:NSMakeRange((NSUInteger)from, all.length - (NSUInteger)from)];
    NSDictionary *h = @{ @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lu/%lu", from, (unsigned long)all.length - 1, (unsigned long)all.length],
                         @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)part.length] };
    Answer(r, client, p, 206, h, part);
}

static CCDownloadOptions *Options(NSString *dir) {
    CCDownloadOptions *o = [CCDownloadOptions new];
    o.destination = dir;
    o.retryDelay = 0.001;
    return o;
}

static CCDownloadEngine *Engine(void) { return [[CCDownloadEngine alloc] initWithConfiguration:StubConfiguration()]; }
static CCDownloadFile *DF(NSString *path, long long size) { return [CCDownloadFile path:path size:size]; }

// ───────────── downloads ─────────────

static void TestDownloads(void) {
    NSString *dir = Scratch();
    NSData *all = Bytes(1000);

    // Fetches into folders and leaves no part file.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 200, nil, all); });
    CCDownloadReport *report = [Engine() run:@[ DF(@"A & B/c d.mp3", 1000) ] options:Options(dir) progress:nil cancel:nil];
    CHECK(report.downloaded == 1 && report.failures.count == 0, @"plain fetch: %ld, %@", (long)report.downloaded, report.failures);
    CHECK(report.bytes == 1000, @"report bytes");
    EQUAL([NSData dataWithContentsOfFile:Join(dir, @"A & B/c d.mp3")], all);
    CHECK(!Exists(Join(dir, @"A & B/c d.mp3.part")), @"part file left");
    CHECK([Requests()[0].URL.absoluteString containsString:@"path=A%20%26%20B%2Fc%20d.mp3"], @"escaping: %@", Requests()[0].URL);
    CHECK([[Requests()[0] valueForHTTPHeaderField:@"User-Agent"] hasPrefix:@"JuiceDownloader/"], @"user agent: %@", [Requests()[0] valueForHTTPHeaderField:@"User-Agent"]);
    CHECK([Requests()[0] valueForHTTPHeaderField:@"Range"] == nil, @"no range on a fresh file");

    // A file already there is not fetched again, but still gets its lyrics.
    NSString *d2 = Scratch();
    [Bytes(10) writeToFile:Join(d2, @"x.mp3") atomically:NO];
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 500, nil, [NSData data]); });
    NSMutableArray *seen = [NSMutableArray array];
    CCDownloadOptions *withAfter = Options(d2);
    withAfter.afterFile = ^(NSString *api, NSString *local) { @synchronized (seen) { [seen addObject:api]; } };
    report = [Engine() run:@[ DF(@"x.mp3", 10) ] options:withAfter progress:nil cancel:nil];
    CHECK(report.alreadyThere == 1 && report.downloaded == 0, @"already there");
    CHECK(Requests().count == 0, @"a request for a file already there");
    EQUAL(seen, @[ @"x.mp3" ]);

    // A different size means a new copy.
    NSString *d3 = Scratch();
    [Bytes(5) writeToFile:Join(d3, @"x.mp3") atomically:NO];
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 200, nil, Bytes(10)); });
    report = [Engine() run:@[ DF(@"x.mp3", 10) ] options:Options(d3) progress:nil cancel:nil];
    CHECK(report.downloaded == 1, @"new copy");
    EQUAL([NSData dataWithContentsOfFile:Join(d3, @"x.mp3")], Bytes(10));

    // Lyrics written into an MP3 grow it past the catalog's size: it still counts as complete, and is not fetched again.
    NSString *d3b = Scratch();
    NSString *tagged = Join(d3b, @"tagged.mp3");
    [Audio() writeToFile:tagged atomically:NO];
    CHECK([CCDownloadEngine isComplete:tagged size:(long long)Audio().length], @"catalog size is complete");
    CHECK(![CCDownloadEngine isComplete:tagged size:999], @"an MP3 of another size without words is not complete");
    CHECK([CCId3Lyrics write:@"words" to:tagged error:nil], @"tag it");
    CHECK([CCDownloadEngine isComplete:tagged size:(long long)Audio().length], @"an MP3 with words is complete");
    CHECK(![CCDownloadEngine isComplete:Join(d3b, @"none.mp3") size:0], @"no file is not complete");
    NSString *wavGrown = Join(d3b, @"x.wav");
    [Bytes(20) writeToFile:wavGrown atomically:NO];
    CHECK(![CCDownloadEngine isComplete:wavGrown size:10], @"only an MP3 gets the exception");
    NSString *oldTag = Join(d3b, @"old.mp3");
    [[NSData dataWithBytes:(const uint8_t[]){ 'I', 'D', '3', 2, 0, 0, 0, 0, 0, 0, 1 } length:11] writeToFile:oldTag atomically:NO];
    CHECK(![CCDownloadEngine isComplete:oldTag size:10], @"an unreadable tag is not complete");
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 200, nil, Audio()); });
    report = [Engine() run:@[ DF(@"tagged.mp3", (long long)Audio().length) ] options:Options(d3b) progress:nil cancel:nil];
    CHECK(report.alreadyThere == 1 && Requests().count == 0, @"a tagged MP3 was fetched again: %lu requests", (unsigned long)Requests().count);
    CHECK([CCLibrary bytesStillNeeded:@[ DF(@"tagged.mp3", (long long)Audio().length) ] under:d3b] == 0, @"a tagged MP3 is not still needed");

    // Resumes a part file by range (206).
    NSString *d4 = Scratch();
    [[all subdataWithRange:NSMakeRange(0, 400)] writeToFile:Join(d4, @"x.mp3.part") atomically:NO];
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { AnswerRange(r, c, p, all); });
    report = [Engine() run:@[ DF(@"x.mp3", 1000) ] options:Options(d4) progress:nil cancel:nil];
    CHECK(RangeFrom(Requests()[0]) == 400, @"range from %lld", RangeFrom(Requests()[0]));
    CHECK(Requests().count == 1, @"one request to resume");
    EQUAL([NSData dataWithContentsOfFile:Join(d4, @"x.mp3")], all);
    CHECK(!Exists(Join(d4, @"x.mp3.part")), @"part left after resume");

    // A server that ignores the range (200) starts the file over.
    NSString *d5 = Scratch();
    [[NSMutableData dataWithLength:400] writeToFile:Join(d5, @"x.mp3.part") atomically:NO];
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 200, nil, all); });
    [Engine() run:@[ DF(@"x.mp3", 1000) ] options:Options(d5) progress:nil cancel:nil];
    EQUAL([NSData dataWithContentsOfFile:Join(d5, @"x.mp3")], all);

    // 416 throws the part away and starts over.
    NSString *d6 = Scratch();
    [[NSMutableData dataWithLength:400] writeToFile:Join(d6, @"x.mp3.part") atomically:NO];
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        if (RangeFrom(r) > 0) Answer(r, c, p, 416, nil, [NSData data]);
        else Answer(r, c, p, 200, nil, all);
    });
    report = [Engine() run:@[ DF(@"x.mp3", 1000) ] options:Options(d6) progress:nil cancel:nil];
    CHECK(report.downloaded == 1 && Requests().count == 2, @"416: %lu requests", (unsigned long)Requests().count);
    EQUAL([NSData dataWithContentsOfFile:Join(d6, @"x.mp3")], all);

    // A part longer than the catalog's size is not sent as a range at all.
    NSString *d7 = Scratch();
    [[NSMutableData dataWithLength:2000] writeToFile:Join(d7, @"x.mp3.part") atomically:NO];
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 200, nil, all); });
    [Engine() run:@[ DF(@"x.mp3", 1000) ] options:Options(d7) progress:nil cancel:nil];
    CHECK([Requests()[0] valueForHTTPHeaderField:@"Range"] == nil, @"range for a part that is too long");

    // A 206 for another range never lands in the part file.
    NSString *d7b = Scratch();
    [[all subdataWithRange:NSMakeRange(0, 400)] writeToFile:Join(d7b, @"x.mp3.part") atomically:NO];
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        if (n == 1) Answer(r, c, p, 206, @{ @"Content-Range": @"bytes 500-999/1000", @"Content-Length": @"500" }, [all subdataWithRange:NSMakeRange(500, 500)]);
        else Answer(r, c, p, 200, nil, all);
    });
    report = [Engine() run:@[ DF(@"x.mp3", 1000) ] options:Options(d7b) progress:nil cancel:nil];
    EQUAL([NSData dataWithContentsOfFile:Join(d7b, @"x.mp3")], all);

    // A dropped connection is resumed, and a short file never takes the name.
    NSString *d8 = Scratch();
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        if (n == 1) Answer(r, c, p, 200, @{ @"Content-Length": @"1000" }, [all subdataWithRange:NSMakeRange(0, 300)]);
        else AnswerRange(r, c, p, all);
    });
    report = [Engine() run:@[ DF(@"x.mp3", 1000) ] options:Options(d8) progress:nil cancel:nil];
    CHECK(report.failures.count == 0, @"dropped: %@", report.failures);
    CHECK(Requests().count == 2, @"dropped: %lu requests", (unsigned long)Requests().count);
    CHECK(RangeFrom(Requests()[1]) == 300, @"resumed from %lld", RangeFrom(Requests()[1]));
    EQUAL([NSData dataWithContentsOfFile:Join(d8, @"x.mp3")], all);

    // A connection error is resumed too; when it never recovers the file fails, without its real name.
    NSString *d9 = Scratch();
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:r.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Length": @"1000", @"Content-Type": @"audio/mpeg" }];
        [c URLProtocol:p didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [c URLProtocol:p didLoadData:[all subdataWithRange:NSMakeRange(0, 100)]];
        [c URLProtocol:p didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]];
    });
    CCDownloadOptions *few = Options(d9);
    few.maxAttempts = 3;
    report = [Engine() run:@[ DF(@"x.mp3", 1000) ] options:few progress:nil cancel:nil];
    CHECK(report.failures.count == 1 && report.downloaded == 0, @"never recovers");
    CHECK(Requests().count == 3, @"attempts %lu", (unsigned long)Requests().count);
    CHECK(!Exists(Join(d9, @"x.mp3")), @"a short file took the name");
    CHECK(Exists(Join(d9, @"x.mp3.part")), @"the part is kept for next time");

    // 429 and 5xx wait and try again; Retry-After is honoured.
    NSString *d10 = Scratch();
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        if (n == 1) Answer(r, c, p, 429, @{ @"Retry-After": @"0" }, [NSData data]);
        else if (n == 2) Answer(r, c, p, 503, nil, [NSData data]);
        else Answer(r, c, p, 200, nil, Bytes(10));
    });
    report = [Engine() run:@[ DF(@"x.mp3", 10) ] options:Options(d10) progress:nil cancel:nil];
    CHECK(report.downloaded == 1 && Requests().count == 3, @"429: %lu requests", (unsigned long)Requests().count);

    // Backoff grows: 3 attempts at a 0.1 s delay wait 0.1 + 0.2 s.
    NSString *d10b = Scratch();
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 500, nil, [NSData data]); });
    CCDownloadOptions *backoff = Options(d10b);
    backoff.retryDelay = 0.1;
    backoff.maxAttempts = 3;
    NSDate *startedBackoff = [NSDate date];
    report = [Engine() run:@[ DF(@"x.mp3", 10) ] options:backoff progress:nil cancel:nil];
    NSTimeInterval spentBackoff = -startedBackoff.timeIntervalSinceNow;
    CHECK(spentBackoff >= 0.29, @"backoff took only %.2f s", spentBackoff);
    EQUAL(report.failures.firstObject.reason, @"HTTP 500");

    // A missing file fails once and the rest carry on.
    NSString *d11 = Scratch();
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        if ([r.URL.absoluteString containsString:@"gone"]) Answer(r, c, p, 404, nil, [NSData data]);
        else Answer(r, c, p, 200, nil, Bytes(10));
    });
    NSMutableArray<CCDownloadProgress *> *ticks = [NSMutableArray array];
    report = [Engine() run:@[ DF(@"gone.mp3", 10), DF(@"here.mp3", 10) ] options:Options(d11)
                  progress:^(CCDownloadProgress *t) { @synchronized (ticks) { [ticks addObject:t]; } } cancel:nil];
    CHECK(report.failures.count == 1 && [report.failures[0].apiPath isEqualToString:@"gone.mp3"], @"failure list");
    EQUAL(report.failures[0].reason, @"HTTP 404");
    CHECK(report.downloaded == 1 && Requests().count == 2, @"404: %lu requests", (unsigned long)Requests().count);
    CHECK(!Exists(Join(d11, @"gone.mp3")), @"a failed file exists");
    CCDownloadProgress *last = ticks.lastObject;
    CHECK(last.finished == 2 && last.failed == 1 && last.fraction == 1 && last.active.count == 0, @"final progress");

    // An unsafe path fails without a request.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 200, nil, all); });
    report = [Engine() run:@[ DF(@"../evil.mp3", 1) ] options:Options(Scratch()) progress:nil cancel:nil];
    CHECK(report.failures.count == 1 && Requests().count == 0, @"unsafe path");

    // A stream that stops sending counts as dropped: the next attempt resumes.
    NSString *d12 = Scratch();
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        if (n == 1) {
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:r.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Length": @"1000", @"Content-Type": @"audio/mpeg" }];
            [c URLProtocol:p didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [c URLProtocol:p didLoadData:[all subdataWithRange:NSMakeRange(0, 200)]];
            // and then nothing, for ever
        } else AnswerRange(r, c, p, all);
    });
    CCDownloadOptions *stall = Options(d12);
    stall.stallTimeout = 0.2;
    report = [Engine() run:@[ DF(@"x.mp3", 1000) ] options:stall progress:nil cancel:nil];
    CHECK(report.downloaded == 1 && Requests().count == 2, @"stall: %lu requests, %@", (unsigned long)Requests().count, report.failures);
    CHECK(RangeFrom(Requests().lastObject) == 200, @"stall resumed from %lld", RangeFrom(Requests().lastObject));
    EQUAL([NSData dataWithContentsOfFile:Join(d12, @"x.mp3")], all);

    // Stopping keeps the part file, reports it, and starts nothing else.
    NSString *d13 = Scratch();
    CCCancel *stop = [CCCancel new];
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:r.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Length": @"1000", @"Content-Type": @"audio/mpeg" }];
        [c URLProtocol:p didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [c URLProtocol:p didLoadData:[all subdataWithRange:NSMakeRange(0, 200)]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{ [stop cancel]; });
    });
    CCDownloadOptions *one = Options(d13);
    one.parallel = 1;
    report = [Engine() run:@[ DF(@"a.mp3", 1000), DF(@"b.mp3", 1000) ] options:one progress:nil cancel:stop];
    CHECK(report.stopped, @"not reported as stopped");
    CHECK(report.failures.count == 0 && report.downloaded == 0, @"stop is no failure");
    CHECK(Exists(Join(d13, @"a.mp3.part")), @"the part file was not kept");
    CHECK(!Exists(Join(d13, @"a.mp3")) && !Exists(Join(d13, @"b.mp3")) && !Exists(Join(d13, @"b.mp3.part")), @"stop started more");
    CHECK(Requests().count == 1, @"stop: %lu requests", (unsigned long)Requests().count);
    // A later run continues from the part file.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { AnswerRange(r, c, p, all); });
    report = [Engine() run:@[ DF(@"a.mp3", 1000) ] options:one progress:nil cancel:nil];
    CHECK(RangeFrom(Requests()[0]) == 200, @"continued from %lld", RangeFrom(Requests()[0]));
    EQUAL([NSData dataWithContentsOfFile:Join(d13, @"a.mp3")], all);

    // Sixteen really run at once, and the session allows as many connections as the setting.
    CHECK([Engine() configurationForParallel:32].HTTPMaximumConnectionsPerHost == 32, @"connections for 32");
    CHECK([Engine() configurationForParallel:2].HTTPMaximumConnectionsPerHost == 2, @"connections for 2");
    CHECK([Engine() configurationForParallel:99].HTTPMaximumConnectionsPerHost == 32, @"connections are capped");
    CHECK([CCDownloadOptions new].parallel == 8, @"default parallel");
    NSString *dWide = Scratch();
    __block int running = 0, peak = 0;
    NSLock *peakLock = [NSLock new];
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        // Answers later without holding the loader's thread, which a stub shares with every other request.
        [peakLock lock];
        peak = MAX(peak, ++running);
        [peakLock unlock];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
            [peakLock lock];
            running--;
            [peakLock unlock];
            Answer(r, c, p, 200, nil, Bytes(10));
        });
    });
    NSMutableArray *wide = [NSMutableArray array];
    for (int i = 0; i < 16; i++) [wide addObject:DF([NSString stringWithFormat:@"%d.mp3", i], 10)];
    CCDownloadOptions *sixteen = Options(dWide);
    sixteen.parallel = 16;
    report = [Engine() run:wide options:sixteen progress:nil cancel:nil];
    CHECK(report.downloaded == 16, @"wide run: %ld", (long)report.downloaded);
    CHECK(peak >= 12, @"only %d ran at once out of 16", peak);

    // Several at a time, each file whole.
    NSString *d14 = Scratch();
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 200, nil, all); });
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 20; i++) [many addObject:DF([NSString stringWithFormat:@"f/%d.mp3", i], 1000)];
    report = [Engine() run:many options:Options(d14) progress:nil cancel:nil];
    CHECK(report.downloaded == 20, @"parallel: %ld", (long)report.downloaded);
    for (int i = 0; i < 20; i++) EQUAL([NSData dataWithContentsOfFile:Join(d14, [NSString stringWithFormat:@"f/%d.mp3", i])], all);

    // An answer without a length is judged by the catalog's size.
    NSString *d15 = Scratch();
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:r.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type": @"audio/mpeg" }];
        [c URLProtocol:p didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [c URLProtocol:p didLoadData:Bytes(10)];
        [c URLProtocolDidFinishLoading:p];
    });
    report = [Engine() run:@[ DF(@"x.mp3", 10) ] options:Options(d15) progress:nil cancel:nil];
    CHECK(report.downloaded == 1, @"no length: %@", report.failures);
}

// ───────────── web lyrics ─────────────

static NSString *const kWords = @"these are enough words to count as a real song\nand a second line of them";

static NSData *JSONDataEarly(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }

static NSData *Lrclib(NSString *artist, NSString *title) {
    return JSONDataEarly(@[ @{ @"artistName": artist, @"trackName": title, @"plainLyrics": kWords, @"syncedLyrics": @"", @"instrumental": @NO } ]);
}

/// A site's answer, or nil for "nothing here" (what each site says then).
typedef NSData *_Nullable (^CCSite)(NSString *url, NSInteger *status);

static CCWebLyricsResult *Ask(NSString *path, CCSite site) {
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        NSString *url = r.URL.absoluteString;
        NSInteger status = 200;
        NSData *body = site(url, &status);
        if (!body) {
            if ([url containsString:@"lrclib"]) body = JSONDataEarly(@[]);
            else if ([url containsString:@"genius.com/api"]) body = JSONDataEarly(@{ @"response": @{ @"sections": @[] } });
            else if ([url containsString:@"lyrics.ovh"]) { status = 404; body = [NSData data]; }
            else if ([url containsString:@"genius.com"]) { status = 404; body = [NSData data]; }
            else body = JSONDataEarly(@{});
        }
        Answer(r, c, p, status, nil, body);
    });
    CCWebLyrics *web = [[CCWebLyrics alloc] initWithConfiguration:StubConfiguration()];
    web.paced = NO;
    return [web find:path cancel:nil];
}

static void TestWebLyrics(void) {
    // Takes a song of his with that name.
    CCWebLyricsResult *r = Ask(@"Compilation/2. Unreleased Discography/x/Lost Control.mp3", ^NSData *(NSString *u, NSInteger *s) { return [u containsString:@"lrclib"] ? Lrclib(@"Juice WRLD", @"Lost Control") : nil; });
    EQUAL(r.match.source, @"LRCLIB");
    CHECK(r.match.fit == CCLyricsFitSameRecording, @"same recording");
    CHECK([[Requests()[0] valueForHTTPHeaderField:@"User-Agent"] hasPrefix:@"JuiceDownloader/"], @"user agent");

    // Refuses anything else on a finished song.
    NSArray *refused = @[ @[ @"Someone Else", @"Lost Control" ], @[ @"Juice WRLD", @"Lost Something" ], @[ @"Juice WRLD", @"Lost Control (Remix)" ],
                          @[ @"Juice WRLD", @"Lost Control (Snippet)" ], @[ @"Juice WRLD", @"Lost Control (Sessions)" ], @[ @"Genius Traductions", @"Lost Control (Traduction)" ] ];
    for (NSArray *pair in refused) {
        r = Ask(@"Lost Control.mp3", ^NSData *(NSString *u, NSInteger *s) { return [u containsString:@"lrclib"] ? Lrclib(pair[0], pair[1]) : nil; });
        CHECK(r.match == nil, @"took %@ - %@", pair[0], pair[1]);
        CHECK(r.closest.length > 0, @"closest for %@ - %@", pair[0], pair[1]);
    }

    // A session file prefers a page that says session.
    r = Ask(@"Session Edits/x/Lost Control [Session Edit].mp3", ^NSData *(NSString *u, NSInteger *s) {
        if (![u containsString:@"lrclib"]) return nil;
        return [u containsString:@"session"] ? Lrclib(@"Juice WRLD", @"Lost Control (Sessions)") : Lrclib(@"Juice WRLD", @"Lost Control");
    });
    EQUAL(r.match.title, @"Lost Control (Sessions)");
    CHECK(r.match.fit == CCLyricsFitSameRecording, @"session fit");

    // And is told when it only found the song.
    r = Ask(@"Session Edits/x/Lost Control [Session Edit].mp3", ^NSData *(NSString *u, NSInteger *s) { return [u containsString:@"lrclib"] ? Lrclib(@"Juice WRLD", @"Lost Control") : nil; });
    CHECK(r.match && r.match.fit == CCLyricsFitOtherRecording, @"other recording");

    // A named take refuses another take.
    r = Ask(@"Lost Control (v2).mp3", ^NSData *(NSString *u, NSInteger *s) { return [u containsString:@"lrclib"] ? Lrclib(@"Juice WRLD", @"Lost Control (v3)") : nil; });
    CHECK(r.match == nil, @"another take");

    // A named take is told when the page has only the song.
    r = Ask(@"Bad Boy (with Young Thug) [v5].mp3", ^NSData *(NSString *u, NSInteger *s) { return [u containsString:@"lrclib"] ? Lrclib(@"Juice WRLD", @"Bad Boy") : nil; });
    CHECK(r.match && r.match.fit == CCLyricsFitOtherRecording, @"a take with only the song");
    r = Ask(@"Lost Control (v2).mp3", ^NSData *(NSString *u, NSInteger *s) { return [u containsString:@"lyrics.ovh"] ? JSONDataEarly(@{ @"lyrics": kWords }) : nil; });
    CHECK(r.match && [r.match.source isEqualToString:@"lyrics.ovh"] && r.match.fit == CCLyricsFitOtherRecording, @"lyrics.ovh for a take");

    // Genius refusing this client is said, and its search is not asked again.
    Serve(^(NSURLRequest *rq, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        NSString *u = rq.URL.absoluteString;
        if ([u containsString:@"genius.com"]) Answer(rq, c, p, 403, nil, [NSData data]);
        else if ([u containsString:@"lrclib"]) Answer(rq, c, p, 200, nil, JSONDataEarly(@[]));
        else if ([u containsString:@"lyrics.ovh"]) Answer(rq, c, p, 404, nil, [NSData data]);
        else Answer(rq, c, p, 200, nil, JSONDataEarly(@{}));
    });
    CCWebLyrics *turnedAway = [[CCWebLyrics alloc] initWithConfiguration:StubConfiguration()];
    turnedAway.paced = NO;
    CCWebLyricsResult *firstAsk = [turnedAway find:@"One.mp3" cancel:nil];
    [turnedAway find:@"Two.mp3" cancel:nil];
    CHECK([firstAsk.failed.firstObject containsString:@"403"], @"403 not said: %@", firstAsk.failed);
    NSInteger searches = 0;
    for (NSURLRequest *rq in Requests()) searches += [rq.URL.absoluteString containsString:@"genius.com/api"];
    CHECK(searches == 1, @"Genius search asked %ld times", (long)searches);

    // Genius pages are read without their adverts.
    NSString *page = @"<div data-lyrics-container=\"true\" class=\"a\"><div data-exclude-from-selection=\"true\">ADVERT<div>inner</div></div>First line<br/>Second &amp; line<div><a href=\"#\">Third</a></div></div>\n<p>nope</p><div data-lyrics-container=\"true\">Fourth</div>";
    NSString *text = [CCWebLyrics geniusLyrics:page];
    CHECK([text hasPrefix:@"First line\nSecond & line"] && [text containsString:@"Third"] && [text hasSuffix:@"Fourth"], @"genius text: %@", text);
    CHECK(![text containsString:@"ADVERT"] && ![text containsString:@"inner"] && ![text containsString:@"nope"], @"genius kept: %@", text);
    NSData *search = JSONDataEarly(@{ @"response": @{ @"sections": @[ @{ @"hits": @[ @{ @"type": @"song", @"result": @{ @"url": @"https://genius.com/x-lyrics", @"title": @"Lost Control", @"artist_names": @"Juice WRLD" } } ] } ] } });
    NSData *geniusPage = [[NSString stringWithFormat:@"<div data-lyrics-container=\"true\">%@</div>", kWords] dataUsingEncoding:NSUTF8StringEncoding];
    r = Ask(@"Lost Control.mp3", ^NSData *(NSString *u, NSInteger *s) { return [u containsString:@"genius.com/api"] ? search : [u containsString:@"genius.com/x"] ? geniusPage : nil; });
    EQUAL(r.match.source, @"Genius");

    // When Genius turns requests away, its page is tried by address.
    r = Ask(@"Don't Go.mp3", ^NSData *(NSString *u, NSInteger *s) {
        if ([u containsString:@"genius.com/api"]) { *s = 429; return [NSData data]; }
        return [u hasSuffix:@"genius.com/Juice-wrld-dont-go-lyrics"] ? geniusPage : nil;
    });
    EQUAL(r.match.source, @"Genius");

    // A source that fails is named and the others still answer.
    r = Ask(@"Lost Control.mp3", ^NSData *(NSString *u, NSInteger *s) {
        if ([u containsString:@"lrclib"]) { *s = 500; return [NSData data]; }
        return [u containsString:@"lyrics.ovh"] ? JSONDataEarly(@{ @"lyrics": kWords }) : nil;
    });
    EQUAL(r.failed.firstObject, @"LRCLIB: replied 500");
    EQUAL(r.match.source, @"lyrics.ovh");

    // NetEase, through its two requests.
    r = Ask(@"Lost Control.mp3", ^NSData *(NSString *u, NSInteger *s) {
        if ([u containsString:@"163.com/api/search"]) return JSONDataEarly(@{ @"result": @{ @"songs": @[ @{ @"id": @7, @"name": @"Lost Control", @"artists": @[ @{ @"name": @"Juice WRLD" } ] } ] } });
        if ([u containsString:@"163.com/api/song/lyric"]) return JSONDataEarly(@{ @"lrc": @{ @"lyric": [NSString stringWithFormat:@"[00:01.00] %@", [kWords stringByReplacingOccurrencesOfString:@"\n" withString:@" "]] } });
        return nil;
    });
    EQUAL(r.match.source, @"NetEase");
    CHECK([r.match.synced hasPrefix:@"[00:01.00]these"], @"netease timing: %@", r.match.synced);

    // A site answering nonsense is a failed source, not a crash.
    r = Ask(@"Lost Control.mp3", ^NSData *(NSString *u, NSInteger *s) {
        if ([u containsString:@"lrclib"]) return [@"<html>" dataUsingEncoding:NSUTF8StringEncoding];
        if ([u containsString:@"genius.com/api"]) return JSONDataEarly(@{});
        return nil;
    });
    CHECK(r.match == nil && [r.failed.firstObject hasPrefix:@"LRCLIB"], @"nonsense: %@", r.failed);
    BOOL geniusSaid = NO;
    for (NSString *f in r.failed) geniusSaid |= [f hasPrefix:@"Genius"];
    CHECK(geniusSaid, @"an empty Genius answer is a failed source: %@", r.failed);
    r = Ask(@"Lost Control.mp3", ^NSData *(NSString *u, NSInteger *s) { return [u containsString:@"lrclib"] ? JSONDataEarly(@{}) : nil; });
    CHECK([r.failed.firstObject hasPrefix:@"LRCLIB"], @"an object from LRCLIB is a failed source: %@", r.failed);

    // Names and words are cleaned.
    EQUAL([CCWebLyrics bare:@"Light-Years (ft. Young Thug) [Session Edit].mp3"], @"Light-Years");
    EQUAL([CCWebLyrics bare:@"Too Smooth (v2).mp3"], @"Too Smooth");
    CHECK([CCWebLyrics tidy:@"[Instrumental]"] == nil, @"instrumental");
    CHECK([CCWebLyrics tidy:@"too short"] == nil, @"short");
    EQUAL([CCWebLyrics tidy:@"  a line that is long enough to count  \r\n\n\n\nnext "], @"a line that is long enough to count\n\nnext");
    NSString *plain, *timed;
    [CCWebLyrics neteaseWords:@"[00:00.00] 作词 : Someone\n[00:01.00] hello there" plain:&plain timed:&timed];
    EQUAL(plain, @"hello there");
    EQUAL(timed, @"[00:01.00]hello there");
    [CCWebLyrics neteaseWords:@"[00:00.00] 纯音乐，请欣赏" plain:&plain timed:&timed];
    EQUAL(plain, @"");
    EQUAL([CCWebLyrics slug:@"Juice WRLD Don't Go & Run"], @"Juice-wrld-dont-go-and-run");
    EQUAL([CCWebLyrics slug:@"Juice 日本語"], @"");
    CHECK(fabs([CCWebLyrics similarity:@"abcd" to:@"abce"] - 0.75) < 0.001, @"similarity");
    CHECK([CCWebLyrics similarity:@"" to:@"a"] == 0, @"similarity of nothing");
}

// ───────────── API client ─────────────

static NSData *JSONData(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }

static void TestApi(void) {
    [CCApiClient setVersion:@"9.9.9"];
    EQUAL(CCApiClient.userAgent, @"JuiceDownloader/9.9.9");
    EQUAL([CCApiClient downloadURL:@"A & B/c d.mp3"].absoluteString,
          @"https://juicewrldapi.com/juicewrld/files/download/?path=A%20%26%20B%2Fc%20d.mp3");

    // Songs are paged over https, whatever "next" says.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        BOOL firstPage = [r.URL.absoluteString containsString:@"page=1&"];
        id body = firstPage ? @{ @"count": @2, @"next": @"http://juicewrldapi.com/juicewrld/songs/?page=2", @"results": @[ @{ @"id": @1, @"name": @"a" } ] }
                            : @{ @"count": @2, @"next": NSNull.null, @"results": @[ @{ @"id": @2, @"name": @"b", @"lyrics": @"w", @"era": @{ @"name": @"OUT", @"description": @"Outsiders" } } ] };
        Answer(r, c, p, 200, nil, JSONData(body));
    });
    CCApiClient *api = [[CCApiClient alloc] initWithConfiguration:StubConfiguration()];
    api.pageDelay = 0;
    api.buildingDelay = 0;
    api.retryUnit = 0;
    NSMutableArray *progress = [NSMutableArray array];
    NSArray<CCSong *> *songs = [api fetchSongs:^(NSInteger done, NSInteger total) { [progress addObject:@[ @(done), @(total) ]]; } cancel:nil error:nil];
    CHECK(songs.count == 2, @"songs %lu", (unsigned long)songs.count);
    EQUAL(songs[1].eraName, @"OUT");
    EQUAL(progress.lastObject, (@[ @2, @2 ]));
    for (NSURLRequest *r in Requests()) {
        CHECK([r.URL.scheme isEqualToString:@"https"], @"not https: %@", r.URL);
        EQUAL([r valueForHTTPHeaderField:@"User-Agent"], @"JuiceDownloader/9.9.9");
    }
    CHECK(Requests().count == 2, @"pages");

    // The tree waits while the server builds it.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        id body = n == 1 ? @{ @"items": @[], @"building": @YES } : @{ @"items": @[ @{ @"path": @"a.mp3", @"type": @"file", @"size": @3 } ], @"total": @1 };
        Answer(r, c, p, 200, nil, JSONData(body));
    });
    NSArray<CCApiItem *> *items = [api fetchTree:nil error:nil];
    CHECK(items.count == 1 && items[0].size == 3, @"tree");
    CHECK(Requests().count == 2, @"building");

    // An empty catalog that is not building is an error, and a server error retries, then reports.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 200, nil, JSONData(@{ @"items": @[] })); });
    NSError *error = nil;
    CHECK([api fetchTree:nil error:&error] == nil && error != nil, @"empty catalog");
    error = nil;
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 503, nil, [NSData data]); });
    CHECK([api fetchTree:nil error:&error] == nil && error != nil, @"503");
    CHECK(Requests().count == 4, @"retries %lu", (unsigned long)Requests().count);
    error = nil;
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 403, nil, [NSData data]); });
    CHECK([api fetchTree:nil error:&error] == nil && [error.localizedDescription isEqualToString:@"HTTP 403"], @"403: %@", error);
    CHECK(Requests().count == 1, @"403 retried");

    [CCApiClient setVersion:@"1.0.0"];
}

// ───────────── cache ─────────────

static void TestCache(void) {
    NSString *dir = Scratch();
    CCCatalogCache *cache = [[CCCatalogCache alloc] initWithDirectory:Join(dir, @"cache")];
    CHECK([cache loadTree] == nil && cache.treeTime == nil, @"empty cache");
    [cache saveTree:@[ F(@"a/b.mp3", 5), [CCApiItem path:@"a" type:@"directory" size:0] ]];
    NSArray<CCApiItem *> *items = [cache loadTree];
    CHECK(items.count == 2 && items[0].size == 5 && items[1].isDirectory, @"tree round trip");
    CHECK(cache.treeTime != nil, @"tree time");

    // The same JSON as the C# cache: plain arrays with the API's own field names.
    NSArray *raw = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Join(dir, @"cache/catalog.json")] options:0 error:nil];
    EQUAL(raw[0], (@{ @"path": @"a/b.mp3", @"type": @"file", @"size": @5 }));

    CCSong *song = Song(@"la", @"[0:01.00] la");
    song.identifier = 7;
    song.path = @"p.mp3";
    song.eraName = @"OUT";
    song.eraDescription = @"Outsiders";
    song.trackTitles = @[ @"t" ];
    song.fileNames = @"f";
    [cache saveSongs:@[ song ]];
    NSArray *rawSongs = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Join(dir, @"cache/songs.json")] options:0 error:nil];
    for (NSString *key in @[ @"id", @"name", @"category", @"path", @"era", @"track_titles", @"file_names", @"lyrics", @"synced_lyrics" ])
        CHECK(rawSongs[0][key] != nil, @"song JSON has no %@", key);
    CCSong *back = [cache loadSongs].firstObject;
    CHECK(back.identifier == 7, @"id");
    EQUAL(back.eraDescription, @"Outsiders");
    EQUAL(back.trackTitles, @[ @"t" ]);
    EQUAL(back.syncedLyrics, @"[0:01.00] la");

    // A file the C# app wrote reads the same (null for missing fields, no era).
    NSData *csharp = Utf8(@"[{\"id\":1,\"name\":\"x\",\"category\":\"released\",\"path\":null,\"era\":null,\"track_titles\":null,\"file_names\":null,\"lyrics\":null,\"synced_lyrics\":null}]");
    [csharp writeToFile:Join(dir, @"cache/songs.json") atomically:NO];
    CCSong *other = [cache loadSongs].firstObject;
    CHECK(other && other.path == nil && other.eraName == nil && other.lyrics == nil, @"nulls");

    [Utf8(@"not json") writeToFile:Join(dir, @"cache/catalog.json") atomically:NO];
    CHECK([cache loadTree] == nil, @"damaged cache");
    [FM() removeItemAtPath:dir error:nil];
}

// ───────────── library ─────────────

static CCStubHandler ApiStub(void) {
    return ^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        NSString *url = r.URL.absoluteString;
        if ([url containsString:@"list-all"]) {
            Answer(r, c, p, 200, nil, JSONData(@{ @"items": @[ @{ @"path": @"A/Song One.mp3", @"type": @"file", @"size": @4 }, @{ @"path": @"A/Other.mp3", @"type": @"file", @"size": @4 } ] }));
        } else if ([url containsString:@"/songs/"]) {
            Answer(r, c, p, 200, nil, JSONData(@{ @"count": @1, @"next": NSNull.null, @"results": @[ @{ @"id": @1, @"name": @"Song One", @"category": @"unreleased", @"lyrics": @"la la", @"synced_lyrics": @"[0:01.00] la la" } ] }));
        } else {
            Answer(r, c, p, 200, nil, [NSData dataWithBytes:(const uint8_t[]){ 0xFF, 0xFB, 0x90, 0x00 } length:4]);
        }
    };
}

static CCLibrary *MakeLibrary(NSString *cache) {
    CCApiClient *api = [[CCApiClient alloc] initWithConfiguration:StubConfiguration()];
    api.pageDelay = 0;
    return [[CCLibrary alloc] initWithApi:api engine:Engine() cache:[[CCCatalogCache alloc] initWithDirectory:cache]];
}

static void TestLibrary(void) {
    NSString *dir = Scratch();
    Serve(ApiStub());
    NSString *cache = Join(dir, @"cache"), *dest = Join(dir, @"music");

    // Selected files arrive with their lyrics and the catalog survives a restart.
    CCLibrary *library = MakeLibrary(cache);
    CHECK(![library loadCached], @"no cache yet");
    CHECK(library.catalogIsStale, @"no cache is stale");
    CHECK([library refresh:nil error:nil], @"refresh");
    CHECK(!library.catalogIsStale, @"just fetched");
    [CCCatalog select:library.catalog.root selected:YES];
    CCLyricsOptions *options = [CCLyricsOptions embed:YES sidecar:YES timedInTag:NO];
    CCLyricsIndex *index = [library ensureLyricsForce:NO progress:nil cancel:nil error:nil];
    CHECK(index.songCount == 1 && index.withLyrics == 1, @"index");
    CCDownloadReport *report = [library download:library.selectedDownloadFiles to:dest parallel:2 lyrics:index options:options progress:nil cancel:nil];
    CHECK(report.downloaded == 2, @"downloaded %ld: %@", (long)report.downloaded, report.failures);
    CHECK(Has(Join(dest, @"A/Song One.mp3")), @"no words in the tag");
    EQUAL(TextOf(Join(dest, @"A/Song One.lrc")), @"[00:01.00]la la\n");
    CHECK(!Has(Join(dest, @"A/Other.mp3")), @"words on the wrong song");
    CCLibrary *again = MakeLibrary(cache);
    CHECK([again loadCached] && again.catalog.totalFiles == 2, @"restart");
    CHECK([again loadCachedLyrics] && again.lyrics.songCount == 1, @"songs from the cache");

    // Lyrics come from the cache without a request, however old it is; forcing asks again.
    Serve(ApiStub());
    [NSFileManager.defaultManager setAttributes:@{ NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-400 * 24 * 3600] } ofItemAtPath:Join(cache, @"songs.json") error:nil];
    [again ensureLyricsForce:NO progress:nil cancel:nil error:nil];
    CHECK(Requests().count == 0, @"a kept copy must not ask, even a year later");
    [again ensureLyricsForce:YES progress:nil cancel:nil error:nil];
    CHECK(Requests().count == 1, @"force must ask");
    // Only a different number of songs on the server sends the app back for the words.
    CHECK(![again lyricsChangedOnServer], @"same count, nothing new");
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        Answer(r, c, p, 200, nil, JSONData(@{ @"count": @2, @"next": NSNull.null, @"results": @[] }));
    });
    CHECK([again lyricsChangedOnServer], @"a new song must be noticed");
    // Offline with an old copy, the old copy is used.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        [c URLProtocol:p didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
    });
    again.api.retryUnit = 0;
    CHECK([again ensureLyricsForce:YES progress:nil cancel:nil error:nil] != nil, @"old words are better than a failed run");
    CCLibrary *nothing = MakeLibrary(Join(dir, @"nothing"));
    nothing.api.retryUnit = 0;
    NSError *error = nil;
    CHECK([nothing ensureLyricsForce:NO progress:nil cancel:nil error:&error] == nil && error != nil, @"no cache, no network");

    // A folder on disk gets lyrics and says what it could not place.
    Serve(ApiStub());
    NSString *music = Join(dir, @"mine");
    [FM() createDirectoryAtPath:Join(music, @"sub") withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *frame = [NSData dataWithBytes:(const uint8_t[]){ 0xFF, 0xFB } length:2];
    [frame writeToFile:Join(music, @"sub/song one (Session Edit).mp3") atomically:NO];
    [frame writeToFile:Join(music, @"nothing.mp3") atomically:NO];
    [frame writeToFile:Join(music, @"cover.jpg") atomically:NO];
    CCLibrary *folderLibrary = MakeLibrary(Join(dir, @"c"));
    folderLibrary.api.pageDelay = 0;
    NSMutableArray *names = [NSMutableArray array];
    CCLyricsRunReport *run = [folderLibrary addLyricsToFolder:music options:[CCLyricsOptions embed:YES sidecar:NO timedInTag:NO]
                                                     progress:^(NSInteger done, NSInteger total, NSString *name) { [names addObject:name]; } cancel:nil error:nil];
    CHECK(run.written == 1 && run.notFound == 1, @"folder: %ld written, %ld missing", (long)run.written, (long)run.notFound);
    EQUAL(run.missing, @[ @"nothing.mp3" ]);
    CHECK(names.count == 2, @"progress names %@", names);
    CHECK(Has(Join(music, @"sub/song one (Session Edit).mp3")), @"folder words");
    run = [folderLibrary addLyricsToFolder:music options:[CCLyricsOptions embed:YES sidecar:NO timedInTag:NO] progress:nil cancel:nil error:nil];
    CHECK(run.written == 0 && run.alreadyThere == 1, @"second run");
    CCCancel *stopped = [CCCancel new];
    [stopped cancel];
    run = [folderLibrary addLyricsToFolder:music options:[CCLyricsOptions embed:YES sidecar:NO timedInTag:NO] progress:nil cancel:stopped error:nil];
    CHECK(run.stopped && run.written == 0, @"stop");

    // A refresh keeps the selection; retry keeps only what failed.
    CCLibrary *keep = MakeLibrary(Join(dir, @"c2"));
    [keep refresh:nil error:nil];
    __block CCCatalogNode *first = nil, *second = nil;
    [keep.catalog.root forEachFile:^(CCCatalogNode *f) { if (!first) first = f; else second = f; }];
    [CCCatalog select:first selected:YES];
    [keep refresh:nil error:nil];
    CHECK(keep.catalog.selectedFiles == 1, @"selection through a refresh");
    EQUAL(keep.catalog.selectedFilesList[0].path, first.path);
    [CCCatalog select:keep.catalog.root selected:YES];
    [keep keepOnlySelected:@[ first.path ]];
    CHECK(keep.catalog.selectedFiles == 1, @"keep only");
    EQUAL(keep.catalog.selectedFilesList[0].path, first.path);

    // What is still needed.
    NSString *need = Join(dir, @"need");
    [FM() createDirectoryAtPath:need withIntermediateDirectories:YES attributes:nil error:nil];
    [Bytes(10) writeToFile:Join(need, @"whole.mp3") atomically:NO];
    [Bytes(4) writeToFile:Join(need, @"half.mp3.part") atomically:NO];
    long long needed = [CCLibrary bytesStillNeeded:@[ DF(@"whole.mp3", 10), DF(@"half.mp3", 10), DF(@"new.mp3", 10) ] under:need];
    CHECK(needed == 16, @"needed %lld", needed);

    // Gaps: what the API can fill is filled; instrumentals are no gaps; files with words are fine; the rest go to the web.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        NSString *url = r.URL.absoluteString;
        if ([url containsString:@"/songs/"]) {
            Answer(r, c, p, 200, nil, JSONData(@{ @"count": @2, @"next": NSNull.null, @"results": @[
                @{ @"id": @1, @"name": @"Song One", @"category": @"unreleased", @"lyrics": @"la la" },
                @{ @"id": @2, @"name": @"Song Two", @"category": @"released", @"lyrics": @"finished words" } ] }));
        } else if ([url containsString:@"lrclib"]) {
            NSString *wanted = [url containsString:@"Unknown"] ? @"Unknown Song" : @"Song Two (Sessions)";
            Answer(r, c, p, 200, nil, JSONData(@[ @{ @"artistName": @"Juice WRLD", @"trackName": wanted, @"plainLyrics": @"these are enough words to count as a real song", @"syncedLyrics": @"" } ]));
        } else if ([url containsString:@"genius.com/api"]) {
            Answer(r, c, p, 200, nil, JSONData(@{ @"response": @{ @"sections": @[] } }));
        } else {
            Answer(r, c, p, [url containsString:@"genius"] || [url containsString:@"ovh"] ? 404 : 200, nil, JSONData(@{}));
        }
    });
    NSString *gapDir = Join(dir, @"gaps");
    [FM() createDirectoryAtPath:Join(gapDir, @"Instrumentals") withIntermediateDirectories:YES attributes:nil error:nil];
    [frame writeToFile:Join(gapDir, @"Song One.mp3") atomically:NO];
    [frame writeToFile:Join(gapDir, @"Song Two [Session Edit].mp3") atomically:NO];
    [frame writeToFile:Join(gapDir, @"Unknown Song.mp3") atomically:NO];
    [frame writeToFile:Join(gapDir, @"Has A File.mp3") atomically:NO];
    [Bytes(3) writeToFile:Join(gapDir, @"Has A File.txt") atomically:NO];
    [frame writeToFile:Join(gapDir, @"Instrumentals/Song One.mp3") atomically:NO];
    [frame writeToFile:Join(gapDir, @"cover.jpg") atomically:NO];
    CCLibrary *gapLibrary = MakeLibrary(Join(dir, @"c3"));
    CCLyricsOptions *gapOptions = [CCLyricsOptions embed:YES sidecar:NO timedInTag:NO];
    CCLyricsGapScan *scan = [gapLibrary scanForGaps:gapDir options:gapOptions progress:nil cancel:nil error:nil];
    CHECK(scan.files == 5 && scan.fine == 3 && scan.gaps.count == 2, @"scan: %ld files, %ld fine, %lu gaps", (long)scan.files, (long)scan.fine, (unsigned long)scan.gaps.count);
    CHECK(Has(Join(gapDir, @"Song One.mp3")), @"the scan writes what the API has");
    CCLyricsGap *other = nil, *none = nil;
    for (CCLyricsGap *g in scan.gaps) {
        if (g.kind == CCLyricsGapOtherRecording) other = g;
        else none = g;
    }
    EQUAL(other.relative, @"Song Two [Session Edit].mp3");
    EQUAL(other.hasWordsOf, @"Song Two");
    EQUAL(none.relative, @"Unknown Song.mp3");
    CHECK(Contains([NSData dataWithContentsOfFile:other.file], Utf16(@"finished words")), @"the nearest words went on meanwhile");
    CCWebLyrics *web = [[CCWebLyrics alloc] initWithConfiguration:StubConfiguration()];
    web.paced = NO;
    NSMutableArray *live = [NSMutableArray array];
    NSArray *results = [gapLibrary searchWeb:scan.gaps web:web options:gapOptions progress:^(CCLyricsGapResult *result) { @synchronized (live) { [live addObject:result]; } } cancel:nil];
    CHECK(results.count == 2 && live.count == 2, @"search results %lu", (unsigned long)results.count);
    for (CCLyricsGapResult *result in results) {
        CHECK(result.written == CCLyricsResultWritten, @"%@ not written: %@ %@", result.gap.relative, result.found.match, result.found.failed);
    }
    CHECK(Contains([NSData dataWithContentsOfFile:other.file], Utf16(@"enough words")) && !Contains([NSData dataWithContentsOfFile:other.file], Utf16(@"finished words")), @"the session's words replace the song's");
    CCLyricsGapScan *again2 = [gapLibrary scanForGaps:gapDir options:gapOptions progress:nil cancel:nil error:nil];
    CHECK(again2.gaps.count == 1 && again2.gaps[0].kind == CCLyricsGapOtherRecording, @"filled: %lu gaps left", (unsigned long)again2.gaps.count);
    CCCancel *stopScan = [CCCancel new];
    [stopScan cancel];
    NSError *scanError = nil;
    CHECK([gapLibrary scanForGaps:gapDir options:gapOptions progress:nil cancel:stopScan error:&scanError] == nil && scanError.code == CCErrorCancelled, @"scan stops");
    CHECK([gapLibrary searchWeb:scan.gaps web:web options:gapOptions progress:nil cancel:stopScan].count == 0, @"search stops");

    // The last download's lyrics, by how well they fit.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 200, nil, frame); });
    CCSong *lastSong = Song(@"la", nil);
    lastSong.identifier = 1;
    lastSong.name = @"Song One";
    CCLibrary *lastLibrary = MakeLibrary(Join(dir, @"c4"));
    CCLyricsIndex *lastIndex = [[CCLyricsIndex alloc] initWithSongs:@[ lastSong ]];
    [lastLibrary download:@[ DF(@"A/Song One.mp3", 2), DF(@"A/Song One [Session Edit].mp3", 2), DF(@"A/Nobody.mp3", 2), DF(@"Instrumentals/Song One.mp3", 2), DF(@"A/art.jpg", 2) ]
                       to:Join(dir, @"last") parallel:2 lyrics:lastIndex options:gapOptions progress:nil cancel:nil];
    CHECK(lastLibrary.lastLyricsSame == 1 && lastLibrary.lastLyricsOther == 1 && lastLibrary.lastLyricsNone == 1, @"last lyrics %ld %ld %ld", (long)lastLibrary.lastLyricsSame, (long)lastLibrary.lastLyricsOther, (long)lastLibrary.lastLyricsNone);

    // Playable, wanted, and a copy to play.
    CHECK([CCLibrary isPlayable:@"a.MP3"] && ![CCLibrary isPlayable:@"a.mov"] && ![CCLibrary isPlayable:@"a.mp4"] && ![CCLibrary isPlayable:@"a.zip"] && ![CCLibrary isPlayable:@"a.jpg"], @"playable is audio only");
    CHECK([CCLibrary previewOf:@"a.JPG"] == CCPreviewImage && [CCLibrary previewOf:@"a.png"] == CCPreviewImage && [CCLibrary previewOf:@"a.tiff"] == CCPreviewImage, @"images");
    CHECK([CCLibrary previewOf:@"a.mp4"] == CCPreviewVideo && [CCLibrary previewOf:@"a.MKV"] == CCPreviewVideo && [CCLibrary previewOf:@"a.webm"] == CCPreviewVideo, @"videos");
    CHECK([CCLibrary previewOf:@"a.txt"] == CCPreviewText && [CCLibrary previewOf:@"a.lrc"] == CCPreviewText && [CCLibrary previewOf:@"a.ini"] == CCPreviewText, @"texts");
    CHECK([CCLibrary previewOf:@"a.mp3"] == CCPreviewNone && [CCLibrary previewOf:@"a.zip"] == CCPreviewNone && [CCLibrary previewOf:@"a"] == CCPreviewNone, @"nothing to show");
    CHECK([CCLibrary wantsLyrics:@"a.wav"] && [CCLibrary wantsLyrics:@"Studio Sessions/x/a.ZIP"] && ![CCLibrary wantsLyrics:@"Others/a.zip"] && ![CCLibrary wantsLyrics:@"a.mp4"], @"wants lyrics");
    NSString *copies = Join(dir, @"copies");
    [FM() createDirectoryAtPath:Join(copies, @"A") withIntermediateDirectories:YES attributes:nil error:nil];
    [Bytes(4) writeToFile:Join(copies, @"A/here.mp3") atomically:NO];
    [Bytes(2) writeToFile:Join(copies, @"A/short.wav") atomically:NO];
    CCCatalog *copyCatalog = [CCCatalog build:@[ F(@"A/here.mp3", 4), F(@"A/gone.mp3", 4), F(@"A/short.wav", 4) ]];
    CCCatalogNode *folderNode = copyCatalog.root.children[0];
    {
        NSArray *some = @[ [CCDownloadFile path:@"A/b song.mp3" size:1], [CCDownloadFile path:@"B/a song.wav" size:1], [CCDownloadFile path:@"C/c song.mp3" size:1] ];
        EQUAL([CCSongRules listOf:some], @"a song\nb song\nc song");
        CHECK([CCSongRules listOf:@[]] == nil, @"nothing to list");
    }
    {
        CCCatalog *albums = [CCCatalog build:@[ F(@"Compilation/1. Released Discography/22. The Party Never Ends/Misfit.mp3", 4), F(@"Compilation/1. Released Discography/22. The Party Never Ends/CD2/Goodbye.mp3", 5) ]];
        CCCatalogNode *album = albums.root.children[0].children[0].children[0];
        NSArray *targets = [[CCLibrary albumFiles:album] valueForKey:@"target"];
        EQUAL([NSSet setWithArray:targets], ([NSSet setWithArray:@[ @"The Party Never Ends/Misfit.mp3", @"The Party Never Ends/CD2/Goodbye.mp3" ]]));
        CHECK(![CCCatalog.ruleSectionIds containsObject:@"snippets"] && ![CCCatalog.ruleSectionIds containsObject:@"media"] && [CCCatalog.ruleSectionIds containsObject:@"unofficial"], @"rule sections");
    }
    EQUAL([CCLibrary localCopy:folderNode.children[1] under:copies], Join(copies, @"A/here.mp3"));
    CHECK([CCLibrary localCopy:folderNode.children[0] under:copies] == nil, @"no copy, stream it");
    CHECK([CCLibrary localCopy:folderNode.children[2] under:copies] == nil, @"a short copy does not count");

    CHECK([CCLibrary isAudio:@"a.MP3"] && [CCLibrary isAudio:@"a.aiff"] && ![CCLibrary isAudio:@"a.jpg"] && ![CCLibrary isAudio:@"a.mp3.part"], @"audio");
    [FM() removeItemAtPath:dir error:nil];
}

// ───────────── rules ─────────────

static NSString *const kU = @"Compilation/2. Unreleased Discography/8. WRLD ON DRUGS (Sessions)/";

static CCSong *RuleSong(NSString *name, NSString *leak, NSString *lyrics, NSString *category, NSArray *titles) {
    static long long nextId = 1;
    CCSong *s = [CCSong new];
    s.identifier = nextId++;
    s.name = name;
    s.category = category;
    s.path = [category isEqualToString:@"unreleased"] ? [NSString stringWithFormat:@"%@%@.mp3", kU, name] : [NSString stringWithFormat:@"Compilation/1. Released Discography/%@.mp3", name];
    s.leakType = leak;
    s.lyrics = lyrics;
    s.length = @"3:00";
    s.trackTitles = [@[ name ] arrayByAddingObjectsFromArray:titles ?: @[]];
    return s;
}

static CCCatalog *RuleCatalog(NSArray<CCSong *> *songs) {
    NSMutableArray *items = [NSMutableArray array];
    for (CCSong *s in songs) [items addObject:F(s.path, 7200000)];
    return [CCCatalog build:items];
}

static void TestUnofficialRelease(void) {
    // Filed under released in the Compilations folder, but its leak type says unofficial: it goes with the unreleased.
    CCSong *leaked = RuleSong(@"For You", @"Unofficial EP Track", @"", @"released", nil);
    leaked.path = @"Compilation/3. Misc. Discography/4. Whatever, They Leaked Already/For You.mp3";
    CCSong *mix = RuleSong(@"Big (TV Mix)", @"Misc. Track", @"", @"released", nil);
    mix.path = @"Compilation/3. Misc. Discography/3. Death Race For Love (Television Mixes)/Big (TV Mix).mp3";
    CCSong *album = RuleSong(@"Big", @"Album Track", @"", @"released", nil);
    album.path = @"Compilation/1. Released Discography/5. Fighting Demons/Big.mp3";
    NSArray *songs = @[ leaked, mix, album ];
    CCCatalog *c = [CCCatalog build:@[ F(leaked.path, 7200000), F(mix.path, 7200000), F(album.path, 7200000), F(@"Remixes & Edits/Tracks/New One (Prod. Someone).mp3", 7200000), F(@"Remixes & Edits/Instrumental/Other Song.mp3", 7200000) ]];
    CCRuleOptions *unreleased = [CCRuleOptions new];
    unreleased.sections = @[ @"unreleased", @"sessionEdits" ];
    EQUAL([[CCSongRules apply:c songs:songs options:unreleased].kept valueForKeyPath:@"picked.file.name"], @[ @"For You.mp3" ]);
    unreleased.sections = @[ @"unreleased", @"sessionEdits", @"remixes" ];
    NSArray *names = [[[CCSongRules apply:c songs:songs options:unreleased].kept valueForKeyPath:@"picked.file.name"] sortedArrayUsingSelector:@selector(compare:)];
    EQUAL(names, (@[ @"For You.mp3", @"New One (Prod. Someone).mp3" ]));
    unreleased.skipReleased = YES;
    CHECK([CCSongRules apply:c songs:songs options:unreleased].kept.count == 2, @"an unofficial song is no released song");
    CCRuleOptions *released = [CCRuleOptions new];
    released.sections = @[ @"albums", @"compilations" ];
    CHECK(![[[CCSongRules apply:c songs:songs options:released].kept valueForKeyPath:@"picked.file.name"] containsObject:@"For You.mp3"], @"an unofficial song is not among the released");
}

static void TestSongRules(void) {
    TestUnofficialRelease();
    // One song keeps its most finished take.
    NSArray *songs = @[ RuleSong(@"Bad Boy (with Young Thug) [v1]", @"Original Demo Track (Open Verse)", @"words", @"unreleased", nil),
                        RuleSong(@"Bad Boy (with Young Thug) [v2]", @"Alternate Demo Track (Completed)", @"words", @"unreleased", nil),
                        RuleSong(@"Bad Boy (with Young Thug) [v3]", @"Alternate Demo Track", @"", @"unreleased", nil),
                        RuleSong(@"Other Song", @"Throwaway Track (Complete)", @"words", @"unreleased", nil) ];
    CCRuleOptions *options = [CCRuleOptions new];
    CCRuleResult *r = [CCSongRules apply:RuleCatalog(songs) songs:songs options:options];
    CHECK(r.kept.count == 2 && r.skippedVersions == 2, @"takes: %lu kept, %ld skipped", (unsigned long)r.kept.count, (long)r.skippedVersions);
    for (CCSongGroup *g in r.kept)
        if (g.versions.count == 3) CHECK([g.picked.file.name containsString:@"[v2]"], @"picked %@", g.picked.file.name);
    CHECK(r.bytes == 2 * 7200000, @"bytes of what is picked");
    CHECK(r.filesConsidered == 4, @"files considered");

    // A remix or a part two is its own song.
    songs = @[ RuleSong(@"Song", @"Throwaway Track", @"", @"unreleased", nil), RuleSong(@"Song (Remix)", @"Throwaway Track", @"", @"unreleased", nil), RuleSong(@"Song (Pt. 2)", @"Throwaway Track", @"", @"unreleased", nil) ];
    CHECK([CCSongRules apply:RuleCatalog(songs) songs:songs options:options].kept.count == 3, @"own songs");

    // Songs that came out and unfinished ones are left out unless wanted.
    songs = @[ RuleSong(@"Lucid Dreams (v1)", @"Original Demo Track", @"", @"unreleased", nil), RuleSong(@"Lucid Dreams", @"Single", @"", @"released", nil),
               RuleSong(@"Hooky", @"Throwaway Track (Hook Only)", @"", @"unreleased", nil), RuleSong(@"Keep", @"Throwaway Track", @"", @"unreleased", nil) ];
    CCRuleOptions *strict = [CCRuleOptions new];
    strict.skipReleased = YES;
    strict.skipUnfinished = YES;
    r = [CCSongRules apply:RuleCatalog(songs) songs:songs options:strict];
    CHECK(r.kept.count == 1 && [r.kept[0].title isEqualToString:@"Keep"], @"kept %@", [r.kept valueForKey:@"title"]);
    CHECK(r.skippedReleased == 1 && r.skippedUnfinished == 1, @"skipped %ld %ld", (long)r.skippedReleased, (long)r.skippedUnfinished);
    CCRuleOptions *allOfIt = [CCRuleOptions new];
    allOfIt.skipReleased = NO;
    CHECK([CCSongRules apply:RuleCatalog(songs) songs:songs options:allOfIt].kept.count == 3, @"all of it");
    NSArray *eraSongs = @[ RuleSong(@"AGATS 999", @"Unofficial EP Track", @"", @"unreleased", nil), RuleSong(@"AGATS", @"Single", @"", @"released", nil), RuleSong(@"Keep", @"Throwaway Track", @"", @"unreleased", nil) ];
    CCRuleResult *era = [CCSongRules apply:RuleCatalog(eraSongs) songs:eraSongs options:[CCRuleOptions new]];
    CHECK(![[era.kept valueForKey:@"title"] containsObject:@"AGATS 999"], @"an EP track that came out later is left out: %@", [era.kept valueForKey:@"title"]);
    CCSong *tiny = RuleSong(@"Tiny", @"Throwaway Track", @"", @"unreleased", nil);
    tiny.length = @"0:44";
    NSArray *clips = @[ RuleSong(@"Big Bang (IG Live)", @"Throwaway Track", @"", @"unreleased", nil), RuleSong(@"Both Sides (Snipet)", @"Throwaway Track", @"", @"unreleased", nil), tiny, RuleSong(@"Live Forever", @"Throwaway Track", @"", @"unreleased", nil) ];
    EQUAL([[CCSongRules apply:RuleCatalog(clips) songs:clips options:[CCRuleOptions new]].kept valueForKey:@"title"], @[ @"Live Forever" ]);
    CCSong *chef = RuleSong(@"Chef Juice", @"Throwaway Track", @"", @"unreleased", nil), *hocus = RuleSong(@"Hocus Pocus", @"Throwaway Track", @"", @"unreleased", nil), *known = RuleSong(@"Known", @"Throwaway Track", @"", @"unreleased", nil);
    known.length = @"0:50";
    chef.length = hocus.length = nil;
    CCCatalog *small = [CCCatalog build:@[ F(chef.path, 195752), F(hocus.path, 786179), F(known.path, 300000) ]];
    NSArray *smallSongs = @[ chef, hocus, known ];
    EQUAL([[CCSongRules apply:small songs:smallSongs options:[CCRuleOptions new]].kept valueForKey:@"title"], (@[ @"Hocus Pocus", @"Known" ]));
    // With clips wanted: every live, snippet and short bit, each its own, in a folder of their own; and a live refused by hand too.
    CCSong *lucid = RuleSong(@"Lucid Dreams (Live)", @"Throwaway Track", @"", @"unreleased", nil), *daniel = RuleSong(@"Daniel Live 1", @"Throwaway Track", @"", @"unreleased", nil);
    NSArray *withLives = [clips arrayByAddingObjectsFromArray:@[ lucid, daniel, RuleSong(@"Lucid Dreams", @"Single", @"", @"released", nil) ]];
    CCRuleOptions *clipsToo = [CCRuleOptions new];
    clipsToo.withClips = YES;
    clipsToo.clipPaths = @[ daniel.path ];
    clipsToo.neverOffer = @[ daniel.path ];
    CCRuleResult *lives = [CCSongRules apply:RuleCatalog(withLives) songs:withLives options:clipsToo];
    EQUAL([lives.kept valueForKey:@"title"], (@[ @"Big Bang (IG Live)", @"Both Sides (Snipet)", @"Daniel Live 1", @"Live Forever", @"Lucid Dreams (Live)", @"Tiny" ]));
    NSMutableArray *targets = [NSMutableArray array];
    for (CCDownloadFile *f in [CCSongRules files:lives.kept options:clipsToo]) [targets addObject:f.target.stringByDeletingLastPathComponent];
    EQUAL(targets, (@[ @"IG Lives & Clips", @"IG Lives & Clips", @"IG Lives & Clips", @"Unreleased", @"IG Lives & Clips", @"IG Lives & Clips" ]));
    clipsToo.withClips = NO;
    EQUAL([[CCSongRules apply:RuleCatalog(withLives) songs:withLives options:clipsToo].kept valueForKey:@"title"], @[ @"Live Forever" ]);
    CCRuleOptions *refused = [CCRuleOptions new];
    refused.neverOffer = [[[CCSongRules files:r.kept options:strict] valueForKey:@"apiPath"] copy];
    CHECK(![[[CCSongRules apply:RuleCatalog(songs) songs:songs options:refused].kept valueForKey:@"title"] containsObject:@"Keep"], @"a refused file is not offered");

    // The defaults, and every session edit stays beside the finished song: its own group, never a released song.
    CCRuleOptions *defaults = [CCRuleOptions new];
    EQUAL(defaults.sections, (@[ @"unreleased", @"sessionEdits" ]));
    CHECK(defaults.skipReleased && !defaults.skipUnfinished && defaults.oneVersion && defaults.oneFolder, @"default rules");
    CCCatalog *withSessions = [CCCatalog build:@[ F([kU stringByAppendingString:@"734.mp3"], 5000000), F(@"Session Edits/7. X (Sessions)/734 [Session Edit].mp3", 5000000), F(@"Session Edits/7. X (Sessions)/734 (ft. A) [Session Edit].mp3", 5000000) ]];
    CCRuleResult *sessions = [CCSongRules apply:withSessions songs:@[] options:defaults];
    CHECK(sessions.kept.count == 3 && sessions.skippedVersions == 0, @"sessions: %lu groups", (unsigned long)sessions.kept.count);
    CCSong *cameOut = RuleSong(@"734", @"Single", @"", @"released", nil);
    CCRuleResult *strictSessions = [CCSongRules apply:withSessions songs:@[ cameOut ] options:strict];
    CHECK(strictSessions.kept.count == 2 && strictSessions.skippedReleased == 1, @"a session file is no released song: %lu kept, %ld skipped", (unsigned long)strictSessions.kept.count, (long)strictSessions.skippedReleased);

    // Every take as its own row without One version.
    songs = @[ RuleSong(@"Take [v1]", @"Throwaway Track", @"", @"unreleased", nil), RuleSong(@"Take [v2]", @"Throwaway Track", @"", @"unreleased", nil) ];
    CCRuleOptions *every = [CCRuleOptions new];
    every.oneVersion = NO;
    CHECK([CCSongRules apply:RuleCatalog(songs) songs:songs options:every].kept.count == 2, @"every take");

    // Another title is the same song only when the words agree.
    NSString *words = @"first long line of the song\nsecond long line of the song\nthird long line of the song";
    songs = @[ RuleSong(@"Late Night", @"Throwaway Track", words, @"unreleased", @[ @"Wake Up" ]), RuleSong(@"Wake Up", @"Throwaway Track", words, @"unreleased", nil),
               RuleSong(@"Lonely Road", @"Throwaway Track", @"some other verse entirely here", @"unreleased", @[ @"By Myself" ]), RuleSong(@"By Myself", @"Throwaway Track", words, @"unreleased", nil) ];
    CHECK([CCSongRules apply:RuleCatalog(songs) songs:songs options:options].kept.count == 3, @"titles merge by words");

    // One folder keeps names apart.
    songs = @[ RuleSong(@"A (v1)", @"Throwaway Track", @"", @"unreleased", nil), RuleSong(@"B", @"Throwaway Track", @"", @"unreleased", nil) ];
    CCRuleOptions *picked = [CCRuleOptions new];
    picked.folderName = @"Picked";
    NSArray<CCDownloadFile *> *files = [CCSongRules files:[CCSongRules apply:RuleCatalog(songs) songs:songs options:picked].kept options:picked];
    for (CCDownloadFile *f in files) CHECK([f.target hasPrefix:@"Picked/"], @"target %@", f.target);
    CCCatalog *same = [CCCatalog build:@[ F(@"x/a.mp3", 2), F(@"y/A.MP3", 2) ]];
    NSMutableArray *clash = [NSMutableArray array];
    [same.root forEachFile:^(CCCatalogNode *file) {
        CCSongVersion *v = [CCSongVersion new];
        v.file = file;
        CCSongGroup *g = [CCSongGroup new];
        g.picked = v;
        [clash addObject:g];
    }];
    NSArray<CCDownloadFile *> *apart = [CCSongRules files:clash options:picked];
    EQUAL(apart[0].target, @"Picked/a.mp3");
    EQUAL(apart[1].target, @"Picked/A 2.MP3");
    CCRuleOptions *byEra = [CCRuleOptions new];
    byEra.oneFolder = NO;
    CHECK([CCSongRules files:clash options:byEra][0].target == nil, @"no target without one folder");

    // A target decides where the file lands.
    NSString *dir = Scratch();
    Serve(^(NSURLRequest *r2, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r2, c, p, 200, nil, Bytes(10)); });
    CCDownloadOptions *to = Options(dir);
    CCDownloadReport *report = [Engine() run:@[ [CCDownloadFile path:@"deep/in/x.mp3" size:10 target:@"Picked/x.mp3"] ] options:to progress:nil cancel:nil];
    CHECK(report.downloaded == 1 && Exists(Join(dir, @"Picked/x.mp3")) && !Exists(Join(dir, @"deep/in/x.mp3")), @"target ignored");
    CHECK([Requests()[0].URL.absoluteString containsString:@"path=deep%2Fin%2Fx.mp3"], @"asked for the wrong file");
    CHECK([CCLibrary bytesStillNeeded:@[ [CCDownloadFile path:@"deep/in/x.mp3" size:10 target:@"Picked/x.mp3"] ] under:dir] == 0, @"needed goes by target");
    [FM() removeItemAtPath:dir error:nil];

    // Relations: the same song in other trees; Place reads without the ordering numbers; Reveal opens the way.
    CCCatalog *c = [CCCatalog build:@[ F(@"Compilation/2. Unreleased Discography/8. WOD (Sessions)/Tune (v1).mp3", 1), F(@"Original Files/8. WOD (Sessions)/Tune.wav", 1),
                                       F(@"Snippets/Tune/Tune.zip", 1), F(@"Compilation/2. Unreleased Discography/8. WOD (Sessions)/Other.mp3", 1), F(@"Others/tune.txt", 1) ]];
    CCCatalogRelations *relations = [[CCCatalogRelations alloc] initWithCatalog:c];
    __block CCCatalogNode *first = nil;
    [[c section:@"unreleased"].rows.firstObject forEachFile:^(CCCatalogNode *f) { if ([f.name hasPrefix:@"Tune"]) first = f; }];
    NSArray *others = [[relations of:first] valueForKey:@"path"];
    CHECK(others.count == 2 && [others containsObject:@"Original Files/8. WOD (Sessions)/Tune.wav"] && [others containsObject:@"Snippets/Tune/Tune.zip"], @"also in: %@", others);
    EQUAL([CCCatalogRelations place:first], @"Compilation › Unreleased Discography › WOD (Sessions)");
    CCLibraryRows *rows = [[CCLibraryRows alloc] initWithSection:[c section:@"unreleased"]];
    rows.query = @"nothing";
    [rows reveal:first];
    EQUAL(rows.query, @"");
    CHECK([[rows.rows valueForKeyPath:@"node.path"] containsObject:first.path], @"reveal did not open the way");

    // The song's new fields survive the cache.
    CCSong *cached = [CCSong fromJSON:@{ @"id": @1, @"name": @"x", @"category": @"unreleased", @"leak_type": @"Single", @"length": @"3:15" }];
    EQUAL(cached.leakType, @"Single");
    EQUAL(cached.length, @"3:15");
    EQUAL(cached.JSON[@"leak_type"], @"Single");
    CHECK([CCSong fromJSON:cached.JSON].length.length == 4, @"round trip");

    // Rules through the library, with a cache from before them refetched.
    Serve(^(NSURLRequest *r2, NSInteger n, id<NSURLProtocolClient> client, NSURLProtocol *p) {
        NSString *url = r2.URL.absoluteString;
        if ([url containsString:@"list-all"]) Answer(r2, client, p, 200, nil, JSONData(@{ @"items": @[ @{ @"path": @"Compilation/2. Unreleased Discography/A/Fresh.mp3", @"type": @"file", @"size": @4 } ] }));
        else Answer(r2, client, p, 200, nil, JSONData(@{ @"count": @1, @"next": NSNull.null, @"results": @[ @{ @"id": @1, @"name": @"Fresh", @"category": @"unreleased", @"path": @"Compilation/2. Unreleased Discography/A/Fresh.mp3", @"leak_type": @"Throwaway Track", @"length": @"1:00" } ] }));
    });
    NSString *ruleCache = Scratch();
    CCLibrary *library = MakeLibrary(ruleCache);
    [library refresh:nil error:nil];
    CCCatalogCache *old = [[CCCatalogCache alloc] initWithDirectory:ruleCache];
    [old saveSongs:@[ Song(@"la", nil) ]];
    CCRuleResult *viaLibrary = [library applyRules:[CCRuleOptions new] cancel:nil error:nil];
    CHECK(viaLibrary.kept.count == 1 && [[old loadSongs].firstObject.leakType isEqualToString:@"Throwaway Track"], @"old cache refetched");
    [FM() removeItemAtPath:ruleCache error:nil];
}

// ───────────── audio copies ─────────────

static NSData *Tagged(NSUInteger tag, NSData *audio) {
    uint8_t h[10] = { 'I', 'D', '3', 3, 0, 0, 0, 0, (tag >> 7) & 127, tag & 127 };
    NSMutableData *d = [NSMutableData dataWithBytes:h length:10];
    [d increaseLengthBy:tag];
    [d appendData:audio];
    return d;
}

static void TestAudioCopies(void) {
    NSMutableData *sound = [NSMutableData dataWithLength:600000], *other = [NSMutableData dataWithLength:600000];
    for (NSUInteger i = 0; i < 600000; i++) {
        ((uint8_t *)sound.mutableBytes)[i] = (uint8_t)(i * 7);
        ((uint8_t *)other.mutableBytes)[i] = (uint8_t)(i * 7) ^ 1;
    }
    NSDictionary<NSString *, NSData *> *files = @{
        @"Session Edits/x/Break [Session Edit].mp3": Tagged(100, sound),
        @"Session Edits/x/On And On (Break) [Session Edit].mp3": Tagged(300, sound),
        @"Session Edits/x/Different [Session Edit].mp3": Tagged(100, other),
    };
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *path in files) [items addObject:F(path, (long long)files[path].length)];
    CCCatalog *catalog = [CCCatalog build:items];
    CCSong *song = Song(@"words", nil);
    song.identifier = 1;
    song.name = @"Break";
    song.category = @"recording_session";
    song.trackTitles = @[ @"Break", @"On And On", @"Different" ];
    __block BOOL fail = NO;
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) {
        if (fail) {
            Answer(r, c, p, 404, nil, [NSData data]);
            return;
        }
        NSString *query = r.URL.query;
        NSString *path = [[query substringFromIndex:@"path=".length] stringByRemovingPercentEncoding];
        NSData *all = files[path];
        long long from = 0, to = 0;
        sscanf([r valueForHTTPHeaderField:@"Range"].UTF8String, "bytes=%lld-%lld", &from, &to);
        NSData *part = [all subdataWithRange:NSMakeRange((NSUInteger)from, (NSUInteger)(to - from + 1))];
        Answer(r, c, p, 206, @{ @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lu", from, to, (unsigned long)all.length], @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)part.length] }, part);
    });
    CCApiClient *api = [[CCApiClient alloc] initWithConfiguration:StubConfiguration()];
    api.retryUnit = 0;
    CCCatalog *keepCatalog = catalog;
    CCRuleResult *result = [CCSongRules apply:keepCatalog songs:@[ song ] options:[CCRuleOptions new]];
    CCLyricsIndex *index = [[CCLyricsIndex alloc] initWithSongs:@[ song ]];
    NSMutableDictionary *same = [NSMutableDictionary dictionary];
    CCRuleResult *cleaned = [CCAudioCopies remove:result index:index api:api same:same cancel:nil];
    CHECK(cleaned.skippedCopies == 1 && cleaned.kept.count == 2, @"copies: %ld skipped, %lu kept", (long)cleaned.skippedCopies, (unsigned long)cleaned.kept.count);
    NSArray *names = [cleaned.kept valueForKeyPath:@"picked.file.name"];
    CHECK([names containsObject:@"Break [Session Edit].mp3"], @"the plainer name stays: %@", names);
    CHECK(![names containsObject:@"On And On (Break) [Session Edit].mp3"], @"the copy went: %@", names);
    CHECK(Requests().count < 20, @"%lu requests", (unsigned long)Requests().count);

    // A second run knows without asking, and the answers survive in the cache.
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 500, nil, [NSData data]); });
    cleaned = [CCAudioCopies remove:result index:index api:api same:same cancel:nil];
    CHECK(cleaned.skippedCopies == 1 && Requests().count == 0, @"remembered: %lu requests", (unsigned long)Requests().count);
    NSString *dir = Scratch();
    CCCatalogCache *cache = [[CCCatalogCache alloc] initWithDirectory:dir];
    CHECK([cache loadSameAudio].count == 0, @"nothing known yet");
    [cache saveSameAudio:same];
    EQUAL([cache loadSameAudio], same);
    NSDictionary *raw = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Join(dir, @"same-audio.json")] options:0 error:nil];
    CHECK(raw.count == same.count, @"same JSON as the other apps");
    [FM() removeItemAtPath:dir error:nil];

    // An answer that cannot be had keeps both.
    fail = YES;
    Serve(^(NSURLRequest *r, NSInteger n, id<NSURLProtocolClient> c, NSURLProtocol *p) { Answer(r, c, p, 404, nil, [NSData data]); });
    NSMutableDictionary *none = [NSMutableDictionary dictionary];
    cleaned = [CCAudioCopies remove:result index:index api:api same:none cancel:nil];
    CHECK(cleaned.skippedCopies == 0 && cleaned.kept.count == 3 && none.count == 0, @"unknown keeps both");
}

// ───────────── settings ─────────────

static void TestSettings(void) {
    NSString *dir = Scratch();
    NSString *path = Join(dir, @"sub/settings.json");
    setenv("JUICEDOWNLOADER_SETTINGS", path.fileSystemRepresentation, 1);
    EQUAL([CCSettings filePath], path);
    EQUAL([CCSettings cacheDirectory], Join(dir, @"sub/cache"));

    CCSettings *s = [CCSettings load];
    CHECK([s.destination hasSuffix:@"Music/Juice WRLD"], @"default folder: %@", s.destination);
    CHECK(s.parallel == 8 && s.confirmDownloads && s.refreshOnLaunch && !s.lyricsEnabled, @"defaults");
    CHECK(s.lyricsEmbed && s.lyricsSidecar && !s.lyricsTimedInTag && s.playerVolume == 0.8, @"defaults of the add-on and the player");
    CHECK(s.rulesSkipReleased && !s.rulesSkipUnfinished && !s.rulesWithClips && s.rulesOneVersion && s.rulesOneFolder, @"rule defaults follow RuleOptions");
    EQUAL(s.rulesSections, (@[ @"unreleased", @"sessionEdits" ]));
    s.destination = @"/tmp/x";
    s.parallel = 16;
    s.rulesOneFolder = NO;
    s.rulesSections = @[ @"albums", @"unreleased" ];
    s.playerVolume = 0.25;
    s.lyricsEnabled = YES;
    s.lyricsTimedInTag = YES;
    s.confirmDownloads = NO;
    s.theme = @"light";
    [s save];

    NSDictionary *raw = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
    NSArray *keys = @[ @"language", @"theme", @"animations", @"backdrop", @"destination", @"parallel", @"confirmDownloads", @"refreshOnLaunch",
                       @"lyricsEnabled", @"lyricsEmbed", @"lyricsSidecar", @"lyricsTimedInTag", @"playerVolume", @"rulesOneVersion", @"rulesSkipReleased", @"rulesSkipUnfinished", @"rulesOneFolder", @"rulesWithClips", @"rulesSections", @"rulesNeverOffer", @"rulesClipPaths", @"windowWidth", @"windowHeight", @"windowMaximized" ];
    EQUAL([NSSet setWithArray:raw.allKeys], [NSSet setWithArray:keys]);

    CCSettings *back = [CCSettings load];
    EQUAL(back.destination, @"/tmp/x");
    CHECK(back.playerVolume == 0.25, @"volume");
    CHECK(!back.rulesOneFolder && back.rulesOneVersion && back.rulesSections.count == 2, @"rules settings");
    CHECK(back.parallel == 16 && back.lyricsEnabled && back.lyricsTimedInTag && !back.confirmDownloads, @"round trip");
    EQUAL(back.theme, @"light");

    [JSONData(@{ @"parallel": @40, @"playerVolume": @7, @"destination": @"", @"theme": @3 }) writeToFile:path atomically:NO];
    CCSettings *odd = [CCSettings load];
    CHECK(odd.parallel == 32, @"parallel clamped: %ld", (long)odd.parallel);
    CHECK(odd.playerVolume == 1, @"volume clamped");
    CHECK([odd.destination hasSuffix:@"Music/Juice WRLD"] && [odd.theme isEqualToString:@"dark"], @"bad values fall back");
    unsetenv("JUICEDOWNLOADER_SETTINGS");
    [FM() removeItemAtPath:dir error:nil];
}

// ───────────── strings ─────────────

static NSDictionary *MergedStrings(NSArray<NSString *> *folders, NSString *code) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *folder in folders) {
        NSData *data = [NSData dataWithContentsOfFile:[[folder stringByAppendingPathComponent:code] stringByAppendingPathExtension:@"json"]];
        if (!data) continue;
        if (data.length >= 3 && memcmp(data.bytes, "\xEF\xBB\xBF", 3) == 0) data = [data subdataWithRange:NSMakeRange(3, data.length - 3)];
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        CHECK([json isKindOfClass:NSDictionary.class], @"%@/%@.json is not a JSON object", folder, code);
        if (json) [d addEntriesFromDictionary:json];
    }
    return d;
}

static NSSet *Placeholders(NSString *s) {
    NSMutableSet *set = [NSMutableSet set];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\{\\d+\\}" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) [set addObject:[s substringWithRange:m.range]];
    return set;
}

static void TestPlainName(void) {
    EQUAL([CCLyricsIndex plainName:@"Juice WRLD - Calm Down Unreleased.mp3"], @"Calm Down.mp3");
    EQUAL([CCLyricsIndex plainName:@"Juice_Wrld_-_RNB_FREESTYLE.mp3"], @"RNB FREESTYLE.mp3");
    EQUAL([CCLyricsIndex plainName:@"Juice WRLD _ @juicewrld_rus - Quitter (Session Edit).mp3"], @"Quitter (Session Edit).mp3");
    EQUAL([CCLyricsIndex plainName:@"Juice - Me & Agony.m4a"], @"Me & Agony.m4a");
    EQUAL([CCLyricsIndex plainName:@"Juice WRLD - Game (Session Edit) — копия.mp3"], @"Game (Session Edit).mp3");
    EQUAL([CCLyricsIndex plainName:@"who_shot_cupid_with_stems.mp3"], @"who shot cupid.mp3");
    EQUAL([CCLyricsIndex plainName:@"emotional_overdose_extended.mp3"], @"emotional overdose.mp3");
    EQUAL([CCLyricsIndex plainName:@"Juice Never Have To Flex.mp3"], @"Juice Never Have To Flex.mp3");
    EQUAL([CCLyricsIndex plainName:@"Carbon Copy.mp3"], @"Carbon Copy.mp3");
    EQUAL([CCLyricsIndex plainName:@"Already Dead (Remaster) 2.mp3"], @"Already Dead (Remaster).mp3");
    EQUAL([CCLyricsIndex plainName:@"Song 2.mp3"], @"Song 2.mp3");
    CCSong *song = [CCSong fromJSON:@{ @"id": @1, @"name": @"Calm Down", @"category": @"unreleased", @"track_titles": @[ @"Calm Down" ], @"lyrics": @"words" }];
    CCLyricsIndex *index = [[CCLyricsIndex alloc] initWithSongs:@[ song ]];
    EQUAL(@([index findOnDisk:@"Unreleased/Juice WRLD - Calm Down Unreleased.mp3"].song.identifier), @1);
    CHECK([index findOnDisk:@"Unreleased/Juice WRLD - Other Song Unreleased.mp3"] == nil, @"another song stays without words");
}

static void TestDiskState(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *flat = [dir stringByAppendingPathComponent:@"Unreleased"];
    [NSFileManager.defaultManager createDirectoryAtPath:flat withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *(^bytes)(NSUInteger) = ^NSData *(NSUInteger n) { return [NSMutableData dataWithLength:n]; };
    long long mb = 1024 * 1024;
    CCCatalog *catalog = [CCCatalog build:@[
        [CCApiItem path:@"Compilation" type:@"directory" size:0],
        F(@"Compilation/One.mp3", 8 * mb),          // tagged since: a little bigger, in another folder
        F(@"Compilation/Other/One.mp3", 8 * mb),    // the same file again: one file on disk
        F(@"Compilation/Two.mp3", 8 * mb),          // really an M4A, renamed
        F(@"Compilation/Three.mp3", 30 * mb),       // same name, another size: another file
        F(@"Compilation/Four.mp3", 8 * mb),         // only a .part
        F(@"Compilation/Five.mp3", 8 * mb),         // only words beside nothing
        F(@"Compilation/Six.zip", 8 * mb),          // same name, not audio both ways
        F(@"Compilation/Seven.mp3", 12 * mb),       // the silence at its end cut off: smaller
    ]];
    [bytes(8 * mb + 300000) writeToFile:[flat stringByAppendingPathComponent:@"one.MP3"] atomically:NO];
    [bytes(8 * mb) writeToFile:[flat stringByAppendingPathComponent:@"Two.m4a"] atomically:NO];
    [bytes(8 * mb) writeToFile:[flat stringByAppendingPathComponent:@"Three.mp3"] atomically:NO];
    [bytes(8 * mb) writeToFile:[flat stringByAppendingPathComponent:@"Four.mp3.part"] atomically:NO];
    [bytes(100) writeToFile:[flat stringByAppendingPathComponent:@"Five.lrc"] atomically:NO];
    [bytes(8 * mb) writeToFile:[flat stringByAppendingPathComponent:@"Six.mp3"] atomically:NO];
    [bytes(9 * mb) writeToFile:[flat stringByAppendingPathComponent:@"Seven.mp3"] atomically:NO];
    CCDiskState *state = [CCDiskState scan:catalog under:dir];
    CHECK([state has:@"Compilation/One.mp3"], @"found elsewhere in the folder, tagged");
    CHECK([state has:@"Compilation/Other/One.mp3"], @"every catalog place of it counts");
    CHECK([state has:@"Compilation/Two.mp3"], @"found under its right extension");
    CHECK(![state has:@"Compilation/Three.mp3"], @"another size is another file");
    CHECK(![state has:@"Compilation/Four.mp3"], @"a .part is not there yet");
    CHECK(![state has:@"Compilation/Five.mp3"], @"a .lrc is not the song");
    CHECK(![state has:@"Compilation/Six.zip"], @"an MP3 is not the zip");
    CHECK([state has:@"Compilation/Seven.mp3"], @"a file trimmed of its silence is still there");
    CHECK(state.files == 3, @"each file on disk counted once");
    CHECK(state.bytes == 25 * mb + 300000, @"bytes of what is there");
    CHECK([[state localPathOf:@"Compilation/Two.mp3"] hasSuffix:@"/Unreleased/Two.m4a"], @"the place of it");
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

static void TestStrings(NSArray<NSString *> *folders) {
    NSDictionary *en = MergedStrings(folders, @"en");
    for (NSString *id_ in CCCatalog.sectionIds) {
        CHECK(en[[@"nav." stringByAppendingString:id_]] != nil, @"missing nav.%@", id_);
        CHECK((en[[NSString stringWithFormat:@"section.%@.desc", id_]] != nil), @"missing section.%@.desc", id_);
    }
    for (NSString *key in @[ @"menu.quit", @"menu.settings", @"settings.backdrop", @"download.title", @"lyrics.enable", @"about.source", @"overview.catalog" ])
        CHECK(en[key] != nil, @"missing %@", key);
    CHECK(![en[@"settings.backdrop"] containsString:@"Mica"], @"the macOS wording is not laid over");

    // The overlay may only replace keys English has, and must keep their {0} placeholders.
    NSString *overlay = folders.lastObject;
    NSDictionary *enOverlay = MergedStrings(@[ overlay ], @"en");
    for (CCLanguage *language in CCLocalization.languages) {
        NSDictionary *strings = MergedStrings(@[ overlay ], language.code);
        for (NSString *key in strings) {
            CHECK(enOverlay[key] != nil, @"%@.json has %@, English does not", language.code, key);
            if (enOverlay[key]) CHECK([Placeholders(strings[key]) isEqualToSet:Placeholders(enOverlay[key])], @"%@: placeholders of %@", language.code, key);
        }
    }

    CCLocalization *loc = [CCLocalization new];
    loc.searchFolders = folders;
    [loc setLanguage:@"en"];
    EQUAL(loc.code, @"en");
    EQUAL([loc format:@"library.folderLine" arguments:@[ @"12" ]], @"12 files");
    EQUAL([loc string:@"no.such.key"], @"no.such.key");
    [loc setLanguage:@"xx"];
    EQUAL(loc.code, @"en");
    [loc setLanguage:@"ru"];
    EQUAL(loc.code, @"ru");
    // Whatever a language has not translated yet falls back to English.
    CHECK([loc string:@"overview.catalog"].length > 0 && ![[loc string:@"overview.catalog"] isEqualToString:@"overview.catalog"], @"no fallback");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        gStubLock = [NSLock new];
        const char *strings = getenv("JUICEDOWNLOADER_STRINGS");
        NSArray *folders = strings ? [[NSString stringWithUTF8String:strings] componentsSeparatedByString:@":"] : @[];
        CHECK(folders.count == 2, @"JUICEDOWNLOADER_STRINGS must name the shared and the macOS strings folders");

        TestFormatting();
        TestCatalog();
        TestDiskState();
        TestLibraryRows();
        TestLocalPath();
        TestLyricsFixture();
        TestPlainName();
        TestLyricsMatcher();
        TestLrc();
        TestId3();
        TestDownloads();
        TestWebLyrics();
        TestApi();
        TestCache();
        TestLibrary();
        TestSongRules();
        TestAudioCopies();
        TestSettings();
        if (folders.count == 2) TestStrings(folders);

        printf("%d passed, %d failed\n", gPassed, gFailed);
        return gFailed ? 1 : 0;
    }
}
