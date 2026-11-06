#import "CCLyrics.h"
#import "CCCatalog.h"
#include <stdio.h>

// ───────────── helpers ─────────────

static BOOL HasText(NSString *s) {
    return s.length > 0 && [s rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet.invertedSet].location != NSNotFound;
}

static NSString *Trim(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }

static NSString *StringOf(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }

#define REGEX(name, pattern, opts)                                                                            \
    static NSRegularExpression *name(void) {                                                                  \
        static NSRegularExpression *re;                                                                       \
        static dispatch_once_t once;                                                                          \
        dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:pattern options:opts error:nil]; }); \
        return re;                                                                                            \
    }

#define IC NSRegularExpressionCaseInsensitive
REGEX(Extension, @"\\.[A-Za-z0-9]{2,4}$", 0)
REGEX(Bracket, @"[\\(\\[\\{][^\\)\\]\\}]*[\\)\\]\\}]", 0)
REGEX(Credit, @"[\\(\\[\\{]\\s*(session edit|sessions?|studio session( edit)?|pro ?tools|logic session|multi-?track stems|stems|feat\\.?[^\\)\\]\\}]*|ft\\.?[^\\)\\]\\}]*|with [^\\)\\]\\}]*|prod\\.?[^\\)\\]\\}]*|best|master|mastered|remaster(ed)?|rough|og|og file|explicit|clean|demo)\\s*[\\)\\]\\}]", IC)
REGEX(TrailingCredit, @"\\b(feat|ft|prod)\\b\\.?.*$", IC)
REGEX(TrackNumber, @"^\\s*\\d{1,2}[\\s._-]+", 0)
REGEX(DateStamp, @"\\b\\d{6,8}\\b", 0)
REGEX(AnyVersion, @"\\bv\\d+(\\.\\d+)?\\b", IC)
REGEX(Version, @"\\bv(\\d+)\\b(?!\\.\\d)", IC)
REGEX(ArtistWords, @"\\b(juice\\s*wrld|juice\\s*world|juicethekidd?)\\b", IC)
REGEX(TrailingMixWord, @"[\\s._-]+(final|new|master|mastered|rough|mix|session)[\\s._-]*\\d*\\s*$", IC)
REGEX(Spaces, @"\\s+", 0)
REGEX(Uploader, @"@\\w+", 0)
REGEX(LeadingArtist, @"^\\s*(juice\\s*(wrld|world)?|juicethekidd?)\\s*[-–—]+\\s*", IC)
REGEX(CopyMark, @"(\\s*[-–—]\\s*(копия|copy)|\\s+копия)(\\s+\\d+)?\\s*$", IC)
REGEX(UnreleasedWord, @"[\\(\\[\\{]?\\bunreleased\\b[\\)\\]\\}]?", IC)
REGEX(TrailingUploadWord, @"[\\s.-]+(with\\s+)?(stems?|extended|unheard)\\s*$", IC)
REGEX(TrailingCopyNumber, @"(?<=[\\)\\]\\}])\\s*\\d{1,2}\\s*$", 0)
REGEX(NoVocals, @"instrumental|\\bbeat\\b", IC)
REGEX(SessionMark, @"session edit|[\\(\\[\\{]\\s*(studio )?sessions?\\s*[\\)\\]\\}]|\\bsession\\b(\\s+v\\d+)?\\s*(\\.[A-Za-z0-9]{2,4})?$", IC)
REGEX(FolderSuffix, @"\\s*\\(Sessions\\)$", 0)
REGEX(JoinMark, @"\\s+(?:\\+|&|and|x)\\s+|\\s*,\\s+", IC)
REGEX(FileNameLabel, @"^\\s*[^:]{1,40}:\\s*", 0)
REGEX(NotAFile, @"^\\s*(session|folder|instrumental)", IC)
REGEX(Timed, @"^\\s*\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]\\s?(.*)$", 0)

static NSString *Replace(NSRegularExpression *re, NSString *text, NSString *with) {
    return [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:with];
}

static BOOL IsMatch(NSRegularExpression *re, NSString *text) {
    return [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

static NSString *StripExtension(NSString *name) { return Replace(Extension(), name, @""); }

/// Letters (L*) and decimal digits, like .NET's char.IsLetterOrDigit: Cocoa's letter set also holds the combining marks.
static NSCharacterSet *LettersAndDigits(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *s = [NSCharacterSet.letterCharacterSet mutableCopy];
        [s formIntersectionWithCharacterSet:NSCharacterSet.nonBaseCharacterSet.invertedSet];
        [s formUnionWithCharacterSet:NSCharacterSet.decimalDigitCharacterSet];
        set = [s copy];
    });
    return set;
}

NSString *CCLyricsFold(NSString *text) {
    NSString *normal = text.precomposedStringWithCompatibilityMapping;
    NSCharacterSet *keep = LettersAndDigits();
    NSUInteger n = normal.length;
    NSMutableString *folded = [NSMutableString stringWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [normal characterAtIndex:i];
        if (CFStringIsSurrogateHighCharacter(c) || CFStringIsSurrogateLowCharacter(c)) continue; // as char.IsLetterOrDigit on a lone half
        if (![keep characterIsMember:c]) continue;
        if (c < 128) {
            if (c >= 'A' && c <= 'Z') c += 32;
        } else {
            NSString *lower = [NSString stringWithCharacters:&c length:1].lowercaseString;
            if (lower.length == 1) c = [lower characterAtIndex:0];
        }
        [folded appendFormat:@"%C", c];
    }
    return folded;
}

// NSNotFound stands for "no version".
static NSInteger VersionOf(NSString *name) {
    NSTextCheckingResult *m = [Version() firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
    return m ? [name substringWithRange:[m rangeAtIndex:1]].integerValue : NSNotFound;
}

static NSSet<NSString *> *Qualifiers(NSString *name) {
    NSMutableSet *words = [NSMutableSet set];
    NSString *stem = StripExtension(name);
    for (NSTextCheckingResult *m in [Bracket() matchesInString:stem options:0 range:NSMakeRange(0, stem.length)]) {
        NSString *bracket = [stem substringWithRange:m.range];
        if (IsMatch(Credit(), bracket) || IsMatch(Version(), bracket)) continue;
        [words addObject:CCLyricsFold(bracket)];
    }
    return words;
}

static NSArray<NSString *> *FileNamesOf(CCSong *song) {
    NSMutableArray *names = [NSMutableArray array];
    NSCharacterSet *lines = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    for (NSString *line in [(song.fileNames ?: @"") componentsSeparatedByCharactersInSet:lines]) {
        if (line.length == 0) continue;
        // "File Name (1): naruto", "Explicit: 06 Blood on My Jeans", "Session Title: juice 4.ptx", or a bare name.
        NSTextCheckingResult *label = [FileNameLabel() firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (label && IsMatch(NotAFile(), [line substringWithRange:label.range])) continue;
        NSString *name = Trim(label ? [line substringFromIndex:NSMaxRange(label.range)] : line);
        if (name.length > 0 && [name caseInsensitiveCompare:@"N/A"] != NSOrderedSame) [names addObject:name];
    }
    return names;
}

// ───────────── songs ─────────────

@implementation CCSong

+ (instancetype)fromJSON:(id)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    CCSong *s = [CCSong new];
    id n = json[@"id"];
    s.identifier = [n isKindOfClass:NSNumber.class] ? [n longLongValue] : 0;
    s.name = StringOf(json[@"name"]) ?: @"";
    s.category = StringOf(json[@"category"]) ?: @"";
    s.path = StringOf(json[@"path"]);
    id era = json[@"era"];
    if ([era isKindOfClass:NSDictionary.class]) {
        s.eraName = StringOf(era[@"name"]);
        s.eraDescription = StringOf(era[@"description"]);
    }
    id titles = json[@"track_titles"];
    if ([titles isKindOfClass:NSArray.class]) {
        NSMutableArray *list = [NSMutableArray array];
        for (id t in titles)
            if ([t isKindOfClass:NSString.class]) [list addObject:t];
        s.trackTitles = list;
    }
    s.fileNames = StringOf(json[@"file_names"]);
    s.lyrics = StringOf(json[@"lyrics"]);
    s.syncedLyrics = StringOf(json[@"synced_lyrics"]);
    s.leakType = StringOf(json[@"leak_type"]);
    s.length = StringOf(json[@"length"]);
    return s;
}

- (NSDictionary *)JSON {
    id era = self.eraName || self.eraDescription
        ? @{ @"name": self.eraName ?: NSNull.null, @"description": self.eraDescription ?: NSNull.null } : (id)NSNull.null;
    return @{
        @"id": @(self.identifier),
        @"name": self.name,
        @"category": self.category,
        @"path": self.path ?: NSNull.null,
        @"era": era,
        @"track_titles": self.trackTitles ?: NSNull.null,
        @"file_names": self.fileNames ?: NSNull.null,
        @"lyrics": self.lyrics ?: NSNull.null,
        @"synced_lyrics": self.syncedLyrics ?: NSNull.null,
        @"leak_type": self.leakType ?: NSNull.null,
        @"length": self.length ?: NSNull.null,
    };
}

@end

NSString *CCLyricsFitName(CCLyricsFit fit) { return fit == CCLyricsFitSameRecording ? @"SameRecording" : @"OtherRecording"; }

NSString *CCLyricsMatchKindName(CCLyricsMatchKind kind) {
    switch (kind) {
        case CCLyricsMatchPath: return @"Path";
        case CCLyricsMatchFileName: return @"FileName";
        case CCLyricsMatchTitle: return @"Title";
        case CCLyricsMatchLoose: return @"Loose";
    }
    return @"";
}

@implementation CCLyricsMatch
- (instancetype)initWithSong:(CCSong *)song kind:(CCLyricsMatchKind)kind fit:(CCLyricsFit)fit {
    if ((self = [super init])) {
        _song = song;
        _kind = kind;
        _fit = fit;
    }
    return self;
}
@end

// ───────────── index ─────────────

@implementation CCLyricsIndex {
    NSMutableDictionary<NSString *, CCSong *> *_byPath;
    NSMutableDictionary<NSString *, NSMutableArray<CCSong *> *> *_byFileName, *_byTitle;
    NSMutableDictionary<NSString *, NSString *> *_eraByFolder;
}

static void AddTo(NSMutableDictionary *map, NSString *key, CCSong *song) {
    if (key.length == 0) return;
    NSMutableArray *list = map[key];
    if (!list) map[key] = list = [NSMutableArray array];
    if ([list indexOfObjectIdenticalTo:song] == NSNotFound) [list addObject:song];
}

- (instancetype)initWithSongs:(NSArray<CCSong *> *)songs {
    if ((self = [super init])) {
        _byPath = [NSMutableDictionary dictionary];
        _byFileName = [NSMutableDictionary dictionary];
        _byTitle = [NSMutableDictionary dictionary];
        _eraByFolder = [NSMutableDictionary dictionary];
        for (CCSong *song in songs) {
            @autoreleasepool {
                _songCount++;
                if ([CCLyricsIndex hasWords:song]) _withLyrics++;
                if (song.path.length > 0) _byPath[song.path] = song;
                for (NSString *name in FileNamesOf(song)) AddTo(_byFileName, [CCLyricsIndex key:name loose:NO], song);

                NSMutableOrderedSet *titles = [NSMutableOrderedSet orderedSetWithObject:song.name];
                if (song.trackTitles) [titles addObjectsFromArray:song.trackTitles];
                for (NSString *title in titles) {
                    AddTo(_byTitle, [CCLyricsIndex key:title loose:NO], song);
                    AddTo(_byTitle, [CCLyricsIndex key:title loose:YES], song);
                }
                if (song.eraName.length > 0 && song.eraDescription.length > 0)
                    _eraByFolder[song.eraDescription.uppercaseString] = song.eraName;
            }
        }
    }
    return self;
}

+ (BOOL)hasWords:(CCSong *)song { return HasText(song.lyrics) || HasText(song.syncedLyrics); }

// With its brackets gone a name can come down to a word that says nothing about which song it is.
static NSSet *GenericWords(void) {
    static NSSet *generic;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        generic = [NSSet setWithArray:@[ @"freestyle", @"intro", @"outro", @"interlude", @"skit", @"remix", @"untitled", @"unknown", @"song", @"track", @"audio", @"demo", @"session" ]];
    });
    return generic;
}

/// A session's words stand in for a finished song only if they could be that song, not an hour of takes.
static const NSUInteger kMaxSongLength = 5000;
static BOOL IsSessionSong(CCSong *song) { return [song.category isEqualToString:@"recording_session"]; }
static BOOL FitsAFinishedSong(CCSong *song) { return song.lyrics.length <= kMaxSongLength; }

static NSString *LastComponent(NSString *path) {
    NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
    return slash.location == NSNotFound ? path : [path substringFromIndex:slash.location + 1];
}

+ (BOOL)isSessionFile:(NSString *)path {
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    return [path hasPrefix:@"Session Edits/"] || [path hasPrefix:@"Studio Sessions/"] || IsMatch(SessionMark(), LastComponent(path));
}

+ (NSString *)key:(NSString *)name loose:(BOOL)loose {
    NSString *text = Replace(Credit(), Trim(StripExtension(name)), @" ");
    text = Replace(TrailingCredit(), text, @" ");
    if (loose) {
        text = Replace(Bracket(), text, @" ");
        text = Replace(TrackNumber(), text, @" ");
        text = Replace(DateStamp(), text, @" ");
        text = Replace(AnyVersion(), text, @" ");
        text = Replace(ArtistWords(), text, @" ");
        text = Replace(TrailingMixWord(), text, @" ");
    }
    NSString *key = CCLyricsFold(text);
    return loose && [GenericWords() containsObject:key] ? @"" : key;
}

- (NSString *)lengthOf:(NSString *)path { return _byPath[path].length; }

- (CCLyricsMatch *)find:(NSString *)path {
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSString *name = LastComponent(path);
    BOOL session = [CCLyricsIndex isSessionFile:path];

    CCSong *listed = _byPath[path];
    if (listed) {
        if ([CCLyricsIndex hasWords:listed]) return [[CCLyricsMatch alloc] initWithSong:listed kind:CCLyricsMatchPath fit:CCLyricsFitSameRecording];
        // The API often keeps a take twice, the words only on its recording-session entry. Another name of the same
        // take may hold them; another take may not, so "Slasher (v3)" stays without the words of "Slasher (v5)".
        NSInteger take = VersionOf(listed.name);
        NSString *looseKey = [CCLyricsIndex key:listed.name loose:YES], *strictKey = [CCLyricsIndex key:listed.name loose:NO];
        CCSong *twin = nil, *taken = nil;
        BOOL twinExact = NO;
        for (CCSong *s in _byTitle[looseKey]) {
            if (![CCLyricsIndex hasWords:s] || VersionOf(s.name) != take) continue;
            if (![[CCLyricsIndex key:s.name loose:YES] isEqualToString:looseKey]) continue;
            if (!IsSessionSong(s)) {
                BOOL exact = [[CCLyricsIndex key:s.name loose:NO] isEqualToString:strictKey];
                if (!twin || (exact && !twinExact) || (exact == twinExact && s.identifier < twin.identifier)) {
                    twin = s;
                    twinExact = exact;
                }
            }
            if (FitsAFinishedSong(s) && (!taken || s.identifier < taken.identifier)) taken = s;
        }
        if (twin) return [[CCLyricsMatch alloc] initWithSong:twin kind:CCLyricsMatchPath fit:CCLyricsFitSameRecording];
        return taken ? [[CCLyricsMatch alloc] initWithSong:taken kind:CCLyricsMatchPath fit:CCLyricsFitOtherRecording] : nil;
    }

    if (IsMatch(NoVocals(), name) || [path hasPrefix:@"Instrumentals/"] || [path containsString:@"/Instrumental/"]) return nil;

    NSInteger version = VersionOf(name);
    // The file's own kind of recording first, through every way of matching; the other kind only after that.
    CCLyricsMatch *match = [self search:path name:name version:version fit:CCLyricsFitSameRecording allowed:^BOOL(CCSong *s) { return IsSessionSong(s) == session; }];
    if (match) return match;
    match = [self joined:path name:name];
    if (match) return match;
    return [self search:path name:name version:version fit:CCLyricsFitOtherRecording allowed:^BOOL(CCSong *s) { return IsSessionSong(s) != session && (session || FitsAFinishedSong(s)); }];
}

+ (NSString *)plainName:(NSString *)name {
    NSString *extension = name.pathExtension, *text = StripExtension(name);
    text = Replace(Uploader(), text, @" ");   // before the underscores: they can be part of the name
    text = [text stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    text = Replace(LeadingArtist(), text, @"");
    text = Replace(CopyMark(), text, @"");
    text = Replace(UnreleasedWord(), text, @" ");
    text = Replace(TrailingUploadWord(), text, @"");
    text = Replace(TrailingCopyNumber(), text, @"");
    text = Trim(Replace(Spaces(), text, @" "));
    if (text.length == 0) return name;
    return extension.length > 0 ? [text stringByAppendingPathExtension:extension] : text;
}

- (CCLyricsMatch *)findOnDisk:(NSString *)path {
    CCLyricsMatch *match = [self find:path];
    if (match) return match;
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSString *name = LastComponent(path), *plain = [CCLyricsIndex plainName:name];
    return [plain isEqualToString:name] ? nil : [self find:[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:plain]];
}

- (CCLyricsMatch *)search:(NSString *)path name:(NSString *)name version:(NSInteger)version fit:(CCLyricsFit)fit allowed:(BOOL (^)(CCSong *))allowed {
    NSString *strict = [CCLyricsIndex key:name loose:NO];
    CCSong *song = [self pick:_byFileName key:strict path:path version:NSNotFound allowed:allowed];
    if (song) return [[CCLyricsMatch alloc] initWithSong:song kind:CCLyricsMatchFileName fit:fit];
    song = [self pick:_byTitle key:strict path:path version:version allowed:allowed];
    if (song) return [[CCLyricsMatch alloc] initWithSong:song kind:CCLyricsMatchTitle fit:fit];
    song = [self pick:_byTitle key:[CCLyricsIndex key:name loose:YES] path:path version:version allowed:allowed];
    if (song) return [[CCLyricsMatch alloc] initWithSong:song kind:CCLyricsMatchLoose fit:fit];
    // "Drinks In The Air (Stuck) [Session Edit]": the song's other name, in brackets.
    NSString *stem = StripExtension(name);
    for (NSTextCheckingResult *m in [Bracket() matchesInString:stem options:0 range:NSMakeRange(0, stem.length)]) {
        NSString *bracket = [stem substringWithRange:m.range];
        if (IsMatch(Credit(), bracket) || IsMatch(Version(), bracket)) continue;
        NSString *alias = CCLyricsFold(bracket);
        if ([GenericWords() containsObject:alias]) continue;
        song = [self pick:_byTitle key:alias path:path version:version allowed:allowed];
        if (song) return [[CCLyricsMatch alloc] initWithSong:song kind:CCLyricsMatchLoose fit:fit];
    }
    return nil;
}

/// A file that joins songs, "Motions + 365 (Session Edit)" or "Miracle + Shoot For Love (ProTools)": each song's words in
/// turn. Tried after the whole name has failed, so "Black & White" stays one song.
- (CCLyricsMatch *)joined:(NSString *)path name:(NSString *)name {
    NSString *stem = StripExtension(name);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger from = 0;
    for (NSTextCheckingResult *m in [JoinMark() matchesInString:stem options:0 range:NSMakeRange(0, stem.length)]) {
        [parts addObject:[stem substringWithRange:NSMakeRange(from, m.range.location - from)]];
        from = NSMaxRange(m.range);
    }
    [parts addObject:[stem substringFromIndex:from]];
    if (parts.count < 2) return nil;

    NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
    NSString *folder = slash.location == NSNotFound ? @"" : [path substringToIndex:slash.location + 1];
    NSString *last = parts.lastObject;
    NSMutableArray *marks = [NSMutableArray array];
    for (NSTextCheckingResult *m in [Bracket() matchesInString:last options:0 range:NSMakeRange(0, last.length)]) {
        NSString *bracket = [last substringWithRange:m.range];
        if (IsMatch(Credit(), bracket)) [marks addObject:bracket];
    }
    NSString *extension = name.pathExtension.length > 0 ? [@"." stringByAppendingString:name.pathExtension] : @"";
    BOOL session = [CCLyricsIndex isSessionFile:path];

    NSMutableArray<CCLyricsMatch *> *found = [NSMutableArray array];
    for (NSString *part in parts) {
        NSString *named = Trim(part);
        for (NSString *mark in marks)
            if (![named containsString:mark]) named = [NSString stringWithFormat:@"%@ %@", named, mark];
        // What the whole file is, each song in it is.
        if (session && !IsMatch(SessionMark(), named)) named = [named stringByAppendingString:@" [Session Edit]"];
        CCLyricsMatch *match = [self find:[NSString stringWithFormat:@"%@%@%@", folder, named, extension]];
        if (!match) return nil;
        [found addObject:match];
    }
    CCSong *song = [CCSong new];
    song.identifier = found[0].song.identifier;
    song.category = found[0].song.category;
    song.eraName = found[0].song.eraName;
    song.eraDescription = found[0].song.eraDescription;
    NSMutableArray *names = [NSMutableArray array], *words = [NSMutableArray array];
    BOOL same = YES;
    for (CCLyricsMatch *f in found) {
        [names addObject:f.song.name];
        [words addObject:Trim(f.song.lyrics ?: @"")];
        same &= f.fit == CCLyricsFitSameRecording;
    }
    song.name = [names componentsJoinedByString:@" + "];
    song.lyrics = [words componentsJoinedByString:@"\n\n"];
    return [[CCLyricsMatch alloc] initWithSong:song kind:CCLyricsMatchLoose fit:same ? CCLyricsFitSameRecording : CCLyricsFitOtherRecording];
}

- (CCSong *)pick:(NSDictionary<NSString *, NSArray<CCSong *> *> *)map key:(NSString *)key path:(NSString *)path version:(NSInteger)wanted allowed:(BOOL (^)(CCSong *))allowed {
    if (key.length == 0) return nil;
    NSArray<CCSong *> *all = map[key];
    if (!all) return nil;
    NSMutableArray<CCSong *> *candidates = [NSMutableArray array];
    for (CCSong *s in all)
        if ([CCLyricsIndex hasWords:s] && allowed(s)) [candidates addObject:s];
    if (wanted != NSNotFound) {
        // Another take of the song can have other verses. A file that says which take it is gets that take or none;
        // a song the API keeps without takes is the same words whatever the file calls itself.
        NSMutableArray *same = [NSMutableArray array], *unversioned = [NSMutableArray array];
        for (CCSong *s in candidates) {
            NSInteger v = VersionOf(s.name);
            if (v == wanted) [same addObject:s];
            if (v == NSNotFound) [unversioned addObject:s];
        }
        candidates = same.count > 0 ? same : unversioned;
    }
    if (candidates.count == 0) return nil;

    NSArray *order = [path containsString:@"Released Discography"] ? @[ @"released", @"unreleased", @"unsurfaced", @"recording_session" ]
                                                                   : @[ @"unreleased", @"released", @"unsurfaced", @"recording_session" ];
    NSString *era = [self eraOf:path];
    NSSet *words = Qualifiers(LastComponent(path));

    // Highest score, then the lowest version, then the lowest id; the first of equals stays, as in a stable sort.
    CCSong *best = nil;
    NSInteger bestScore = 0, bestVersion = 0;
    for (CCSong *s in candidates) {
        NSInteger score = Score(s, era, words, order, key);
        NSInteger v = VersionOf(s.name);
        if (v == NSNotFound) v = 0;
        BOOL better = !best || score > bestScore || (score == bestScore && (v < bestVersion || (v == bestVersion && s.identifier < best.identifier)));
        if (better) {
            best = s;
            bestScore = score;
            bestVersion = v;
        }
    }
    return best;
}

static NSInteger Score(CCSong *song, NSString *era, NSSet *fileWords, NSArray *order, NSString *key) {
    NSUInteger rank = [order indexOfObject:song.category];
    NSInteger score = -(NSInteger)(rank == NSNotFound ? order.count : rank);
    if (era && [song.eraName isEqualToString:era]) score += 10;
    // The name itself beats a second title listed for some other recording.
    if ([[CCLyricsIndex key:song.name loose:NO] isEqualToString:key] || [[CCLyricsIndex key:song.name loose:YES] isEqualToString:key]) score += 4;
    // "(Live)" or "(Extended Outro)" on the song but not on the file is a different recording of the words.
    NSInteger extra = 0;
    for (NSString *w in Qualifiers(song.name))
        if (![fileWords containsObject:w]) extra++;
    return score - 3 * extra;
}

/// The era a folder like "7. Goodbye & Good Riddance (Sessions)" belongs to, read off the API's own descriptions.
- (NSString *)eraOf:(NSString *)path {
    for (NSString *segment in [path componentsSeparatedByString:@"/"]) {
        NSString *folder = Replace(FolderSuffix(), [CCCatalog displayName:segment], @"");
        NSString *era = _eraByFolder[folder.uppercaseString];
        if (era) return era;
    }
    return nil;
}

@end

// ───────────── LRC ─────────────

@implementation CCLrc

+ (NSString *)normalize:(NSString *)synced {
    if (!HasText(synced)) return nil;
    NSMutableArray *lines = [NSMutableArray array];
    NSCharacterSet *breaks = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    for (NSString *raw in [synced componentsSeparatedByCharactersInSet:breaks]) {
        if (raw.length == 0) continue;
        NSTextCheckingResult *m = [Timed() firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (!m) continue;
        NSString *minutes = [raw substringWithRange:[m rangeAtIndex:1]];
        NSString *seconds = [raw substringWithRange:[m rangeAtIndex:2]];
        NSRange fractionRange = [m rangeAtIndex:3];
        NSString *fraction = @"00";
        if (fractionRange.location != NSNotFound) {
            fraction = [raw substringWithRange:fractionRange];
            fraction = fraction.length == 1 ? [fraction stringByAppendingString:@"0"] : [fraction substringToIndex:2];
        }
        if (minutes.length == 1) minutes = [@"0" stringByAppendingString:minutes];
        [lines addObject:[NSString stringWithFormat:@"[%@:%@.%@]%@", minutes, seconds, fraction, Trim([raw substringWithRange:[m rangeAtIndex:4]])]];
    }
    return lines.count > 0 ? [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : nil;
}

+ (NSString *)plain:(NSString *)text {
    NSString *unix = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    return [Trim(unix) stringByAppendingString:@"\n"];
}

@end

// ───────────── ID3 ─────────────

static const NSUInteger kHeaderSize = 10;
static const NSUInteger kPadding = 2048;

static NSError *Id3Error(NSString *message) {
    return [NSError errorWithDomain:@"CCId3" code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

@interface CCId3Frame : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) NSData *raw;
@end
@implementation CCId3Frame
@end

@interface CCId3Tag : NSObject
@property (nonatomic) uint8_t version;
@property (nonatomic) unsigned long long endOffset;
@property (nonatomic, strong) NSMutableArray<CCId3Frame *> *frames;
@end
@implementation CCId3Tag
@end

@implementation CCId3Lyrics

static BOOL IsTag(const uint8_t *h) {
    return h[0] == 'I' && h[1] == 'D' && h[2] == '3' && h[3] != 0xFF && h[4] != 0xFF && h[6] < 0x80 && h[7] < 0x80 && h[8] < 0x80 && h[9] < 0x80;
}

static NSData *RemoveUnsync(NSData *data) {
    const uint8_t *in = data.bytes;
    NSUInteger length = data.length, n = 0;
    NSMutableData *result = [NSMutableData dataWithLength:length];
    uint8_t *out = result.mutableBytes;
    for (NSUInteger i = 0; i < length; i++) {
        out[n++] = in[i];
        if (in[i] == 0xFF && i + 1 < length && in[i + 1] == 0) i++;
    }
    result.length = n;
    return result;
}

/// YES with *tag nil when the file has no tag at all; NO with an error when the file or the tag cannot be read.
static BOOL ReadTag(NSString *file, CCId3Tag **tag, NSError **error) {
    *tag = nil;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:file] error:error];
    if (!h) return NO;
    NSData *headerData = [h readDataUpToLength:kHeaderSize error:error];
    if (!headerData) return NO;
    if (headerData.length < kHeaderSize || !IsTag(headerData.bytes)) {
        [h closeFile];
        return YES;
    }
    const uint8_t *header = headerData.bytes;
    uint8_t version = header[3];
    if (version != 3 && version != 4) {
        if (error) *error = Id3Error(@"Only ID3v2.3 and v2.4 tags can be rewritten.");
        return NO;
    }
    uint8_t flags = header[5];
    NSUInteger size = ((NSUInteger)header[6] << 21) | ((NSUInteger)header[7] << 14) | ((NSUInteger)header[8] << 7) | header[9];
    unsigned long long length = 0;
    [h seekToEndReturningOffset:&length error:nil];
    if (size > length - kHeaderSize) {
        if (error) *error = Id3Error(@"The tag is longer than the file.");
        return NO;
    }
    [h seekToOffset:kHeaderSize error:nil];
    NSData *body = size > 0 ? [h readDataUpToLength:size error:error] : [NSData data];
    [h closeFile];
    if (!body) return NO;
    if (body.length < size) {
        if (error) *error = Id3Error(@"The tag is longer than the file.");
        return NO;
    }
    if (version == 3 && (flags & 0x80)) body = RemoveUnsync(body);

    const uint8_t *b = body.bytes;
    NSUInteger bodyLength = body.length, pos = 0;
    if ((flags & 0x40) && bodyLength >= 4) {
        // The extended header is dropped: it holds a checksum or restrictions for the tag as it was.
        long long ext = version == 4 ? (((long long)b[0] << 21) | ((long long)b[1] << 14) | ((long long)b[2] << 7) | b[3])
                                     : (((long long)b[0] << 24) | ((long long)b[1] << 16) | ((long long)b[2] << 8) | b[3]) + 4;
        if (ext < 0 || ext > (long long)bodyLength) {
            if (error) *error = Id3Error(@"Damaged extended header.");
            return NO;
        }
        pos = (NSUInteger)ext;
    }

    CCId3Tag *result = [CCId3Tag new];
    result.version = version;
    result.endOffset = kHeaderSize + (unsigned long long)size + ((flags & 0x10) && version == 4 ? kHeaderSize : 0);
    result.frames = [NSMutableArray array];
    while (pos + kHeaderSize <= bodyLength) {
        BOOL valid = YES;
        for (NSUInteger i = 0; i < 4; i++) {
            uint8_t c = b[pos + i];
            valid &= (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        }
        if (!valid) break; // padding, or something this reader should leave out of the rewrite

        long long frameLength = version == 4
            ? (((long long)b[pos + 4] << 21) | ((long long)b[pos + 5] << 14) | ((long long)b[pos + 6] << 7) | b[pos + 7])
            : (((long long)b[pos + 4] << 24) | ((long long)b[pos + 5] << 16) | ((long long)b[pos + 6] << 8) | b[pos + 7]);
        if (frameLength <= 0 || pos + kHeaderSize + (unsigned long long)frameLength > bodyLength) break;

        CCId3Frame *frame = [CCId3Frame new];
        frame.identifier = [[NSString alloc] initWithBytes:b + pos length:4 encoding:NSASCIIStringEncoding];
        frame.raw = [body subdataWithRange:NSMakeRange(pos, kHeaderSize + (NSUInteger)frameLength)];
        [result.frames addObject:frame];
        pos += kHeaderSize + (NSUInteger)frameLength;
    }
    *tag = result;
    return YES;
}

/// Some files in the archive are named .mp3 but hold another format, and a tag in front of those stops them playing.
static BOOL IsOtherContainer(NSData *data) {
    const uint8_t *h = data.bytes;
    NSUInteger n = data.length;
    if (n >= 8 && memcmp(h + 4, "ftyp", 4) == 0) return YES;
    if (n < 4) return NO;
    const uint8_t ebml[] = { 0x1A, 0x45, 0xDF, 0xA3 };
    return memcmp(h, "RIFF", 4) == 0 || memcmp(h, "OggS", 4) == 0 || memcmp(h, "fLaC", 4) == 0 || memcmp(h, ebml, 4) == 0;
}

+ (BOOL)canTag:(NSString *)file error:(NSError **)error {
    if ([file.pathExtension caseInsensitiveCompare:@"mp3"] != NSOrderedSame) return NO;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:file] error:error];
    if (!h) return NO;
    NSData *header = [h readDataUpToLength:kHeaderSize error:error];
    if (!header) { [h closeFile]; return NO; }
    if (header.length < kHeaderSize || !IsTag(header.bytes)) {
        [h closeFile];
        return !IsOtherContainer(header);
    }
    const uint8_t *b = header.bytes;
    if (b[3] != 3 && b[3] != 4) { [h closeFile]; return NO; }
    unsigned long long size = ((unsigned long long)b[6] << 21) | ((unsigned long long)b[7] << 14) | ((unsigned long long)b[8] << 7) | b[9];
    [h seekToOffset:kHeaderSize + size error:nil];
    NSData *start = [h readDataUpToLength:8 error:nil];
    [h closeFile];
    return !IsOtherContainer(start ?: [NSData data]);
}

+ (BOOL)has:(NSString *)file error:(NSError **)error {
    CCId3Tag *tag;
    if (!ReadTag(file, &tag, error)) return NO;
    for (CCId3Frame *frame in tag.frames)
        if ([frame.identifier isEqualToString:@"USLT"]) return YES;
    return NO;
}

static NSData *LyricsBody(uint8_t version, NSString *lyrics) {
    NSMutableData *body = [NSMutableData data];
    if (version == 4) {
        const uint8_t head[] = { 3, 'e', 'n', 'g', 0 }; // UTF-8, language, empty description
        [body appendBytes:head length:sizeof head];
        [body appendData:[lyrics dataUsingEncoding:NSUTF8StringEncoding]];
    } else {
        // UTF-16 with a byte order mark, the only full Unicode ID3v2.3 has.
        const uint8_t head[] = { 1, 'e', 'n', 'g', 0xFF, 0xFE, 0, 0, 0xFF, 0xFE };
        [body appendBytes:head length:sizeof head];
        [body appendData:[lyrics dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
    }
    return body;
}

static void AppendFrame(NSMutableData *to, uint8_t version, const char *identifier, NSData *content) {
    [to appendBytes:identifier length:4];
    NSUInteger n = content.length;
    uint8_t size[6] = { 0 };
    if (version == 4) {
        size[0] = (n >> 21) & 0x7F;
        size[1] = (n >> 14) & 0x7F;
        size[2] = (n >> 7) & 0x7F;
        size[3] = n & 0x7F;
    } else {
        size[0] = (n >> 24) & 0xFF;
        size[1] = (n >> 16) & 0xFF;
        size[2] = (n >> 8) & 0xFF;
        size[3] = n & 0xFF;
    }
    [to appendBytes:size length:6];
    [to appendData:content];
}

+ (BOOL)write:(NSString *)lyrics to:(NSString *)file error:(NSError **)error {
    CCId3Tag *tag;
    if (!ReadTag(file, &tag, error)) return NO;
    uint8_t version = tag ? tag.version : 3;
    unsigned long long audioStart = tag ? tag.endOffset : 0;

    NSMutableData *body = [NSMutableData data];
    for (CCId3Frame *frame in tag.frames)
        if (![frame.identifier isEqualToString:@"USLT"]) [body appendData:frame.raw];
    AppendFrame(body, version, "USLT", LyricsBody(version, lyrics));
    [body increaseLengthBy:kPadding];

    NSUInteger size = body.length;
    uint8_t header[kHeaderSize] = { 'I', 'D', '3', version, 0, 0, (size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F };
    NSMutableData *output = [NSMutableData dataWithBytes:header length:kHeaderSize];
    [output appendData:body];

    NSString *tmp = [file stringByAppendingString:@".tagging"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createFileAtPath:tmp contents:output attributes:nil]) {
        if (error) *error = Id3Error(@"Could not write beside the file.");
        return NO;
    }
    BOOL ok = NO;
    NSError *copyFailure = nil;
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:file] error:error];
    NSFileHandle *result = input ? [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:tmp] error:error] : nil;
    if (result) {
        ok = [result seekToEndReturningOffset:NULL error:error] && [input seekToOffset:audioStart error:error];
        while (ok) {
            @autoreleasepool {
                // A local error: an autoreleased one would not outlive this pool.
                NSError *failure = nil;
                NSData *chunk = [input readDataUpToLength:1 << 20 error:&failure];
                if (!chunk) ok = NO;
                else if (chunk.length == 0) break;
                else ok = [result writeData:chunk error:&failure];
                if (!ok) copyFailure = failure;
            }
        }
        if (copyFailure && error) *error = copyFailure;
        [result closeFile];
    }
    [input closeFile];
    if (ok && rename(tmp.fileSystemRepresentation, file.fileSystemRepresentation) != 0) {
        ok = NO;
        if (error) *error = Id3Error(@"Could not replace the file.");
    }
    if (!ok) [fm removeItemAtPath:tmp error:nil];
    return ok;
}

@end

// ───────────── writer ─────────────

@implementation CCLyricsOptions
+ (instancetype)embed:(BOOL)embed sidecar:(BOOL)sidecar timedInTag:(BOOL)timed {
    CCLyricsOptions *o = [CCLyricsOptions new];
    o.embed = embed;
    o.sidecar = sidecar;
    o.timedInTag = timed;
    return o;
}
@end

@implementation CCLyricsWriter

static NSString *PlainFromTimed(NSString *timed) {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [timed componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSRange close = [line rangeOfString:@"]"];
        [lines addObject:close.location == NSNotFound ? line : [line substringFromIndex:close.location + 1]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

+ (CCLyricsResult)apply:(CCSong *)song to:(NSString *)file options:(CCLyricsOptions *)options {
    return [self applyWords:song.lyrics synced:song.syncedLyrics to:file options:options replace:NO];
}

static NSString *Beside(NSString *file, NSString *extension) { return [file.stringByDeletingPathExtension stringByAppendingPathExtension:extension]; }

+ (CCLyricsResult)applyWords:(NSString *)words synced:(NSString *)synced to:(NSString *)file options:(CCLyricsOptions *)options replace:(BOOL)replace {
    NSString *timed = [CCLrc normalize:synced];
    NSString *plain = HasText(words) ? [CCLrc plain:words] : timed ? [CCLrc plain:PlainFromTimed(timed)] : nil;
    if (!plain) return CCLyricsResultNone;

    CCLyricsResult result = CCLyricsResultAlreadyThere;
    BOOL tagged = NO;
    NSError *error = nil;
    if (options.embed) {
        BOOL can = [CCId3Lyrics canTag:file error:&error];
        if (error) return CCLyricsResultFailed;
        if (can) {
            tagged = YES;
            BOOL has = !replace && [CCId3Lyrics has:file error:&error];
            if (error) return CCLyricsResultFailed;
            if (!has) {
                if (![CCId3Lyrics write:options.timedInTag && timed ? timed : plain to:file error:&error]) return CCLyricsResultFailed;
                result = CCLyricsResultWritten;
            }
        }
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *lrc = Beside(file, @"lrc"), *txt = Beside(file, @"txt");
    if (options.sidecar || !tagged) {
        if (replace || (![fm fileExistsAtPath:lrc] && ![fm fileExistsAtPath:txt])) {
            [fm removeItemAtPath:lrc error:nil];
            [fm removeItemAtPath:txt error:nil];
            NSData *data = [timed ?: plain dataUsingEncoding:NSUTF8StringEncoding];
            if (![data writeToFile:timed ? lrc : txt options:NSDataWritingAtomic error:&error]) return CCLyricsResultFailed;
            result = CCLyricsResultWritten;
        }
    }
    return result;
}

+ (BOOL)has:(NSString *)file {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:Beside(file, @"lrc")] || [fm fileExistsAtPath:Beside(file, @"txt")]) return YES;
    NSError *error = nil;
    return [CCId3Lyrics canTag:file error:&error] && [CCId3Lyrics has:file error:&error];
}

@end
