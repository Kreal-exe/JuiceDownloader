#import "CCWebLyrics.h"

static NSString *const kArtist = @"Juice WRLD";
static const double kSameName = 0.85;

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
REGEX(CreditBracket, @"[\\(\\[\\{]\\s*(feat\\.?|ft\\.?|with |prod\\.?|best|master|remaster|rough|og\\b|explicit|clean)", IC)
REGEX(TrailingCredit, @"\\b(feat|ft|prod)\\b\\.?.*$", IC)
REGEX(SessionWord, @"\\b(studio\\s+)?sessions?(\\s+edit)?\\b", IC)
REGEX(VersionWord, @"\\bv(\\d+)\\b(?!\\.\\d)", IC)
REGEX(Spaces, @"\\s+", 0)
REGEX(GuestCredit, @"[\\(\\[\\{]\\s*(?:feat\\.?|ft\\.?|with)\\s+([^\\)\\]\\}]*)[\\)\\]\\}]", IC)
REGEX(GuestSplit, @"\\s*(?:,|&|\\band\\b)\\s*", IC)
REGEX(BlankRun, @"\\n{3,}", 0)
REGEX(Container, @"<div[^>]*\\bdata-lyrics-container=\"true\"[^>]*>", IC)
REGEX(Excluded, @"<div[^>]*\\bdata-exclude-from-selection=\"true\"[^>]*>", IC)
REGEX(DivTag, @"<(/?)div\\b", IC)
REGEX(LineBreak, @"<br\\s*/?>", IC)
REGEX(BlockEnd, @"</(?:div|p)>", IC)
REGEX(AnyTag, @"<[^>]*>", 0)
REGEX(LrcLine, @"^\\s*((?:\\[\\d{1,3}:\\d{2}(?:[.:]\\d{1,3})?\\])+)\\s*(.*)$", 0)
REGEX(LrcCredit, @"^(?:作词|作曲|编曲|制作人?|混音|母带|录音|和声|监制|出品|发行|企划|统筹|吉他|贝斯|鼓|键盘|弦乐|词|曲|lyricist|lyrics by|composer|composed by|arranger|producer|produced by|mix(?:ed|ing)?(?: by)?|master(?:ed|ing)?(?: by)?|recording)\\s*[:：]", IC)
REGEX(SlugBreak, @"[^a-z0-9]+", 0)
REGEX(Entity, @"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);", 0)

static NSString *Replace(NSRegularExpression *re, NSString *text, NSString *with) {
    return [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:with];
}
static BOOL IsMatch(NSRegularExpression *re, NSString *text) { return [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil; }
static NSString *Trim(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
static NSString *Str(id object, NSString *key) {
    id v = [object isKindOfClass:NSDictionary.class] ? object[key] : nil;
    return [v isKindOfClass:NSString.class] ? v : @"";
}
static NSString *Escape(NSString *s) {
    static NSCharacterSet *unreserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ unreserved = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]; });
    return [s stringByAddingPercentEncodingWithAllowedCharacters:unreserved];
}
static NSInteger VersionOf(NSString *name) {
    NSTextCheckingResult *m = [VersionWord() firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
    return m ? [name substringWithRange:[m rangeAtIndex:1]].integerValue : NSNotFound;
}

@implementation CCWebMatch
@end
@implementation CCWebLyricsResult
- (instancetype)init {
    if ((self = [super init])) _failed = @[];
    return self;
}
@end

@interface CCWebCandidate : NSObject
@property (nonatomic, copy) NSString *artist, *title, *lyrics;
@property (nonatomic, copy, nullable) NSString *synced, *url;
@end
@implementation CCWebCandidate
+ (instancetype)artist:(NSString *)artist title:(NSString *)title lyrics:(NSString *)lyrics synced:(NSString *)synced url:(NSString *)url {
    CCWebCandidate *c = [CCWebCandidate new];
    c.artist = artist;
    c.title = title;
    c.lyrics = lyrics;
    c.synced = synced;
    c.url = url;
    return c;
}
@end

typedef NS_ENUM(NSInteger, CCVerdict) { CCVerdictWrong, CCVerdictSame, CCVerdictOther };

static const NSInteger kNoStatus = 0;

/// A site that answers something else than it should has failed, as much as one that does not answer.
static id Unexpected(NSError **error) {
    if (error) *error = [NSError errorWithDomain:CCErrorDomain code:CCErrorData userInfo:@{ NSLocalizedDescriptionKey: @"unexpected answer" }];
    return nil;
}

@implementation CCWebLyrics {
    NSURLSession *_session;
    NSDictionary<NSString *, NSLock *> *_gates;
    NSMutableDictionary<NSString *, NSNumber *> *_next;
    NSTimeInterval _geniusRestsUntil;
}

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {
    if ((self = [super init])) {
        NSURLSessionConfiguration *c = configuration ?: NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.timeoutIntervalForRequest = 20;
        c.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:c];
        _paced = YES;
        _gates = @{ @"LRCLIB": [NSLock new], @"NetEase": [NSLock new], @"Genius": [NSLock new], @"lyrics.ovh": [NSLock new] };
        _next = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc { [_session finishTasksAndInvalidate]; }

// ───────────── the network ─────────────

- (void)pace:(NSString *)source cancel:(CCCancel *)cancel {
    if (!self.paced) return;
    NSDictionary *gaps = @{ @"LRCLIB": @0.25, @"NetEase": @0.15, @"Genius": @0.7, @"lyrics.ovh": @0.4 };
    NSLock *gate = _gates[source];
    [gate lock];
    NSTimeInterval next;
    @synchronized (_next) { next = _next[source].doubleValue; }
    NSTimeInterval wait = next - NSProcessInfo.processInfo.systemUptime;
    if (wait > 0) {
        if (cancel) [cancel sleep:wait];
        else [NSThread sleepForTimeInterval:wait];
    }
    @synchronized (_next) { _next[source] = @(NSProcessInfo.processInfo.systemUptime + [gaps[source] doubleValue]); }
    [gate unlock];
}

/// One GET. status is the HTTP status; nil data with error when there was no answer at all.
- (NSData *)get:(NSString *)url accept:(NSString *)accept cancel:(CCCancel *)cancel status:(NSInteger *)status error:(NSError **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:CCApiClient.userAgent forHTTPHeaderField:@"User-Agent"];
    if (accept) [request setValue:accept forHTTPHeaderField:@"Accept"];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSHTTPURLResponse *response = nil;
    __block NSError *failure = nil;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        body = d;
        response = (NSHTTPURLResponse *)r;
        failure = e;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 20;
    BOOL sent = NO;
    while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (sent) continue;
        if (cancel.cancelled || NSProcessInfo.processInfo.systemUptime > deadline) {
            sent = YES;
            [task cancel];
        }
    }
    *status = response.statusCode;
    if (failure) {
        if (error) *error = failure.code == NSURLErrorCancelled && !cancel.cancelled
            ? [NSError errorWithDomain:CCErrorDomain code:CCErrorData userInfo:@{ NSLocalizedDescriptionKey: @"timed out" }] : failure;
        return nil;
    }
    return body ?: [NSData data];
}

/// YES with *json nil for a 404 where that means "nothing here".
- (BOOL)json:(NSString *)source url:(NSString *)url notFoundIsEmpty:(BOOL)notFoundIsEmpty cancel:(CCCancel *)cancel status:(NSInteger *)status result:(id *)json error:(NSError **)error {
    [self pace:source cancel:cancel];
    *json = nil;
    NSData *body = [self get:url accept:@"application/json" cancel:cancel status:status error:error];
    if (!body) return NO;
    if (notFoundIsEmpty && *status == 404) return YES;
    if (*status < 200 || *status >= 300) {
        if (error) *error = [NSError errorWithDomain:CCErrorDomain code:CCErrorHTTP userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"replied %ld", (long)*status] }];
        return NO;
    }
    *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:error];
    return *json != nil;
}

// ───────────── the sources ─────────────

static BOOL CreditsHim(NSString *artist, NSArray<NSString *> *guests) {
    NSString *folded = CCLyricsFold(artist);
    for (NSString *name in @[ @"juicewrld", @"juiceworld", @"juicethekid", @"juicedakid" ])
        if ([folded containsString:name]) return YES;
    for (NSString *guest in guests) {
        NSString *f = CCLyricsFold(guest);
        if (f.length > 2 && [folded containsString:f]) return YES;
    }
    return NO;
}

- (NSArray<CCWebCandidate *> *)lrclib:(NSString *)search bare:(NSString *)bare guests:(NSArray *)guests cancel:(CCCancel *)cancel error:(NSError **)error {
    NSArray *queries = @[ [NSString stringWithFormat:@"artist_name=%@&track_name=%@", Escape(kArtist), Escape(search)],
                          [@"q=" stringByAppendingString:Escape([NSString stringWithFormat:@"%@ %@", kArtist, search])] ];
    for (NSString *query in queries) {
        id doc = nil;
        NSInteger status = kNoStatus;
        if (![self json:@"LRCLIB" url:[@"https://lrclib.net/api/search?" stringByAppendingString:query] notFoundIsEmpty:YES cancel:cancel status:&status result:&doc error:error]) return nil;
        if (!doc) continue;
        if (![doc isKindOfClass:NSArray.class]) return Unexpected(error);
        NSMutableArray *list = [NSMutableArray array];
        for (id e in doc) {
            if (![e isKindOfClass:NSDictionary.class] || [e[@"instrumental"] isEqual:@YES]) continue;
            NSString *plain = Str(e, @"plainLyrics");
            if (plain.length == 0) continue;
            [list addObject:[CCWebCandidate artist:Str(e, @"artistName") title:Str(e, @"trackName") lyrics:plain synced:Str(e, @"syncedLyrics") url:nil]];
        }
        if (list.count > 0) return list;
    }
    return @[];
}

- (NSArray<CCWebCandidate *> *)netease:(NSString *)search bare:(NSString *)bare guests:(NSArray *)guests cancel:(CCCancel *)cancel error:(NSError **)error {
    id doc = nil;
    NSInteger status = kNoStatus;
    NSString *url = [NSString stringWithFormat:@"https://music.163.com/api/search/get?s=%@&type=1&limit=8", Escape([NSString stringWithFormat:@"%@ %@", kArtist, search])];
    if (![self json:@"NetEase" url:url notFoundIsEmpty:NO cancel:cancel status:&status result:&doc error:error]) return nil;
    NSMutableArray *list = [NSMutableArray array];
    id result = [doc isKindOfClass:NSDictionary.class] ? doc[@"result"] : nil;
    id songs = [result isKindOfClass:NSDictionary.class] ? result[@"songs"] : nil;
    if (!songs) return list;
    if (![songs isKindOfClass:NSArray.class]) return Unexpected(error);
    NSInteger opened = 0;
    for (id song in songs) {
        NSString *title = Str(song, @"name");
        NSMutableArray *names = [NSMutableArray array];
        id artists = [song isKindOfClass:NSDictionary.class] ? song[@"artists"] : nil;
        if ([artists isKindOfClass:NSArray.class])
            for (id a in artists) [names addObject:Str(a, @"name")];
        NSString *artist = [names componentsJoinedByString:@" & "];
        if (!CreditsHim(artist, guests) || [CCWebLyrics similarity:CCLyricsFold([CCWebLyrics bare:title]) to:CCLyricsFold(bare)] < kSameName) continue;
        if (++opened > 2) break;
        if (![song[@"id"] isKindOfClass:NSNumber.class]) return Unexpected(error);
        long long identifier = [song[@"id"] longLongValue];
        id words = nil;
        if (![self json:@"NetEase" url:[NSString stringWithFormat:@"https://music.163.com/api/song/lyric?id=%lld&lv=1&kv=1&tv=-1", identifier] notFoundIsEmpty:NO cancel:cancel status:&status result:&words error:error]) return nil;
        id lrc = [words isKindOfClass:NSDictionary.class] ? words[@"lrc"] : nil;
        if (!lrc) continue;
        NSString *plain, *timed;
        [CCWebLyrics neteaseWords:Str(lrc, @"lyric") plain:&plain timed:&timed];
        if (plain.length > 0) [list addObject:[CCWebCandidate artist:artist title:title lyrics:plain synced:timed url:[NSString stringWithFormat:@"https://music.163.com/#/song?id=%lld", identifier]]];
    }
    return list;
}

- (NSString *)geniusPage:(NSString *)url cancel:(CCCancel *)cancel error:(NSError **)error {
    [self pace:@"Genius" cancel:cancel];
    NSInteger status = kNoStatus;
    NSData *body = [self get:url accept:nil cancel:cancel status:&status error:error];
    if (!body) return nil;
    if (status == 404) return @"";
    if (status < 200 || status >= 300) {
        if (error) *error = [NSError errorWithDomain:CCErrorDomain code:CCErrorHTTP userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"replied %ld", (long)status] }];
        return nil;
    }
    return [CCWebLyrics geniusLyrics:[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @""];
}

- (NSArray<CCWebCandidate *> *)geniusByAddress:(NSString *)bare cancel:(CCCancel *)cancel {
    NSString *slug = [CCWebLyrics slug:[NSString stringWithFormat:@"%@ %@", kArtist, bare]];
    if (slug.length == 0) return nil;
    NSString *url = [NSString stringWithFormat:@"https://genius.com/%@-lyrics", slug];
    NSString *words = [self geniusPage:url cancel:cancel error:nil];
    return words.length > 0 ? @[ [CCWebCandidate artist:kArtist title:bare lyrics:words synced:nil url:url] ] : nil;
}

- (NSArray<CCWebCandidate *> *)genius:(NSString *)search bare:(NSString *)bare guests:(NSArray *)guests cancel:(CCCancel *)cancel error:(NSError **)error {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL resting;
    @synchronized (self) { resting = now < _geniusRestsUntil; }
    if (resting) {
        NSArray *byAddress = [self geniusByAddress:bare cancel:cancel];
        if (!byAddress && error) *error = [NSError errorWithDomain:CCErrorDomain code:CCErrorData userInfo:@{ NSLocalizedDescriptionKey: @"turning requests away" }];
        return byAddress;
    }
    id doc = nil;
    NSInteger status = kNoStatus;
    NSString *url = [@"https://genius.com/api/search/multi?q=" stringByAppendingString:Escape([NSString stringWithFormat:@"%@ %@", kArtist, search])];
    if (![self json:@"Genius" url:url notFoundIsEmpty:NO cancel:cancel status:&status result:&doc error:error]) {
        if (status == 403) {
            // It does not want this client: asking again for every track would only be rude.
            @synchronized (self) { _geniusRestsUntil = NSProcessInfo.processInfo.systemUptime + 600; }
            return nil;
        }
        if (status != 429) return nil;
        // Every further request only keeps the ban going, but the song pages are still served, at addresses made from the names.
        @synchronized (self) { _geniusRestsUntil = NSProcessInfo.processInfo.systemUptime + 180; }
        NSError *refused = error ? *error : nil;
        NSArray *byAddress = [self geniusByAddress:bare cancel:cancel];
        if (!byAddress && error) *error = refused;
        return byAddress;
    }
    NSMutableArray *list = [NSMutableArray array];
    id response = [doc isKindOfClass:NSDictionary.class] ? doc[@"response"] : nil;
    id sections = [response isKindOfClass:NSDictionary.class] ? response[@"sections"] : nil;
    if (![sections isKindOfClass:NSArray.class]) return Unexpected(error);
    NSMutableSet *seen = [NSMutableSet set];
    for (id section in sections) {
        id hits = [section isKindOfClass:NSDictionary.class] ? section[@"hits"] : nil;
        if (![hits isKindOfClass:NSArray.class]) return Unexpected(error);
        for (id hit in hits) {
            if (![Str(hit, @"type") isEqualToString:@"song"]) continue;
            id r = hit[@"result"];
            NSString *pageUrl = Str(r, @"url"), *title = Str(r, @"title"), *artist = Str(r, @"artist_names");
            if (pageUrl.length == 0 || [seen containsObject:pageUrl]) continue;
            [seen addObject:pageUrl];
            if (!CreditsHim(artist, guests) || [CCWebLyrics similarity:CCLyricsFold([CCWebLyrics bare:title]) to:CCLyricsFold(bare)] < kSameName) continue;
            NSString *words = [self geniusPage:pageUrl cancel:cancel error:error];
            if (!words) return nil;
            if (words.length > 0) [list addObject:[CCWebCandidate artist:artist title:title lyrics:words synced:nil url:pageUrl]];
            if (list.count >= 3) return list;
        }
    }
    return list;
}

// ───────────── judging ─────────────

static CCVerdict Judge(CCWebCandidate *c, NSString *bare, NSString *fileName, NSArray *guests, NSInteger version, BOOL session) {
    if (!CreditsHim(c.artist, guests)) return CCVerdictWrong;
    if ([CCWebLyrics similarity:CCLyricsFold([CCWebLyrics bare:c.title]) to:CCLyricsFold(bare)] < kSameName) return CCVerdictWrong;
    NSInteger take = VersionOf(c.title);
    if (version != NSNotFound && take != NSNotFound && take != version) return CCVerdictWrong;

    NSString *fileWords = CCLyricsFold(fileName);
    BOOL says = NO;
    for (NSTextCheckingResult *m in [Bracket() matchesInString:c.title options:0 range:NSMakeRange(0, c.title.length)]) {
        NSString *bracket = [c.title substringWithRange:m.range];
        if (IsMatch(CreditBracket(), bracket) || IsMatch(VersionWord(), bracket)) continue;
        if (IsMatch(SessionWord(), bracket)) {
            says = YES;
            continue;
        }
        // "(Remix)", "(Snippet)", a translation: another recording unless the file says the same.
        if (![fileWords containsString:CCLyricsFold(bracket)] && CCLyricsFold(bracket).length > 0) return CCVerdictWrong;
    }
    if (IsMatch(SessionWord(), c.title)) says = YES;
    if (says && !session) return CCVerdictWrong;
    if (session && !says) return CCVerdictOther;
    // A page with no take on it has the song's words, which may not be the words of the take the file names.
    return version != NSNotFound && take == NSNotFound ? CCVerdictOther : CCVerdictSame;
}

static NSArray<NSString *> *Guests(NSString *name) {
    NSMutableArray *guests = [NSMutableArray array];
    for (NSTextCheckingResult *m in [GuestCredit() matchesInString:name options:0 range:NSMakeRange(0, name.length)]) {
        NSString *list = [name substringWithRange:[m rangeAtIndex:1]];
        NSUInteger from = 0;
        for (NSTextCheckingResult *cut in [GuestSplit() matchesInString:list options:0 range:NSMakeRange(0, list.length)]) {
            [guests addObject:Trim([list substringWithRange:NSMakeRange(from, cut.range.location - from)])];
            from = NSMaxRange(cut.range);
        }
        [guests addObject:Trim([list substringFromIndex:from])];
    }
    [guests removeObject:@""];
    return guests;
}

- (CCWebLyricsResult *)find:(NSString *)path cancel:(CCCancel *)cancel {
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSString *name = path.lastPathComponent;
    NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
    name = slash.location == NSNotFound ? path : [path substringFromIndex:slash.location + 1];
    BOOL session = [CCLyricsIndex isSessionFile:path];
    NSString *bare = [CCWebLyrics bare:name];
    CCWebLyricsResult *result = [CCWebLyricsResult new];
    if (bare.length == 0) return result;
    NSArray *guests = Guests(name);
    NSInteger version = VersionOf(name);

    NSMutableArray *failed = [NSMutableArray array];
    NSString *closest = nil;
    CCWebMatch *other = nil;

    // A session goes by its own name first: a site that has it files it under "... (Sessions)".
    NSArray *searches = session ? @[ [bare stringByAppendingString:@" session"], bare ] : @[ bare ];
    NSArray *sources = @[ @"LRCLIB", @"NetEase", @"Genius" ];
    for (NSString *search in searches) {
        for (NSString *source in sources) {
            if (cancel.cancelled) return result;
            NSError *error = nil;
            NSArray<CCWebCandidate *> *found = [source isEqualToString:@"LRCLIB"] ? [self lrclib:search bare:bare guests:guests cancel:cancel error:&error]
                : [source isEqualToString:@"NetEase"] ? [self netease:search bare:bare guests:guests cancel:cancel error:&error]
                : [self genius:search bare:bare guests:guests cancel:cancel error:&error];
            if (!found) {
                if (cancel.cancelled) return result;
                NSString *reason = [NSString stringWithFormat:@"%@: %@", source, error.localizedDescription ?: @"failed"];
                if (![failed containsObject:reason]) [failed addObject:reason];
                continue;
            }
            for (CCWebCandidate *c in found) {
                CCVerdict verdict = Judge(c, bare, name, guests, version, session);
                if (verdict == CCVerdictWrong) {
                    if (!closest) closest = [NSString stringWithFormat:@"%@ - %@ (%@)", c.artist, c.title, source];
                    continue;
                }
                NSString *words = [CCWebLyrics tidy:c.lyrics];
                if (!words) continue;
                CCWebMatch *match = [CCWebMatch new];
                match.source = source;
                match.artist = c.artist;
                match.title = c.title;
                match.lyrics = words;
                match.synced = c.synced;
                match.url = c.url;
                match.fit = verdict == CCVerdictSame ? CCLyricsFitSameRecording : CCLyricsFitOtherRecording;
                if (verdict == CCVerdictSame) {
                    result.match = match;
                    result.failed = failed;
                    return result;
                }
                if (!other) other = match;
            }
        }
    }

    if (!other && !session) {
        // It is down as often as not, and says nothing about whether the words exist.
        id doc = nil;
        NSInteger status = kNoStatus;
        NSString *url = [NSString stringWithFormat:@"https://api.lyrics.ovh/v1/%@/%@", Escape(kArtist), Escape(bare)];
        if ([self json:@"lyrics.ovh" url:url notFoundIsEmpty:YES cancel:cancel status:&status result:&doc error:nil] && doc) {
            NSString *words = [CCWebLyrics tidy:Str(doc, @"lyrics")];
            if (words) {
                CCWebMatch *match = [CCWebMatch new];
                match.source = @"lyrics.ovh";
                match.artist = kArtist;
                match.title = bare;
                match.lyrics = words;
                match.fit = version == NSNotFound ? CCLyricsFitSameRecording : CCLyricsFitOtherRecording;
                result.match = match;
                result.failed = failed;
                return result;
            }
        }
    }
    result.match = other;
    result.closest = other ? nil : closest;
    result.failed = failed;
    return result;
}

// ───────────── text ─────────────

+ (NSString *)bare:(NSString *)name {
    NSString *text = Replace(Extension(), Trim(name), @"");
    text = Replace(Bracket(), text, @" ");
    text = Replace(TrailingCredit(), text, @" ");
    text = Replace(SessionWord(), text, @" ");
    text = Replace(VersionWord(), text, @" ");
    text = Replace(Spaces(), text, @" ");
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" -_"]];
}

+ (double)similarity:(NSString *)a to:(NSString *)b {
    NSUInteger la = a.length, lb = b.length;
    if (la == 0 || lb == 0) return 0;
    if ([a isEqualToString:b]) return 1;
    NSMutableData *rowData = [NSMutableData dataWithLength:(lb + 1) * sizeof(NSInteger)];
    NSInteger *row = rowData.mutableBytes;
    for (NSUInteger j = 0; j <= lb; j++) row[j] = (NSInteger)j;
    for (NSUInteger i = 1; i <= la; i++) {
        NSInteger diagonal = row[0];
        row[0] = (NSInteger)i;
        unichar ca = [a characterAtIndex:i - 1];
        for (NSUInteger j = 1; j <= lb; j++) {
            NSInteger up = row[j];
            row[j] = MIN(MIN(row[j] + 1, row[j - 1] + 1), diagonal + (ca == [b characterAtIndex:j - 1] ? 0 : 1));
            diagonal = up;
        }
    }
    return 1 - (double)row[lb] / MAX(la, lb);
}

+ (NSString *)tidy:(NSString *)text {
    if (Trim(text ?: @"").length == 0) return nil;
    NSString *unix = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray *lines = [NSMutableArray array];
    NSCharacterSet *tail = [NSCharacterSet characterSetWithCharactersInString:@" \t"];
    for (NSString *line in [unix componentsSeparatedByString:@"\n"]) {
        NSUInteger end = line.length;
        while (end > 0 && [tail characterIsMember:[line characterAtIndex:end - 1]]) end--;
        [lines addObject:[line substringToIndex:end]];
    }
    NSString *tidy = Trim(Replace(BlankRun(), [lines componentsJoinedByString:@"\n"], @"\n\n"));
    NSString *inner = [tidy stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]()"]];
    if (tidy.length < 25 || [inner caseInsensitiveCompare:@"instrumental"] == NSOrderedSame) return nil;
    return tidy;
}

/// Where the div opened just before start closes: the index of its "</div", or the end of the page.
static NSUInteger DivEnd(NSString *page, NSUInteger start) {
    __block NSInteger depth = 1;
    __block NSUInteger end = page.length;
    [DivTag() enumerateMatchesInString:page options:0 range:NSMakeRange(start, page.length - start) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        depth += [m rangeAtIndex:1].length > 0 ? -1 : 1;
        if (depth == 0) {
            end = m.range.location;
            *stop = YES;
        }
    }];
    return end;
}

static NSString *DropExcluded(NSString *fragment) {
    while (YES) {
        NSTextCheckingResult *m = [Excluded() firstMatchInString:fragment options:0 range:NSMakeRange(0, fragment.length)];
        if (!m) return fragment;
        NSUInteger end = DivEnd(fragment, NSMaxRange(m.range));
        if (end < fragment.length) end += 6; // "</div>"
        end = MIN(end, fragment.length);
        fragment = [[fragment substringToIndex:m.range.location] stringByAppendingString:[fragment substringFromIndex:end]];
    }
}

static NSString *HtmlDecode(NSString *text) {
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{ @"amp": @"&", @"lt": @"<", @"gt": @">", @"quot": @"\"", @"apos": @"'", @"nbsp": @" ", @"mdash": @"—", @"ndash": @"–", @"hellip": @"…",
                   @"rsquo": @"’", @"lsquo": @"‘", @"ldquo": @"“", @"rdquo": @"”" };
    });
    NSMutableString *out = [NSMutableString string];
    __block NSUInteger from = 0;
    [Entity() enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        NSString *body = [text substringWithRange:[m rangeAtIndex:1]];
        NSString *decoded = names[body];
        if ([body hasPrefix:@"#"]) {
            unsigned long code = [body hasPrefix:@"#x"] || [body hasPrefix:@"#X"] ? strtoul(body.UTF8String + 2, NULL, 16) : strtoul(body.UTF8String + 1, NULL, 10);
            if (code > 0 && code <= 0x10FFFF) {
                uint32_t scalar = (uint32_t)code;
                decoded = [[NSString alloc] initWithBytes:&scalar length:4 encoding:NSUTF32LittleEndianStringEncoding];
            }
        }
        if (!decoded) return;
        [out appendString:[text substringWithRange:NSMakeRange(from, m.range.location - from)]];
        [out appendString:decoded];
        from = NSMaxRange(m.range);
    }];
    [out appendString:[text substringFromIndex:from]];
    return out;
}

static NSString *HtmlText(NSString *fragment) {
    NSString *text = Replace(LineBreak(), fragment, @"\n");
    text = Replace(BlockEnd(), text, @"\n");
    text = Replace(AnyTag(), text, @"");
    return Trim(HtmlDecode(text));
}

+ (NSString *)geniusLyrics:(NSString *)page {
    NSMutableArray *parts = [NSMutableArray array];
    NSUInteger offset = 0;
    while (offset < page.length) {
        NSTextCheckingResult *open = [Container() firstMatchInString:page options:0 range:NSMakeRange(offset, page.length - offset)];
        if (!open) break;
        NSUInteger start = NSMaxRange(open.range);
        NSUInteger end = DivEnd(page, start);
        NSString *text = HtmlText(DropExcluded([page substringWithRange:NSMakeRange(start, end - start)]));
        if (text.length > 0) [parts addObject:text];
        offset = MAX(end, start);
        if (end >= page.length) break;
    }
    return [parts componentsJoinedByString:@"\n"];
}

+ (void)neteaseWords:(NSString *)lrc plain:(NSString **)plain timed:(NSString **)timed {
    *plain = @"";
    *timed = @"";
    if ([lrc containsString:@"纯音乐"]) return;
    NSMutableArray *times = [NSMutableArray array], *words = [NSMutableArray array];
    for (NSString *line in [[lrc stringByReplacingOccurrencesOfString:@"\r" withString:@""] componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *m = [LrcLine() firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!m) continue;
        NSString *text = Trim([line substringWithRange:[m rangeAtIndex:2]]);
        if (IsMatch(LrcCredit(), text)) continue;
        [times addObject:[[line substringWithRange:[m rangeAtIndex:1]] stringByAppendingString:text]];
        [words addObject:text];
    }
    NSString *joined = Trim([words componentsJoinedByString:@"\n"]);
    if (joined.length == 0) return;
    *plain = joined;
    *timed = [times componentsJoinedByString:@"\n"];
}

+ (NSString *)slug:(NSString *)names {
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    for (NSUInteger i = 0; i < names.length; i++) {
        unichar c = [names characterAtIndex:i];
        if (c > 127 && [letters characterIsMember:c]) return @"";
    }
    NSString *text = [names.lowercaseString stringByReplacingOccurrencesOfString:@"&" withString:@" and "];
    text = [[text stringByReplacingOccurrencesOfString:@"'" withString:@""] stringByReplacingOccurrencesOfString:@"’" withString:@""];
    text = [Replace(SlugBreak(), text, @"-") stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-"]];
    if (text.length == 0) return @"";
    return [[text substringToIndex:1].uppercaseString stringByAppendingString:[text substringFromIndex:1]];
}

@end
