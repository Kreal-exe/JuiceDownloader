#import "CCLibrary.h"
#include <stdatomic.h>
#include <sys/stat.h>

static const NSTimeInterval kCatalogAge = 6 * 3600;

@implementation CCLyricsRunReport
- (instancetype)init {
    if ((self = [super init])) _missing = @[];
    return self;
}
@end

@implementation CCLyricsGap
@end
@implementation CCLyricsGapResult
@end
@implementation CCLyricsGapScan
- (instancetype)init {
    if ((self = [super init])) _gaps = @[];
    return self;
}
@end

@implementation CCDiskState {
    NSDictionary<NSString *, NSString *> *_paths;
    NSDictionary<NSString *, NSNumber *> *_sections;
}

static NSString *DiskKey(NSString *name) {
    return name.stringByDeletingPathExtension.precomposedStringWithCanonicalMapping.lowercaseString;
}

static BOOL DiskIsAudio(NSString *extension) {
    return [extension isEqualToString:@"webm"] || [CCLibrary isAudio:[@"x." stringByAppendingString:extension]];
}

/// Words and cover art go into a tag after the download, so the size only has to be near; and a file cut of the
/// silence at its end is smaller, though never by half.
static BOOL DiskSizeIsNear(long long local, long long size) {
    return llabs(local - size) <= MAX(2LL * 1024 * 1024, size / 20) || (local < size && local >= size / 2);
}

+ (instancetype)scan:(CCCatalog *)catalog under:(NSString *)destination {
    CCDiskState *state = [CCDiskState new];
    NSMutableDictionary<NSString *, NSMutableArray<NSArray *> *> *local = [NSMutableDictionary dictionary];
    NSArray *keys = @[ NSURLIsRegularFileKey, NSURLFileSizeKey ];
    NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:destination] includingPropertiesForKeys:keys
                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
    for (NSURL *url in walk) {
        @autoreleasepool {
            NSNumber *regular, *size;
            [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            if (!regular.boolValue) continue;
            NSString *extension = url.pathExtension.lowercaseString;
            if ([extension isEqualToString:@"part"] || [extension isEqualToString:@"lrc"]) continue;
            [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            NSString *key = DiskKey(url.lastPathComponent);
            if (!local[key]) local[key] = [NSMutableArray array];
            [local[key] addObject:@[ url.path, extension, size ?: @0 ]];
        }
    }
    NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *used = [NSMutableDictionary dictionary];
    [catalog.root forEachFile:^(CCCatalogNode *file) {
        NSString *name = [CCLocalPath clean:file.name], *extension = name.pathExtension.lowercaseString;
        NSArray *best = nil;
        long long nearest = LLONG_MAX;
        for (NSArray *entry in local[DiskKey(name)]) {
            long long size = [entry[2] longLongValue];
            if (![entry[1] isEqualToString:extension] && !(DiskIsAudio(entry[1]) && DiskIsAudio(extension))) continue;
            if (!DiskSizeIsNear(size, file.size) || llabs(size - file.size) >= nearest) continue;
            best = entry;
            nearest = llabs(size - file.size);
        }
        if (!best) return;
        paths[file.path] = best[0];
        used[best[0]] = best[2];
    }];
    NSMutableDictionary<NSString *, NSNumber *> *sections = [NSMutableDictionary dictionary];
    for (CCCatalogSection *section in catalog.sections) {
        __block NSInteger count = 0;
        for (CCCatalogNode *row in section.rows)
            [row forEachFile:^(CCCatalogNode *file) { if (paths[file.path]) count++; }];
        sections[section.identifier] = @(count);
    }
    long long bytes = 0;
    for (NSNumber *size in used.allValues) bytes += size.longLongValue;
    state->_paths = paths;
    state->_sections = sections;
    state->_files = (NSInteger)used.count;
    state->_bytes = bytes;
    return state;
}

- (BOOL)has:(NSString *)apiPath { return _paths[apiPath] != nil; }
- (NSString *)localPathOf:(NSString *)apiPath { return _paths[apiPath]; }
- (NSInteger)filesInSection:(NSString *)identifier { return _sections[identifier].integerValue; }

@end

@implementation CCLibrary {
    atomic_long _same, _other, _none;
}

- (instancetype)initWithApi:(CCApiClient *)api engine:(CCDownloadEngine *)engine cache:(CCCatalogCache *)cache {
    if ((self = [super init])) {
        _api = api;
        _engine = engine;
        _cache = cache;
    }
    return self;
}

- (NSDate *)updatedAt { return self.cache.treeTime; }

- (BOOL)loadCached {
    NSArray *items = [self.cache loadTree];
    if (items.count > 0) self.catalog = [CCCatalog build:items];
    return self.catalog != nil;
}

- (BOOL)loadCachedLyrics {
    NSArray *songs = [self.cache loadSongs];
    if (songs.count == 0) return NO;
    self.lyrics = [[CCLyricsIndex alloc] initWithSongs:songs];
    return YES;
}

- (BOOL)catalogIsStale {
    NSDate *t = self.cache.treeTime;
    return !t || -t.timeIntervalSinceNow > kCatalogAge;
}

- (CCCatalog *)fetchCatalog:(CCCancel *)cancel error:(NSError **)error {
    NSArray *items = [self.api fetchTree:cancel error:error];
    if (!items) return nil;
    [self.cache saveTree:items];
    return [CCCatalog build:items];
}

- (void)adoptCatalog:(CCCatalog *)fresh {
    [CCLibrary carrySelectionFrom:self.catalog to:fresh];
    self.catalog = fresh;
}

- (BOOL)refresh:(CCCancel *)cancel error:(NSError **)error {
    CCCatalog *fresh = [self fetchCatalog:cancel error:error];
    if (!fresh) return NO;
    [self adoptCatalog:fresh];
    return YES;
}

+ (void)carrySelectionFrom:(CCCatalog *)from to:(CCCatalog *)to {
    if (!from || from.selectedFiles == 0) return;
    NSMutableSet *selected = [NSMutableSet set];
    for (CCCatalogNode *file in from.selectedFilesList) [selected addObject:file.path];
    [to.root forEachFile:^(CCCatalogNode *file) {
        if ([selected containsObject:file.path]) [CCCatalog select:file selected:YES];
    }];
}

- (CCLyricsIndex *)ensureLyricsForce:(BOOL)force progress:(void (^)(NSInteger, NSInteger))progress cancel:(CCCancel *)cancel error:(NSError **)error {
    if (!force && self.lyrics) return self.lyrics;
    if (!force && [self loadCachedLyrics]) return self.lyrics;
    NSError *fetchError = nil;
    NSArray *songs = [self.api fetchSongs:progress cancel:cancel error:&fetchError];
    if (songs) {
        [self.cache saveSongs:songs];
        return self.lyrics = [[CCLyricsIndex alloc] initWithSongs:songs];
    }
    if (!cancel.cancelled) {
        NSArray *cached = [self.cache loadSongs];
        if (cached.count > 0) return self.lyrics = [[CCLyricsIndex alloc] initWithSongs:cached];
    }
    if (error) *error = fetchError;
    return nil;
}

- (BOOL)lyricsChangedOnServer {
    if (!self.lyrics && ![self loadCachedLyrics]) return NO;
    NSInteger count = [self.api fetchSongCount];
    return count > 0 && count != self.lyrics.songCount;
}

- (NSArray<CCDownloadFile *> *)selectedDownloadFiles {
    NSMutableArray *files = [NSMutableArray array];
    for (CCCatalogNode *node in self.catalog.selectedFilesList) [files addObject:[CCDownloadFile path:node.path size:node.size]];
    return files;
}

- (CCDownloadReport *)download:(NSArray<CCDownloadFile *> *)files to:(NSString *)destination parallel:(NSInteger)parallel
                         lyrics:(CCLyricsIndex *)index options:(CCLyricsOptions *)lyricsOptions
                       progress:(void (^)(CCDownloadProgress *))progress cancel:(CCCancel *)cancel {
    CCDownloadOptions *options = [CCDownloadOptions new];
    options.destination = destination;
    options.parallel = parallel;
    atomic_store(&_same, 0);
    atomic_store(&_other, 0);
    atomic_store(&_none, 0);
    if (index && lyricsOptions) {
        __weak CCLibrary *weak = self;
        options.afterFile = ^(NSString *apiPath, NSString *local) { [weak applyLyrics:index api:apiPath local:local options:lyricsOptions]; };
    }
    return [self.engine run:files options:options progress:progress cancel:cancel];
}

- (void)applyLyrics:(CCLyricsIndex *)index api:(NSString *)apiPath local:(NSString *)local options:(CCLyricsOptions *)options {
    if (![CCLibrary wantsLyrics:apiPath] || [apiPath containsString:@"nstrumental"]) return;
    CCLyricsMatch *match = [index find:apiPath];
    if (!match) atomic_fetch_add(&_none, 1);
    else if (match.fit == CCLyricsFitSameRecording) atomic_fetch_add(&_same, 1);
    else atomic_fetch_add(&_other, 1);
    if (match) [CCLyricsWriter apply:match.song to:local options:options];
}

- (NSInteger)lastLyricsSame { return atomic_load(&_same); }
- (NSInteger)lastLyricsOther { return atomic_load(&_other); }
- (NSInteger)lastLyricsNone { return atomic_load(&_none); }

- (void)keepOnlySelected:(NSArray<NSString *> *)paths {
    if (!self.catalog) return;
    NSSet *keep = [NSSet setWithArray:paths];
    for (CCCatalogNode *file in self.catalog.selectedFilesList)
        if (![keep containsObject:file.path]) [CCCatalog select:file selected:NO];
}

+ (NSArray<CCDownloadFile *> *)albumFiles:(CCCatalogNode *)album {
    NSMutableArray *files = [NSMutableArray array];
    NSUInteger skip = album.path.length + 1;
    [album forEachFile:^(CCCatalogNode *file) {
        NSString *target = [album.displayName stringByAppendingPathComponent:[file.path substringFromIndex:skip]];
        [files addObject:[CCDownloadFile path:file.path size:file.size target:target]];
    }];
    return files;
}

+ (long long)bytesStillNeeded:(NSArray<CCDownloadFile *> *)files under:(NSString *)destination {
    long long needed = 0;
    for (CCDownloadFile *file in files) {
        @autoreleasepool {
            NSString *target = [CCLocalPath resolve:file.target ?: file.apiPath under:destination];
            if (!target) continue;
            if ([CCDownloadEngine isComplete:target size:file.size]) continue;
            struct stat st;
            long long part = stat([target stringByAppendingString:@".part"].fileSystemRepresentation, &st) == 0 ? st.st_size : 0;
            needed += MAX(0, file.size - part);
        }
    }
    return needed;
}

+ (BOOL)isAudio:(NSString *)name {
    static NSSet *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ extensions = [NSSet setWithArray:@[ @"mp3", @"m4a", @"flac", @"wav", @"aif", @"aiff", @"ogg", @"caf" ]]; });
    return [extensions containsObject:name.pathExtension.lowercaseString];
}

- (CCRuleResult *)applyRules:(CCRuleOptions *)options cancel:(CCCancel *)cancel error:(NSError **)error {
    if (![self ensureLyricsForce:NO progress:nil cancel:cancel error:error]) return nil;
    NSArray<CCSong *> *songs = [self.cache loadSongs] ?: @[];
    // A cache from before the rules has no leak types: it says nothing about which take is finished.
    BOOL anyLeak = NO;
    for (CCSong *s in songs)
        if (s.leakType.length > 0) { anyLeak = YES; break; }
    if (songs.count > 0 && !anyLeak) {
        if (![self ensureLyricsForce:YES progress:nil cancel:cancel error:error]) return nil;
        songs = [self.cache loadSongs] ?: @[];
    }
    CCCatalog *catalog = self.catalog;
    if (!catalog) return [CCRuleResult new];
    CCRuleResult *result = [CCSongRules apply:catalog songs:songs options:options];
    if (!self.lyrics) return result;
    NSMutableDictionary *known = [self.cache loadSameAudio];
    CCRuleResult *cleaned = [CCAudioCopies remove:result index:self.lyrics api:self.api same:known cancel:cancel];
    [self.cache saveSameAudio:known];
    return cleaned;
}

+ (BOOL)isPlayable:(NSString *)name { return [self isAudio:name]; }

+ (CCPreviewKind)previewOf:(NSString *)name {
    static NSDictionary *kinds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kinds = @{ @"jpg": @(CCPreviewImage), @"jpeg": @(CCPreviewImage), @"png": @(CCPreviewImage), @"webp": @(CCPreviewImage), @"gif": @(CCPreviewImage),
                   @"tif": @(CCPreviewImage), @"tiff": @(CCPreviewImage), @"bmp": @(CCPreviewImage),
                   @"mp4": @(CCPreviewVideo), @"mov": @(CCPreviewVideo), @"m4v": @(CCPreviewVideo), @"webm": @(CCPreviewVideo), @"mkv": @(CCPreviewVideo),
                   @"txt": @(CCPreviewText), @"ini": @(CCPreviewText), @"lrc": @(CCPreviewText) };
    });
    return (CCPreviewKind)[kinds[name.pathExtension.lowercaseString] integerValue];
}

+ (BOOL)wantsLyrics:(NSString *)path {
    NSString *unix = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    return [self isAudio:path] || ([unix hasPrefix:@"Studio Sessions/"] && [unix.pathExtension caseInsensitiveCompare:@"zip"] == NSOrderedSame);
}

+ (NSString *)localCopy:(CCCatalogNode *)file under:(NSString *)destination {
    NSString *path = [CCLocalPath resolve:file.path under:destination];
    return path && [CCDownloadEngine isComplete:path size:file.size] ? path : nil;
}

/// The files of a folder lyrics can go with, by their path below it, sorted.
static NSArray<NSString *> *LyricFiles(NSString *folder) {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSDirectoryEnumerator *walker = [NSFileManager.defaultManager enumeratorAtPath:folder];
    for (NSString *relative in walker)
        if ([CCLibrary wantsLyrics:relative] && [walker.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) [files addObject:relative];
    [files sortUsingSelector:@selector(compare:)];
    return files;
}

/// Instrumentals are not gaps, and neither is a stem of one channel.
static BOOL NoWordsExpected(NSString *relative) {
    return [relative hasPrefix:@"Instrumentals/"] || [relative containsString:@"/Instrumental/"]
        || [relative rangeOfString:@"instrumental" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (CCLyricsGapScan *)scanForGaps:(NSString *)folder options:(CCLyricsOptions *)options progress:(void (^)(NSInteger, NSInteger, NSString *))progress
                          cancel:(CCCancel *)cancel error:(NSError **)error {
    CCLyricsIndex *index = [self ensureLyricsForce:NO progress:nil cancel:cancel error:error];
    if (!index) return nil;
    NSArray *files = LyricFiles(folder);
    CCLyricsGapScan *scan = [CCLyricsGapScan new];
    scan.files = (NSInteger)files.count;
    NSMutableArray *gaps = [NSMutableArray array];
    NSInteger done = 0;
    for (NSString *relative in files) {
        if (cancel.cancelled) {
            if (error) *error = [NSError errorWithDomain:CCErrorDomain code:CCErrorCancelled userInfo:@{ NSLocalizedDescriptionKey: @"Cancelled" }];
            return nil;
        }
        @autoreleasepool {
            done++;
            if (progress) progress(done, (NSInteger)files.count, relative.lastPathComponent);
            if (NoWordsExpected(relative)) {
                scan.fine++;
                continue;
            }
            NSString *file = [folder stringByAppendingPathComponent:relative];
            CCLyricsMatch *match = [index find:relative];
            if (match) [CCLyricsWriter apply:match.song to:file options:options];
            if ((match && match.fit == CCLyricsFitSameRecording) || (!match && [CCLyricsWriter has:file])) {
                scan.fine++;
                continue;
            }
            CCLyricsGap *gap = [CCLyricsGap new];
            gap.file = file;
            gap.relative = relative;
            gap.kind = match ? CCLyricsGapOtherRecording : CCLyricsGapNoWords;
            gap.hasWordsOf = match.song.name;
            [gaps addObject:gap];
        }
    }
    scan.gaps = gaps;
    return scan;
}

- (NSArray<CCLyricsGapResult *> *)searchWeb:(NSArray<CCLyricsGap *> *)gaps web:(CCWebLyrics *)web options:(CCLyricsOptions *)options
                                   progress:(void (^)(CCLyricsGapResult *))progress cancel:(CCCancel *)cancel {
    NSMutableArray *results = [NSMutableArray array];
    NSLock *lock = [NSLock new];
    __block NSUInteger next = 0;
    dispatch_group_t workers = dispatch_group_create();
    for (int i = 0; i < 3; i++) {
        dispatch_group_enter(workers);
        [NSThread detachNewThreadWithBlock:^{
            while (!cancel.cancelled) {
                [lock lock];
                CCLyricsGap *gap = next < gaps.count ? gaps[next++] : nil;
                [lock unlock];
                if (!gap) break;
                @autoreleasepool {
                    CCWebLyricsResult *found = [web find:gap.relative cancel:cancel];
                    if (cancel.cancelled) break;
                    CCLyricsGapResult *result = [CCLyricsGapResult new];
                    result.gap = gap;
                    result.found = found;
                    result.written = CCLyricsResultNone;
                    CCWebMatch *word = found.match;
                    if (word && (gap.kind == CCLyricsGapNoWords || word.fit == CCLyricsFitSameRecording))
                        result.written = [CCLyricsWriter applyWords:word.lyrics synced:word.synced to:gap.file options:options replace:gap.kind == CCLyricsGapOtherRecording];
                    [lock lock];
                    [results addObject:result];
                    [lock unlock];
                    if (progress) progress(result);
                }
            }
            dispatch_group_leave(workers);
        }];
    }
    dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);
    return results;
}

- (CCLyricsRunReport *)addLyricsToFolder:(NSString *)folder options:(CCLyricsOptions *)options
                                progress:(void (^)(NSInteger, NSInteger, NSString *))progress cancel:(CCCancel *)cancel error:(NSError **)error {
    CCLyricsIndex *index = [self ensureLyricsForce:NO progress:nil cancel:cancel error:error];
    if (!index) return nil;

    NSArray<NSString *> *files = LyricFiles(folder);
    CCLyricsRunReport *report = [CCLyricsRunReport new];
    NSMutableArray *missing = [NSMutableArray array];
    NSInteger done = 0;
    for (NSString *relative in files) {
        if (cancel.cancelled) {
            report.stopped = YES;
            break;
        }
        @autoreleasepool {
            done++;
            if (progress) progress(done, (NSInteger)files.count, relative.lastPathComponent);
            CCLyricsMatch *match = [index findOnDisk:relative];
            if (!match) {
                [missing addObject:relative];
                continue;
            }
            switch ([CCLyricsWriter apply:match.song to:[folder stringByAppendingPathComponent:relative] options:options]) {
                case CCLyricsResultWritten: report.written++; break;
                case CCLyricsResultAlreadyThere: report.alreadyThere++; break;
                case CCLyricsResultFailed: report.failed++; break;
                case CCLyricsResultNone: [missing addObject:relative]; break;
            }
        }
    }
    report.missing = missing;
    report.notFound = (NSInteger)missing.count;
    return report;
}

@end
