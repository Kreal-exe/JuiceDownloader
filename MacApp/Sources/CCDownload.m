#import "CCDownload.h"
#include <stdatomic.h>
#include <stdio.h>
#include <sys/stat.h>

NSErrorDomain const CCErrorDomain = @"JuiceDownloader";

static NSError *MakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:CCErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static NSTimeInterval Now(void) { return NSProcessInfo.processInfo.systemUptime; }

// ───────────── cancellation ─────────────

@implementation CCCancel {
    NSCondition *_condition;
    BOOL _flag;
}

- (instancetype)init {
    if ((self = [super init])) _condition = [NSCondition new];
    return self;
}

- (BOOL)cancelled {
    [_condition lock];
    BOOL flag = _flag;
    [_condition unlock];
    return flag;
}

- (void)cancel {
    [_condition lock];
    _flag = YES;
    [_condition broadcast];
    [_condition unlock];
}

- (BOOL)sleep:(NSTimeInterval)seconds {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    [_condition lock];
    while (!_flag && [_condition waitUntilDate:until]) {}
    BOOL flag = _flag;
    [_condition unlock];
    return !flag;
}

@end

static BOOL Sleep(CCCancel *cancel, NSTimeInterval seconds) {
    if (seconds <= 0) return !cancel.cancelled;
    if (cancel) return [cancel sleep:seconds];
    [NSThread sleepForTimeInterval:seconds];
    return YES;
}

// ───────────── API ─────────────

static NSString *gVersion = @"1.0.0";

@implementation CCApiClient {
    NSURLSession *_session;
}

+ (NSString *)baseURL { return @"https://juicewrldapi.com/juicewrld"; }
+ (NSString *)userAgent { return [@"JuiceDownloader/" stringByAppendingString:gVersion]; }
+ (void)setVersion:(NSString *)version { gVersion = [version copy]; }

+ (NSURL *)downloadURL:(NSString *)path {
    // Uri.EscapeDataString: everything but the unreserved characters of RFC 3986.
    static NSCharacterSet *unreserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unreserved = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    NSString *escaped = [path stringByAddingPercentEncodingWithAllowedCharacters:unreserved];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/files/download/?path=%@", self.baseURL, escaped]];
}

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {
    if ((self = [super init])) {
        NSURLSessionConfiguration *c = configuration ?: NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.timeoutIntervalForRequest = 120;
        c.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:c];
        _pageDelay = 1;
        _buildingDelay = 3;
        _retryUnit = 1;
    }
    return self;
}

- (void)dealloc { [_session finishTasksAndInvalidate]; }

/// One GET, retried like the C# client: 429, 5xx and dropped connections up to three times, waiting 2, 4 and 8 s.
- (id)getJSON:(NSString *)url cancel:(CCCancel *)cancel error:(NSError **)error {
    for (NSInteger attempt = 0;; attempt++) {
        if (cancel.cancelled) {
            if (error) *error = MakeError(CCErrorCancelled, @"Cancelled");
            return nil;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        [request setValue:CCApiClient.userAgent forHTTPHeaderField:@"User-Agent"];
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
        while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0)
            if (cancel.cancelled) [task cancel];

        if (cancel.cancelled) continue;
        BOOL busy = !failure && (response.statusCode == 429 || response.statusCode >= 500);
        if ((failure || busy) && attempt < 3) {
            Sleep(cancel, (2 << attempt) * self.retryUnit);
            continue;
        }
        if (failure) {
            if (error) *error = failure;
            return nil;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
            if (error) *error = MakeError(CCErrorHTTP, [NSString stringWithFormat:@"HTTP %ld", (long)response.statusCode]);
            return nil;
        }
        NSError *parse = nil;
        id json = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:&parse] : nil;
        if (!json) {
            if (error) *error = parse ?: MakeError(CCErrorData, @"The API returned nothing.");
            return nil;
        }
        return json;
    }
}

- (NSData *)bytesOf:(NSString *)path from:(long long)from to:(long long)to cancel:(CCCancel *)cancel error:(NSError **)error {
    for (NSInteger attempt = 0;; attempt++) {
        if (cancel.cancelled) {
            if (error) *error = MakeError(CCErrorCancelled, @"Cancelled");
            return nil;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[CCApiClient downloadURL:path]];
        [request setValue:CCApiClient.userAgent forHTTPHeaderField:@"User-Agent"];
        [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", from, to] forHTTPHeaderField:@"Range"];
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
        while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0)
            if (cancel.cancelled) [task cancel];
        if (cancel.cancelled) continue;
        BOOL busy = !failure && (response.statusCode == 429 || response.statusCode >= 500);
        if ((failure || busy) && attempt < 3) {
            Sleep(cancel, (2 << attempt) * self.retryUnit);
            continue;
        }
        if (failure) {
            if (error) *error = failure;
            return nil;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
            if (error) *error = MakeError(CCErrorHTTP, [NSString stringWithFormat:@"HTTP %ld", (long)response.statusCode]);
            return nil;
        }
        // A server that ignores the range answers with the whole file: only what was asked for counts.
        if (response.statusCode == 200 && (long long)body.length > to - from + 1) {
            if (from >= (long long)body.length) return [NSData data];
            return [body subdataWithRange:NSMakeRange((NSUInteger)from, (NSUInteger)MIN(to - from + 1, (long long)body.length - from))];
        }
        return body ?: [NSData data];
    }
}

- (NSArray<CCApiItem *> *)fetchTree:(CCCancel *)cancel error:(NSError **)error {
    for (NSInteger attempt = 0;; attempt++) {
        id page = [self getJSON:[CCApiClient.baseURL stringByAppendingString:@"/files/list-all/"] cancel:cancel error:error];
        if (!page) return nil;
        id list = [page isKindOfClass:NSDictionary.class] ? page[@"items"] : nil;
        if ([list isKindOfClass:NSArray.class] && [list count] > 0) {
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:[list count]];
            for (id json in list) {
                CCApiItem *item = [CCApiItem fromJSON:json];
                if (item) [items addObject:item];
            }
            return items;
        }
        id building = [page isKindOfClass:NSDictionary.class] ? page[@"building"] : nil;
        if (![building respondsToSelector:@selector(boolValue)] || ![building boolValue] || attempt >= 5) {
            if (error) *error = MakeError(CCErrorData, @"The API returned an empty catalog.");
            return nil;
        }
        if (!Sleep(cancel, self.buildingDelay)) {
            if (error) *error = MakeError(CCErrorCancelled, @"Cancelled");
            return nil;
        }
    }
}

- (NSInteger)fetchSongCount {
    NSString *url = [NSString stringWithFormat:@"%@/songs/?page=1&page_size=1&omit=lyrics,synced_lyrics", CCApiClient.baseURL];
    id page = [self getJSON:url cancel:nil error:nil];
    id count = [page isKindOfClass:NSDictionary.class] ? page[@"count"] : nil;
    return [count respondsToSelector:@selector(integerValue)] ? [count integerValue] : 0;
}

- (NSArray<CCSong *> *)fetchSongs:(void (^)(NSInteger, NSInteger))progress cancel:(CCCancel *)cancel error:(NSError **)error {
    NSMutableArray *songs = [NSMutableArray array];
    for (NSInteger number = 1;; number++) {
        NSString *url = [NSString stringWithFormat:@"%@/songs/?page=%ld&page_size=100", CCApiClient.baseURL, (long)number];
        id page = [self getJSON:url cancel:cancel error:error];
        if (!page) return nil;
        NSArray *results = [page isKindOfClass:NSDictionary.class] && [page[@"results"] isKindOfClass:NSArray.class] ? page[@"results"] : @[];
        for (id json in results) {
            CCSong *song = [CCSong fromJSON:json];
            if (song) [songs addObject:song];
        }
        id total = [page isKindOfClass:NSDictionary.class] ? page[@"count"] : nil;
        if (progress) progress((NSInteger)songs.count, [total respondsToSelector:@selector(integerValue)] ? [total integerValue] : 0);
        id next = [page isKindOfClass:NSDictionary.class] ? page[@"next"] : nil;
        if (![next isKindOfClass:NSString.class] || results.count == 0) return songs;
        if (!Sleep(cancel, self.pageDelay)) {
            if (error) *error = MakeError(CCErrorCancelled, @"Cancelled");
            return nil;
        }
    }
}

@end

// ───────────── cache ─────────────

@implementation CCCatalogCache {
    NSString *_directory;
}

- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) _directory = [directory copy];
    return self;
}

- (NSString *)treePath { return [_directory stringByAppendingPathComponent:@"catalog.json"]; }
- (NSString *)songsPath { return [_directory stringByAppendingPathComponent:@"songs.json"]; }

static NSArray *LoadList(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:NSArray.class] ? json : nil;
}

- (NSArray<CCApiItem *> *)loadTree {
    @autoreleasepool {
        NSArray *list = LoadList(self.treePath);
        if (!list) return nil;
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:list.count];
        for (id json in list) {
            CCApiItem *item = [CCApiItem fromJSON:json];
            if (item) [items addObject:item];
        }
        return items;
    }
}

- (NSArray<CCSong *> *)loadSongs {
    @autoreleasepool {
        NSArray *list = LoadList(self.songsPath);
        if (!list) return nil;
        NSMutableArray *songs = [NSMutableArray arrayWithCapacity:list.count];
        for (id json in list) {
            CCSong *song = [CCSong fromJSON:json];
            if (song) [songs addObject:song];
        }
        return songs;
    }
}

// A cache that cannot be written only costs a slower next launch.
- (void)saveList:(NSArray *)list to:(NSString *)path {
    @autoreleasepool {
        NSData *data = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
        if (!data) return;
        [NSFileManager.defaultManager createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil];
        [data writeToFile:path atomically:YES];
    }
}

- (void)saveTree:(NSArray<CCApiItem *> *)items {
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:items.count];
    for (CCApiItem *item in items) [list addObject:item.JSON];
    [self saveList:list to:self.treePath];
}

- (void)saveSongs:(NSArray<CCSong *> *)songs {
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:songs.count];
    for (CCSong *song in songs) [list addObject:song.JSON];
    [self saveList:list to:self.songsPath];
}

- (NSMutableDictionary<NSString *, NSNumber *> *)loadSameAudio {
    NSData *data = [NSData dataWithContentsOfFile:[_directory stringByAppendingPathComponent:@"same-audio.json"]];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableDictionary *known = [NSMutableDictionary dictionary];
    if ([json isKindOfClass:NSDictionary.class])
        for (NSString *key in json)
            if ([json[key] isKindOfClass:NSNumber.class]) known[key] = json[key];
    return known;
}

- (void)saveSameAudio:(NSDictionary<NSString *, NSNumber *> *)known {
    NSMutableDictionary *booleans = [NSMutableDictionary dictionary];
    for (NSString *key in known) booleans[key] = known[key].boolValue ? @YES : @NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:booleans options:0 error:nil];
    if (!data) return;
    [NSFileManager.defaultManager createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:[_directory stringByAppendingPathComponent:@"same-audio.json"] atomically:YES];
}

static NSDate *ModifiedAt(NSString *path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
}

- (NSDate *)treeTime { return ModifiedAt(self.treePath); }
- (NSDate *)songsTime { return ModifiedAt(self.songsPath); }

@end

// ───────────── download values ─────────────

@implementation CCDownloadFile
+ (instancetype)path:(NSString *)apiPath size:(long long)size { return [self path:apiPath size:size target:nil]; }
+ (instancetype)path:(NSString *)apiPath size:(long long)size target:(NSString *)target {
    CCDownloadFile *f = [CCDownloadFile new];
    f->_apiPath = [apiPath copy];
    f->_size = size;
    f->_target = [target copy];
    return f;
}
@end

@implementation CCDownloadFailure
+ (instancetype)path:(NSString *)apiPath reason:(NSString *)reason {
    CCDownloadFailure *f = [CCDownloadFailure new];
    f->_apiPath = [apiPath copy];
    f->_reason = [reason copy];
    return f;
}
@end

@implementation CCDownloadOptions
- (instancetype)init {
    if ((self = [super init])) {
        _destination = @"";
        _parallel = 8;
        _maxAttempts = 5;
        _retryDelay = 2;
        _stallTimeout = 60;
    }
    return self;
}
@end

@implementation CCDownloadProgress
- (instancetype)init {
    if ((self = [super init])) _active = @[];
    return self;
}
- (NSInteger)finished { return self.downloaded + self.alreadyThere + self.failed; }
- (double)fraction {
    if (self.totalBytes > 0) return MAX(0, MIN(1, (double)self.doneBytes / self.totalBytes));
    return self.totalFiles > 0 ? (double)self.finished / self.totalFiles : 1;
}
@end

@implementation CCDownloadReport
- (instancetype)init {
    if ((self = [super init])) _failures = @[];
    return self;
}
@end

// ───────────── run state ─────────────

@interface CCRunState : NSObject
@end

@implementation CCRunState {
    NSMutableArray<NSString *> *_active;
    NSMutableArray<CCDownloadFailure *> *_failures;
    NSInteger _count, _downloaded, _there;
    long long _total, _done, _transferred, _downloadedBytes;
}

- (instancetype)initWithFiles:(NSArray<CCDownloadFile *> *)files {
    if ((self = [super init])) {
        _active = [NSMutableArray array];
        _failures = [NSMutableArray array];
        _count = (NSInteger)files.count;
        for (CCDownloadFile *f in files) _total += f.size;
    }
    return self;
}

- (long long)transferredBytes { @synchronized (self) { return _transferred; } }
- (void)begin:(NSString *)path { @synchronized (self) { [_active addObject:path]; } }
- (void)abandon:(NSString *)path { @synchronized (self) { [_active removeObject:path]; } }

- (void)add:(long long)delta {
    @synchronized (self) {
        _done += delta;
        if (delta > 0) _transferred += delta;
    }
}

- (void)finish:(CCDownloadFile *)file fetched:(BOOL)fetched {
    @synchronized (self) {
        [_active removeObject:file.apiPath];
        if (fetched) {
            _downloaded++;
            _downloadedBytes += file.size;
        } else {
            _there++;
        }
    }
}

- (void)fail:(CCDownloadFile *)file reason:(NSString *)reason {
    @synchronized (self) {
        [_active removeObject:file.apiPath];
        [_failures addObject:[CCDownloadFailure path:file.apiPath reason:reason]];
    }
}

- (CCDownloadProgress *)snapshot:(double)speed {
    @synchronized (self) {
        CCDownloadProgress *p = [CCDownloadProgress new];
        p.totalFiles = _count;
        p.totalBytes = _total;
        p.downloaded = _downloaded;
        p.alreadyThere = _there;
        p.failed = (NSInteger)_failures.count;
        p.doneBytes = _done;
        p.bytesPerSecond = speed;
        p.active = _active;
        return p;
    }
}

- (CCDownloadReport *)report:(BOOL)stopped {
    @synchronized (self) {
        CCDownloadReport *r = [CCDownloadReport new];
        r.downloaded = _downloaded;
        r.alreadyThere = _there;
        r.failures = _failures;
        r.stopped = stopped;
        r.bytes = _downloadedBytes;
        return r;
    }
}

@end

// ───────────── one attempt at one file ─────────────

typedef NS_ENUM(NSInteger, CCAttemptOutcome) {
    CCAttemptPending,
    CCAttemptComplete,
    CCAttemptRetry,
    CCAttemptPermanent,
};

@interface CCTransfer : NSObject
@property (nonatomic, copy) NSString *part;
@property (nonatomic) long long have, expected, catalogSize;
@property (nonatomic, strong, nullable) NSFileHandle *output;
@property (nonatomic, copy) void (^onHave)(long long have);
@property (nonatomic, strong) dispatch_semaphore_t done;
@property (nonatomic) CCAttemptOutcome outcome;
@property (nonatomic, copy, nullable) NSString *message;
/// Negative: the usual backoff.
@property (nonatomic) NSTimeInterval retryAfter;
@property (atomic) NSTimeInterval lastActivity;
@property (atomic) BOOL stalled;
@end
@implementation CCTransfer
@end

/// Streams every transfer of one run to its .part file. Delegate calls arrive on one serial queue.
@interface CCRunSession : NSObject <NSURLSessionDataDelegate>
@end

@implementation CCRunSession {
    NSMutableDictionary<NSNumber *, CCTransfer *> *_transfers;
}

- (instancetype)init {
    if ((self = [super init])) _transfers = [NSMutableDictionary dictionary];
    return self;
}

- (void)watch:(NSURLSessionTask *)task transfer:(CCTransfer *)transfer {
    @synchronized (_transfers) { _transfers[@(task.taskIdentifier)] = transfer; }
}

- (CCTransfer *)transferOf:(NSURLSessionTask *)task {
    @synchronized (_transfers) { return _transfers[@(task.taskIdentifier)]; }
}

- (void)forget:(NSURLSessionTask *)task {
    @synchronized (_transfers) { [_transfers removeObjectForKey:@(task.taskIdentifier)]; }
}

/// "bytes 400-999/1000": from and total, -1 when absent or "*".
static void ParseContentRange(NSString *header, long long *from, long long *total) {
    *from = -1;
    *total = -1;
    if (!header) return;
    long long a = 0, b = 0, c = 0;
    if (sscanf(header.UTF8String, "bytes %lld-%lld/%lld", &a, &b, &c) >= 2) {
        *from = a;
        NSString *tail = [header componentsSeparatedByString:@"/"].lastObject;
        if (![tail isEqualToString:@"*"] && [header containsString:@"/"]) *total = c;
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)r
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    CCTransfer *t = [self transferOf:task];
    t.lastActivity = Now();
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)r;
    NSInteger status = response.statusCode;

    void (^retry)(NSTimeInterval, NSString *) = ^(NSTimeInterval wait, NSString *message) {
        t.outcome = CCAttemptRetry;
        t.retryAfter = wait;
        t.message = message;
        completion(NSURLSessionResponseCancel);
    };
    if (status == 416) {
        [NSFileManager.defaultManager removeItemAtPath:t.part error:nil];
        retry(0, @"HTTP 416");
        return;
    }
    if (status == 429 || status >= 500) {
        NSString *after = [response valueForHTTPHeaderField:@"Retry-After"];
        NSScanner *scanner = after ? [NSScanner scannerWithString:after] : nil;
        long long seconds = -1;
        // A date is treated like no answer, as in the C# engine; an hour's wait would look like a hang.
        if (!scanner || ![scanner scanLongLong:&seconds] || !scanner.atEnd) seconds = -1;
        retry(seconds < 0 ? -1 : MIN(seconds, 300), [NSString stringWithFormat:@"HTTP %ld", (long)status]);
        return;
    }
    if (status < 200 || status >= 300) {
        t.outcome = CCAttemptPermanent;
        t.message = [NSString stringWithFormat:@"HTTP %ld", (long)status];
        completion(NSURLSessionResponseCancel);
        return;
    }

    long long rangeFrom, rangeTotal;
    ParseContentRange([response valueForHTTPHeaderField:@"Content-Range"], &rangeFrom, &rangeTotal);
    if (status == 206 && rangeFrom != t.have) {
        // Bytes from another offset would end up in the wrong place: start the file over rather than keep them.
        [NSFileManager.defaultManager removeItemAtPath:t.part error:nil];
        retry(0, @"wrong range");
        return;
    }
    BOOL resumed = status == 206;
    if (!resumed) t.have = 0;
    NSString *encoding = [response valueForHTTPHeaderField:@"Content-Encoding"];
    BOOL lengthIsBody = response.expectedContentLength >= 0 && (encoding.length == 0 || [encoding isEqualToString:@"identity"]);
    t.expected = rangeTotal >= 0 ? rangeTotal : lengthIsBody ? response.expectedContentLength + t.have : t.catalogSize;

    t.onHave(t.have);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    if ((!resumed || ![fm fileExistsAtPath:t.part]) && ![fm createFileAtPath:t.part contents:nil attributes:nil]) {
        retry(-1, [NSString stringWithFormat:@"Could not write %@", t.part.lastPathComponent]);
        return;
    }
    t.output = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:t.part] error:&error];
    if (!t.output || (resumed && ![t.output seekToEndReturningOffset:NULL error:&error])) {
        retry(-1, error.localizedDescription ?: @"Could not write the file");
        return;
    }
    completion(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    CCTransfer *t = [self transferOf:task];
    t.lastActivity = Now();
    if (t.outcome != CCAttemptPending) return;
    NSError *error = nil;
    if (![t.output writeData:data error:&error]) {
        t.outcome = CCAttemptRetry;
        t.retryAfter = -1;
        t.message = error.localizedDescription ?: @"Could not write the file";
        [task cancel];
        return;
    }
    t.have += (long long)data.length;
    t.onHave(t.have);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    CCTransfer *t = [self transferOf:task];
    [t.output closeFile];
    t.output = nil;
    if (t.outcome == CCAttemptPending) {
        if (t.stalled) {
            t.outcome = CCAttemptRetry;
            t.retryAfter = -1;
            t.message = @"The connection stopped sending";
        } else if (error) {
            t.outcome = CCAttemptRetry;
            t.retryAfter = -1;
            t.message = error.localizedDescription;
        } else if (t.have != t.expected) {
            t.outcome = CCAttemptRetry;
            t.retryAfter = -1;
            t.message = [NSString stringWithFormat:@"connection closed at %lld of %lld bytes", t.have, t.expected];
        } else {
            t.outcome = CCAttemptComplete;
        }
    }
    dispatch_semaphore_signal(t.done);
}

@end

// ───────────── engine ─────────────

static long long FileLength(NSString *path, BOOL *exists) {
    struct stat st;
    BOOL ok = stat(path.fileSystemRepresentation, &st) == 0;
    if (exists) *exists = ok;
    return ok ? st.st_size : 0;
}

@implementation CCDownloadEngine {
    NSURLSessionConfiguration *_configuration;
}

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {
    if ((self = [super init])) {
        NSURLSessionConfiguration *c = configuration ?: NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.URLCache = nil;
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        // The worker watches for a stall itself; this only keeps the system from giving up first.
        c.timeoutIntervalForRequest = 600;
        _configuration = c;
    }
    return self;
}

- (NSURLSessionConfiguration *)configurationForParallel:(NSInteger)parallel {
    NSURLSessionConfiguration *c = [_configuration copy];
    c.HTTPMaximumConnectionsPerHost = MAX(1, MIN(32, parallel));
    return c;
}

+ (BOOL)isComplete:(NSString *)file size:(long long)size {
    BOOL exists = NO;
    long long length = FileLength(file, &exists);
    if (!exists) return NO;
    if (length == size) return YES;
    if ([file.pathExtension caseInsensitiveCompare:@"mp3"] != NSOrderedSame) return NO;
    return [CCId3Lyrics has:file error:nil];
}

- (CCDownloadReport *)run:(NSArray<CCDownloadFile *> *)files options:(CCDownloadOptions *)options
                 progress:(void (^)(CCDownloadProgress *))progress cancel:(CCCancel *)cancel {
    CCCancel *token = cancel ?: [CCCancel new];
    CCRunState *state = [[CCRunState alloc] initWithFiles:files];
    CCRunSession *delegate = [CCRunSession new];
    NSOperationQueue *delegateQueue = [NSOperationQueue new];
    delegateQueue.maxConcurrentOperationCount = 1;
    delegateQueue.name = @"JuiceDownloader.transfers";
    NSInteger parallel = MAX(1, MIN(32, options.parallel));
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[self configurationForParallel:parallel] delegate:delegate delegateQueue:delegateQueue];

    // The progress ticker: four times a second, with the speed smoothed.
    CCCancel *tickerStop = [CCCancel new];
    dispatch_group_t ticker = dispatch_group_create();
    if (progress) {
        dispatch_group_async(ticker, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            long long lastBytes = state.transferredBytes;
            NSTimeInterval lastTime = Now();
            double speed = 0;
            while ([tickerStop sleep:0.25]) {
                NSTimeInterval now = Now();
                long long bytes = state.transferredBytes;
                double seconds = MAX(0.001, now - lastTime);
                double current = (double)(bytes - lastBytes) / seconds;
                speed = speed <= 0 ? current : speed * 0.8 + current * 0.2;
                lastBytes = bytes;
                lastTime = now;
                progress([state snapshot:speed]);
            }
        });
    }

    NSLock *queueLock = [NSLock new];
    __block NSUInteger next = 0;
    dispatch_group_t workers = dispatch_group_create();
    // Threads of their own: each blocks on its transfer, and a dispatch queue may not widen to 32 of those.
    for (NSInteger i = 0; i < parallel; i++) {
        dispatch_group_enter(workers);
        [NSThread detachNewThreadWithBlock:^{
            while (!token.cancelled) {
                [queueLock lock];
                CCDownloadFile *file = next < files.count ? files[next++] : nil;
                [queueLock unlock];
                if (!file) break;
                @autoreleasepool {
                    [self one:file options:options state:state session:session delegate:delegate cancel:token];
                }
            }
            dispatch_group_leave(workers);
        }];
    }
    dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    [tickerStop cancel];
    dispatch_group_wait(ticker, DISPATCH_TIME_FOREVER);
    if (progress) progress([state snapshot:0]);
    return [state report:token.cancelled];
}

- (void)one:(CCDownloadFile *)file options:(CCDownloadOptions *)options state:(CCRunState *)state
    session:(NSURLSession *)session delegate:(CCRunSession *)delegate cancel:(CCCancel *)cancel {
    [state begin:file.apiPath];
    NSString *target = [CCLocalPath resolve:file.target ?: file.apiPath under:options.destination];
    if (!target) {
        [state add:file.size];
        [state fail:file reason:@"unsafe path"];
        return;
    }
    __block long long counted = 0;
    BOOL fetched = NO;
    if (![CCDownloadEngine isComplete:target size:file.size]) {
        fetched = YES;
        NSString *reason = nil;
        BOOL stopped = NO;
        BOOL ok = [self transfer:file to:target options:options session:session delegate:delegate cancel:cancel
                         onBytes:^(long long delta) { counted += delta; [state add:delta]; } reason:&reason stopped:&stopped];
        if (stopped) {
            [state add:-counted];
            [state abandon:file.apiPath];
            return;
        }
        if (!ok) {
            // a failed file stays in the sum, so the bar still reaches the end
            [state add:file.size - counted];
            [state fail:file reason:reason ?: @"failed"];
            return;
        }
    }
    [state add:file.size - counted];
    counted = file.size;
    if (options.afterFile) options.afterFile(file.apiPath, target);
    [state finish:file fetched:fetched];
}

- (BOOL)transfer:(CCDownloadFile *)file to:(NSString *)target options:(CCDownloadOptions *)options
         session:(NSURLSession *)session delegate:(CCRunSession *)delegate cancel:(CCCancel *)cancel
         onBytes:(void (^)(long long))onBytes reason:(NSString **)reason stopped:(BOOL *)stopped {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        *reason = dirError.localizedDescription;
        return NO;
    }
    NSString *part = [target stringByAppendingString:@".part"];
    __block long long reported = 0;
    void (^onHave)(long long) = ^(long long have) {
        onBytes(have - reported);
        reported = have;
    };

    for (NSInteger attempt = 1;; attempt++) {
        CCTransfer *t = [self attempt:file part:part options:options session:session delegate:delegate cancel:cancel onHave:onHave];
        CCAttemptOutcome outcome = t.outcome;
        NSString *message = t.message;
        if (outcome == CCAttemptComplete) {
            if (rename(part.fileSystemRepresentation, target.fileSystemRepresentation) == 0) return YES;
            outcome = CCAttemptRetry;
            message = [NSString stringWithFormat:@"Could not move %@ into place", target.lastPathComponent];
        }
        if (cancel.cancelled) {
            *stopped = YES;
            return NO;
        }
        if (outcome == CCAttemptPermanent || attempt >= options.maxAttempts) {
            *reason = message;
            return NO;
        }
        NSTimeInterval wait = t.retryAfter >= 0 ? t.retryAfter : options.retryDelay * (1 << (attempt - 1));
        if (!Sleep(cancel, wait)) {
            *stopped = YES;
            return NO;
        }
    }
}

- (CCTransfer *)attempt:(CCDownloadFile *)file part:(NSString *)part options:(CCDownloadOptions *)options
                session:(NSURLSession *)session delegate:(CCRunSession *)delegate cancel:(CCCancel *)cancel
                 onHave:(void (^)(long long))onHave {
    BOOL exists = NO;
    long long have = FileLength(part, &exists);
    if (have > file.size && file.size > 0) {
        [NSFileManager.defaultManager removeItemAtPath:part error:nil];
        have = 0;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[CCApiClient downloadURL:file.apiPath]];
    [request setValue:CCApiClient.userAgent forHTTPHeaderField:@"User-Agent"];
    // The bytes as stored: a compressed answer would not match its own Content-Length once decoded.
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (have > 0) [request setValue:[NSString stringWithFormat:@"bytes=%lld-", have] forHTTPHeaderField:@"Range"];

    CCTransfer *t = [CCTransfer new];
    t.part = part;
    t.have = have;
    t.expected = file.size;
    t.catalogSize = file.size;
    t.onHave = onHave;
    t.done = dispatch_semaphore_create(0);
    t.retryAfter = -1;
    t.lastActivity = Now();

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    [delegate watch:task transfer:t];
    [task resume];
    BOOL cancelSent = NO;
    while (dispatch_semaphore_wait(t.done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (cancelSent) continue;
        if (cancel.cancelled) {
            cancelSent = YES;
            [task cancel];
        } else if (Now() - t.lastActivity > options.stallTimeout) {
            cancelSent = YES;
            t.stalled = YES;
            [task cancel];
        }
    }
    [delegate forget:task];
    return t;
}

@end
