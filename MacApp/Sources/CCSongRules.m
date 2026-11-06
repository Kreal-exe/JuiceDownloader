#import "CCSongRules.h"
#import "CCLibrary.h"

#define REGEX(name, pattern, opts)                                                                            \
    static NSRegularExpression *name(void) {                                                                  \
        static NSRegularExpression *re;                                                                       \
        static dispatch_once_t once;                                                                          \
        dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:pattern options:opts error:nil]; }); \
        return re;                                                                                            \
    }
#define IC NSRegularExpressionCaseInsensitive
REGEX(Extension, @"\\.[A-Za-z0-9]{2,4}$", 0)
REGEX(TakeBracket, @"[\\(\\[\\{]\\s*(feat\\.?|ft\\.?|with\\b|prod\\.?|v\\d+\\b|session|sessions|demo|og\\b)[^\\)\\]\\}]*[\\)\\]\\}]", IC)
REGEX(TakeOnly, @"[\\(\\[\\{]\\s*v\\d+\\s*[\\)\\]\\}]", IC)
REGEX(TrailingCredit, @"\\b(feat|ft|prod)\\b\\.?.*$", IC)
REGEX(Spaces, @"\\s+", 0)
REGEX(NotASong, @"instrumental|acapella|a cappella|\\bstems?\\b|\\bbeat\\b|\\bsnippet\\b", IC)
REGEX(Complete, @"\\b(complete|completed)\\b", IC)
REGEX(Unfinished, @"hook only|empty project|snippet", IC)
REGEX(OpenVerse, @"open verse", IC)
REGEX(Unexported, @"unexported|unbounced", IC)

static NSString *Replace(NSRegularExpression *re, NSString *text, NSString *with) {
    return [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:with];
}
static BOOL IsMatch(NSRegularExpression *re, NSString *text) { return [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil; }
static NSString *Trim(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }

@implementation CCRuleOptions
- (instancetype)init {
    if ((self = [super init])) {
        _sections = @[ @"unreleased", @"sessionEdits" ];
        _skipReleased = YES;
        _oneVersion = _oneFolder = YES;
        _folderName = @"Unreleased";
    }
    return self;
}
@end

@implementation CCSongVersion
@end
@implementation CCSongGroup
@end
@implementation CCRuleResult
- (long long)bytes {
    long long sum = 0;
    for (CCSongGroup *g in self.kept) sum += g.picked.file.size;
    return sum;
}
@end

@interface CCRuleEntry : NSObject
@property (nonatomic, strong) CCCatalogNode *file;
@property (nonatomic, strong, nullable) CCSong *song;
@end
@implementation CCRuleEntry
@end

@implementation CCSongRules

+ (NSString *)songKey:(NSString *)name {
    NSString *text = Replace(Extension(), Trim(name), @"");
    text = Replace(TakeBracket(), text, @" ");
    text = Replace(TrailingCredit(), text, @" ");
    return CCLyricsFold(text);
}

/// The name a song on a self-released EP later came out under: "ALL GIRLS ARE THE SAME 999" is All Girls Are The Same.
static NSString *WithoutEraMark(NSString *key, CCSong *song) {
    if (!IsUnofficial(song)) return key;
    NSRange mark = [key rangeOfString:@"(999|3)$" options:NSRegularExpressionSearch];
    return mark.location != NSNotFound && mark.location > 0 ? [key substringToIndex:mark.location] : key;
}

static NSArray<NSString *> *Titles(CCSong *s) {
    return s.trackTitles ? [s.trackTitles arrayByAddingObject:s.name] : @[ s.name ];
}

static NSSet<NSString *> *WordSet(NSArray<CCRuleEntry *> *group) {
    NSMutableSet *lines = [NSMutableSet set];
    NSCharacterSet *breaks = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    for (CCRuleEntry *e in group)
        for (NSString *line in [(e.song.lyrics ?: @"") componentsSeparatedByCharactersInSet:breaks]) {
            NSString *folded = line.length > 0 ? CCLyricsFold(line) : @"";
            if (folded.length > 8) [lines addObject:folded];
        }
    return lines;
}

static BOOL SameWords(NSArray<CCRuleEntry *> *a, NSArray<CCRuleEntry *> *b) {
    NSSet *left = WordSet(a), *right = WordSet(b);
    if (left.count == 0 || right.count == 0) return NO;
    NSUInteger shared = 0;
    for (NSString *line in left) shared += [right containsObject:line];
    return shared >= 0.5 * MIN(left.count, right.count);
}

static NSInteger Seconds(NSString *length) {
    NSString *text = Trim(length ?: @"");
    if (text.length == 0) return 0;
    NSInteger total = 0;
    for (NSString *part in [text componentsSeparatedByString:@":"]) {
        NSScanner *scanner = [NSScanner scannerWithString:part];
        NSInteger n = 0;
        if (![scanner scanInteger:&n] || !scanner.atEnd) return 0;
        total = total * 60 + n;
    }
    return total;
}

/// Finished before unfinished, with words before without, real sound before a low bitrate, the fuller take last.
static CCSongVersion *Rate(CCRuleEntry *entry) {
    CCSong *song = entry.song;
    NSInteger score = 0;
    NSMutableArray *why = [NSMutableArray array];
    NSString *leak = song.leakType ?: @"";
    if (IsMatch(Complete(), leak)) { score += 1000; [why addObject:@"complete"]; }
    if (IsMatch(Unfinished(), leak)) { score -= 1000; [why addObject:@"unfinished"]; }
    else if (IsMatch(OpenVerse(), leak)) { score -= 500; [why addObject:@"open verse"]; }
    if (IsMatch(Unexported(), leak)) { score -= 200; [why addObject:@"unexported"]; }
    if (song && [CCLyricsIndex hasWords:song]) { score += 100; [why addObject:@"has words"]; }

    NSInteger seconds = Seconds(song.length);
    if (seconds > 0) {
        long long kbps = entry.file.size * 8 / 1000 / seconds;
        if (kbps >= 256) { score += 50; [why addObject:@"320 kbps"]; }
        else if (kbps < 160) score -= 50;
        score += MIN(seconds / 30, 15); // a longer take holds more of the song
    }
    score += MIN((NSInteger)song.lyrics.length / 500, 10);
    CCSongVersion *v = [CCSongVersion new];
    v.file = entry.file;
    v.song = song;
    v.score = song ? score : score - 3000;   // a file the API describes beats one it knows nothing about
    v.why = [why componentsJoinedByString:@", "];
    return v;
}

static NSString *TitleOf(NSArray<CCRuleEntry *> *group) {
    NSString *name = group[0].song.name ?: group[0].file.name.stringByDeletingPathExtension;
    return Trim(Replace(Spaces(), Replace(TakeOnly(), name, @" "), @" "));
}

/// A song's title alone: no mix, take, credit or extension, so that "Big (TV Mix) [v1].mp3" is the album's "Big".
static NSString *BareTitle(NSString *name) {
    static NSRegularExpression *brackets, *credits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        brackets = [NSRegularExpression regularExpressionWithPattern:@"[(\\[{][^)\\]}]*[)\\]}]" options:0 error:nil];
        credits = [NSRegularExpression regularExpressionWithPattern:@"\\s(feat\\.?|ft\\.?|featuring|prod\\.?|with)\\s.*$" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSString *text = name.pathExtension.length <= 4 ? name.stringByDeletingPathExtension : name;
    text = [brackets stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    text = [credits stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    text = [text stringByReplacingOccurrencesOfString:@"\\s+v\\d+\\s*$" withString:@"" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
    return CCLyricsFold(text);
}

static BOOL IsUnofficial(CCSong *song) {
    return song.leakType && [song.leakType rangeOfString:@"Unofficial" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

+ (CCRuleResult *)apply:(CCCatalog *)catalog songs:(NSArray<CCSong *> *)songs options:(CCRuleOptions *)options {
    NSMutableDictionary<NSString *, CCSong *> *byPath = [NSMutableDictionary dictionary];
    NSMutableSet *released = [NSMutableSet set];
    for (CCSong *s in songs) {
        if (s.path.length > 0) byPath[s.path] = s;
        // By the name it came out under: its working titles often belong to other songs too, "Motions" among HeMotions's.
        if ([s.category isEqualToString:@"released"] && !IsUnofficial(s)) {
            NSString *k = [self songKey:s.name];
            if (k.length > 0) [released addObject:k];
        }
    }

    // The API files an unofficial project under released, in the Compilations folder; its leak type tells the truth.
    // Such a file counts as unreleased, whichever page lists it.
    NSMutableArray<CCCatalogNode *> *files = [NSMutableArray array];
    BOOL (^unofficial)(CCCatalogNode *) = ^BOOL(CCCatalogNode *f) {
        CCSong *s = byPath[f.path];
        return s && IsUnofficial(s);
    };
    BOOL wantsUnreleased = [options.sections containsObject:@"unreleased"];
    NSArray *mixedPages = @[ @"compilations", @"remixes" ];
    for (NSString *identifier in options.sections) {
        if (wantsUnreleased && [mixedPages containsObject:identifier]) continue;   // sorted below
        for (CCCatalogNode *row in [catalog section:identifier].rows)
            [row forEachFile:^(CCCatalogNode *f) {
                if (!unofficial(f) && [CCLibrary isAudio:f.name] && !IsMatch(NotASong(), f.name)) [files addObject:f];
            }];
    }
    // With Unreleased on, a mixed page that is also on gives only what is unreleased: no version of a song from the
    // official discography, no bare vocals or beats, nothing made by AI. A page that is off gives nothing.
    if (wantsUnreleased) {
        NSMutableSet *official = [NSMutableSet set], *listed = [NSMutableSet set];
        for (CCSong *s in songs)
            if ([s.path hasPrefix:@"Compilation/1."] && !IsUnofficial(s)) [official addObject:BareTitle(s.name)];
        for (CCCatalogNode *f in files) [listed addObject:f.path];
        NSSet *notSongs = [NSSet setWithArray:@[ @"Acapella", @"Instrumental" ]];
        NSRegularExpression *made = [NSRegularExpression regularExpressionWithPattern:@"\\bAI\\b" options:NSRegularExpressionCaseInsensitive error:nil];
        for (NSString *identifier in mixedPages) {
            BOOL on = [options.sections containsObject:identifier];
            for (CCCatalogNode *row in [catalog section:identifier].rows) {
                if ([notSongs containsObject:row.displayName]) continue;
                [row forEachFile:^(CCCatalogNode *f) {
                    if ([listed containsObject:f.path] || ![CCLibrary isAudio:f.name] || IsMatch(NotASong(), f.name)) return;
                    if (unofficial(f)) [files addObject:f];   // a tagged unofficial release is unreleased, whichever page is on
                    else if (on && ![official containsObject:BareTitle(f.name)] && ![made firstMatchInString:f.name options:0 range:NSMakeRange(0, f.name.length)]) [files addObject:f];
                }];
            }
        }
    }

    if (options.neverOffer.count > 0) {
        NSSet *refused = [NSSet setWithArray:options.neverOffer];
        [files filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CCCatalogNode *f, NSDictionary *bindings) { return ![refused containsObject:f.path]; }]];
    }

    // Keys in the order they first appear, as the C# dictionary keeps them.
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<CCRuleEntry *> *> *groups = [NSMutableDictionary dictionary];
    for (CCCatalogNode *file in files) {
        CCRuleEntry *e = [CCRuleEntry new];
        e.file = file;
        e.song = byPath[file.path];
        // With no tag to go by, the title alone says which song it is: "(Prod. X)", "(1)" and "(New Remaster)" are versions.
        NSString *key = e.song ? [self songKey:e.song.name] : BareTitle(file.name);
        // A session is its own recording, with its own words, never a take of the finished song; and every one is wanted.
        if (key.length == 0 || [CCLyricsIndex isSessionFile:file.path]) key = file.path;
        NSMutableArray *list = groups[key];
        if (!list) {
            groups[key] = list = [NSMutableArray array];
            [order addObject:key];
        }
        [list addObject:e];
    }

    // Another title of a song counts only when the words agree.
    for (NSString *key in [order copy]) {
        NSMutableArray<CCRuleEntry *> *group = groups[key];
        if (!group) continue;
        NSMutableOrderedSet *others = [NSMutableOrderedSet orderedSet];
        for (CCRuleEntry *e in group)
            if (e.song)
                for (NSString *t in Titles(e.song)) {
                    NSString *k = [self songKey:t];
                    if (k.length > 0 && ![k isEqualToString:key]) [others addObject:k];
                }
        for (NSString *other in others) {
            NSMutableArray *twin = groups[other];
            if (!twin || !SameWords(group, twin)) continue;
            [group addObjectsFromArray:twin];
            [groups removeObjectForKey:other];
            [order removeObject:other];
        }
    }

    CCRuleResult *result = [CCRuleResult new];
    NSMutableArray<CCSongGroup *> *kept = [NSMutableArray array];
    for (NSString *key in order) {
        NSArray<CCRuleEntry *> *list = groups[key];
        NSMutableArray<CCSongVersion *> *versions = [NSMutableArray array];
        for (CCRuleEntry *e in list) [versions addObject:Rate(e)];
        [versions sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(CCSongVersion *a, CCSongVersion *b) {
            if (a.score != b.score) return a.score > b.score ? NSOrderedAscending : NSOrderedDescending;
            return [a.file.name compare:b.file.name options:NSLiteralSearch];
        }];
        BOOL isReleased = NO, isUnfinished = YES;
        for (CCRuleEntry *e in list) {
            NSString *songKey = [self songKey:e.song.name ?: e.file.name];
            if (![CCLyricsIndex isSessionFile:e.file.path] && ([released containsObject:songKey] || (e.song && [released containsObject:WithoutEraMark(songKey, e.song)]))) isReleased = YES;
            if (!IsMatch(Unfinished(), e.song.leakType ?: @"")) isUnfinished = NO;
        }
        if (options.skipReleased && isReleased) { result.skippedReleased += (NSInteger)versions.count; continue; }
        if (options.skipUnfinished && isUnfinished) { result.skippedUnfinished += (NSInteger)versions.count; continue; }
        if (options.oneVersion) {
            result.skippedVersions += (NSInteger)versions.count - 1;
            CCSongGroup *g = [CCSongGroup new];
            g.title = TitleOf(list);
            g.versions = versions;
            g.picked = versions[0];
            g.isReleasedSong = isReleased;
            g.isUnfinished = isUnfinished;
            [kept addObject:g];
        } else {
            for (CCSongVersion *v in versions) {
                CCSongGroup *g = [CCSongGroup new];
                g.title = v.file.name;
                g.versions = @[ v ];
                g.picked = v;
                [kept addObject:g];
            }
        }
    }
    [kept sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(CCSongGroup *a, CCSongGroup *b) {
        NSInteger c = [CCCatalog naturalCompare:a.title with:b.title];
        return c < 0 ? NSOrderedAscending : c > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
    result.kept = kept;
    result.filesConsidered = (NSInteger)files.count;
    return result;
}

+ (NSString *)listOf:(NSArray<CCDownloadFile *> *)files {
    if (files.count == 0) return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:files.count];
    for (CCDownloadFile *f in files) [names addObject:f.apiPath.lastPathComponent.stringByDeletingPathExtension];
    [names sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return [names componentsJoinedByString:@"\n"];
}

+ (NSArray<CCDownloadFile *> *)files:(NSArray<CCSongGroup *> *)groups options:(CCRuleOptions *)options {
    NSMutableSet *used = [NSMutableSet set];
    NSMutableArray *files = [NSMutableArray array];
    for (CCSongGroup *group in groups) {
        CCCatalogNode *file = group.picked.file;
        NSString *target = nil;
        if (options.oneFolder) {
            NSString *name = file.name;
            for (NSInteger n = 2; [used containsObject:name.lowercaseString]; n++) {
                NSString *extension = file.name.pathExtension;
                name = [NSString stringWithFormat:@"%@ %ld%@", file.name.stringByDeletingPathExtension, (long)n, extension.length ? [@"." stringByAppendingString:extension] : @""];
            }
            [used addObject:name.lowercaseString];
            target = [NSString stringWithFormat:@"%@/%@", options.folderName, name];
        }
        [files addObject:[CCDownloadFile path:file.path size:file.size target:target]];
    }
    return files;
}

@end

@implementation CCAudioCopies

static const long long kSample = 65536;

static long long TagSize(NSData *data) {
    if (data.length < 10) return 0;
    const uint8_t *h = data.bytes;
    if (h[0] != 'I' || h[1] != 'D' || h[2] != '3') return 0;
    return 10LL + (((long long)h[6] << 21) | ((long long)h[7] << 14) | ((long long)h[8] << 7) | h[9]) + ((h[5] & 0x10) ? 10 : 0);
}

/// NO with *known NO when the bytes could not be had.
static BOOL SameAudio(CCCatalogNode *a, CCCatalogNode *b, CCApiClient *api, CCCancel *cancel, BOOL *known) {
    *known = NO;
    NSData *headA = [api bytesOf:a.path from:0 to:9 cancel:cancel error:nil];
    NSData *headB = headA ? [api bytesOf:b.path from:0 to:9 cancel:cancel error:nil] : nil;
    if (!headB) return NO;
    long long tagA = TagSize(headA), tagB = TagSize(headB);
    long long audioA = a.size - tagA, audioB = b.size - tagB;
    if (audioA != audioB || audioA <= 0) {
        *known = YES;
        return NO;
    }
    long long middle = MAX(0, audioA / 2 - kSample / 2);
    long long length = MIN(kSample, audioA) - 1;
    NSData *left = [api bytesOf:a.path from:tagA + middle to:tagA + middle + length cancel:cancel error:nil];
    NSData *right = left ? [api bytesOf:b.path from:tagB + middle to:tagB + middle + length cancel:cancel error:nil] : nil;
    if (!right) return NO;
    *known = YES;
    return [left isEqualToData:right];
}

static NSString *PairKey(CCSongGroup *a, CCSongGroup *b) { return [NSString stringWithFormat:@"%@\n%@", a.picked.file.path, b.picked.file.path]; }

+ (CCRuleResult *)remove:(CCRuleResult *)result index:(CCLyricsIndex *)index api:(CCApiClient *)api same:(NSMutableDictionary *)same cancel:(CCCancel *)cancel {
    // Pairs that may be one recording: the same song by its words, or the same size.
    NSMutableArray *order = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSMutableArray<CCSongGroup *> *> *bySong = [NSMutableDictionary dictionary], *bySize = [NSMutableDictionary dictionary];
    for (CCSongGroup *g in result.kept) {
        CCLyricsMatch *match = [index find:g.picked.file.path];
        NSNumber *songKey = @(match ? match.song.identifier : -g.picked.file.size);
        if (!bySong[songKey]) {
            bySong[songKey] = [NSMutableArray array];
            [order addObject:songKey];
        }
        [bySong[songKey] addObject:g];
    }
    NSMutableArray *sizeOrder = [NSMutableArray array];
    for (CCSongGroup *g in result.kept) {
        NSNumber *sizeKey = @(g.picked.file.size);
        if (!bySize[sizeKey]) {
            bySize[sizeKey] = [NSMutableArray array];
            [sizeOrder addObject:sizeKey];
        }
        [bySize[sizeKey] addObject:g];
    }
    NSMutableArray<NSArray<CCSongGroup *> *> *pairs = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^addPairs)(NSArray<CCSongGroup *> *) = ^(NSArray<CCSongGroup *> *list) {
        for (NSUInteger i = 0; i < list.count; i++)
            for (NSUInteger j = i + 1; j < list.count; j++) {
                if ([seen containsObject:PairKey(list[i], list[j])] || [seen containsObject:PairKey(list[j], list[i])]) continue;
                [seen addObject:PairKey(list[i], list[j])];
                [pairs addObject:@[ list[i], list[j] ]];
            }
    };
    for (NSNumber *key in order) addPairs(bySong[key]);
    for (NSNumber *key in sizeOrder) addPairs(bySize[key]);

    // Side by side: each answer is four small requests, and a first run has dozens of pairs to ask about.
    NSLock *lock = [NSLock new];
    __block NSUInteger next = 0;
    dispatch_group_t workers = dispatch_group_create();
    NSInteger threads = MIN(16, (NSInteger)pairs.count);
    for (NSInteger i = 0; i < threads; i++) {
        dispatch_group_enter(workers);
        [NSThread detachNewThreadWithBlock:^{
            while (!cancel.cancelled) {
                [lock lock];
                NSArray<CCSongGroup *> *pair = nil;
                while (next < pairs.count && !pair) {
                    NSArray<CCSongGroup *> *candidate = pairs[next++];
                    if (!same[PairKey(candidate[0], candidate[1])]) pair = candidate;
                }
                [lock unlock];
                if (!pair) break;
                @autoreleasepool {
                    BOOL known = NO;
                    BOOL alike = SameAudio(pair[0].picked.file, pair[1].picked.file, api, cancel, &known);
                    // Unknown stays unknown: keeping a copy costs a few megabytes, losing a song costs the song.
                    if (known) {
                        [lock lock];
                        same[PairKey(pair[0], pair[1])] = @(alike);
                        [lock unlock];
                    }
                }
            }
            dispatch_group_leave(workers);
        }];
    }
    dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);

    NSHashTable *gone = [NSHashTable weakObjectsHashTable];
    for (NSArray<CCSongGroup *> *pair in pairs) {
        if ([gone containsObject:pair[0]] || [gone containsObject:pair[1]]) continue;
        // The plainer name stays: "Break" over "On And On (Break)".
        if ([same[PairKey(pair[0], pair[1])] boolValue])
            [gone addObject:pair[0].picked.file.name.length <= pair[1].picked.file.name.length ? pair[1] : pair[0]];
    }
    if (gone.count == 0) return result;
    NSMutableArray *kept = [NSMutableArray array];
    for (CCSongGroup *g in result.kept)
        if (![gone containsObject:g]) [kept addObject:g];
    CCRuleResult *cleaned = [CCRuleResult new];
    cleaned.kept = kept;
    cleaned.filesConsidered = result.filesConsidered;
    cleaned.skippedVersions = result.skippedVersions;
    cleaned.skippedReleased = result.skippedReleased;
    cleaned.skippedUnfinished = result.skippedUnfinished;
    cleaned.skippedCopies = (NSInteger)gone.count;
    return cleaned;
}

@end

@implementation CCCatalogRelations {
    NSMutableDictionary<NSString *, NSMutableArray<CCCatalogNode *> *> *_bySong;
}

- (instancetype)initWithCatalog:(CCCatalog *)catalog {
    if ((self = [super init])) {
        _bySong = [NSMutableDictionary dictionary];
        NSMutableDictionary *map = _bySong;
        [catalog.root forEachFile:^(CCCatalogNode *file) {
            if (![CCLibrary isPlayable:file.name] && [file.name.pathExtension caseInsensitiveCompare:@"zip"] != NSOrderedSame) return;
            @autoreleasepool {
                NSString *key = [CCLyricsIndex key:file.name loose:YES];
                if (key.length == 0) return;
                NSMutableArray *list = map[key];
                if (!list) map[key] = list = [NSMutableArray array];
                [list addObject:file];
            }
        }];
    }
    return self;
}

- (NSArray<CCCatalogNode *> *)of:(CCCatalogNode *)file {
    NSMutableArray *others = [NSMutableArray array];
    for (CCCatalogNode *f in _bySong[[CCLyricsIndex key:file.name loose:YES]])
        if (f != file) [others addObject:f];
    return others;
}

+ (NSString *)place:(CCCatalogNode *)file {
    NSMutableArray *names = [NSMutableArray array];
    for (CCCatalogNode *n = file.parent; n && n.name.length > 0; n = n.parent) [names insertObject:n.displayName atIndex:0];
    return [names componentsJoinedByString:@" › "];
}

@end
