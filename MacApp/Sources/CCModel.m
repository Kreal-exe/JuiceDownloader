#import "CCModel.h"

NSNotificationName const CCModelDidChangeNotification = @"CCModelDidChange";
NSNotificationName const CCModelPageNotification = @"CCModelPage";
NSNotificationName const CCModelCatalogNotification = @"CCModelCatalog";
NSNotificationName const CCModelDownloadStateNotification = @"CCModelDownloadState";
NSNotificationName const CCModelDownloadProgressNotification = @"CCModelDownloadProgress";
NSNotificationName const CCModelToastNotification = @"CCModelToast";
NSNotificationName const CCModelPreviewNotification = @"CCModelPreview";
NSNotificationName const CCModelRevealNotification = @"CCModelReveal";
NSNotificationName const CCModelLyricsSheetNotification = @"CCModelLyricsSheet";

static NSString *const kNames[] = { @"overview", @"albums", @"unofficial", @"unreleased", @"compilations", @"sessionEdits", @"originals", @"studio",
                                    @"instrumentals", @"remixes", @"snippets", @"media", @"rules", @"lyrics", @"gaps", @"settings", @"about" };
static NSString *const kSymbols[] = { @"house", @"square.stack", @"cloud", @"music.note.list", @"rectangle.stack", @"scissors", @"waveform", @"slider.horizontal.3",
                                      @"pianokeys", @"shuffle", @"play.rectangle", @"photo.on.rectangle", @"checklist", @"text.quote", @"text.badge.xmark", @"gearshape", @"info.circle" };

NSString *CCPageName(CCPage page) { return kNames[page]; }
NSString *CCPageSymbol(CCPage page) { return kSymbols[page]; }
NSInteger CCPageSectionIndex(CCPage page) { return page >= CCPageAlbums && page <= CCPageMedia ? page - CCPageAlbums : -1; }

NSString *CCFormatDuration(double seconds) {
    long long s = llround(MAX(0, seconds));
    if (s >= 3600) return LF(@"time.hours", @(s / 3600), @((s % 3600) / 60));
    if (s >= 60) return LF(@"time.minutes", @(s / 60));
    return LF(@"time.seconds", @(s));
}

@implementation CCGapRow
@end

static void Background(dispatch_block_t block) { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), block); }
static void Main(dispatch_block_t block) { dispatch_async(dispatch_get_main_queue(), block); }

@implementation CCModel {
    NSMutableDictionary<NSString *, CCLibraryRows *> *_rows;
    CCCancel *_downloadCancel, *_lyricsCancel, *_folderCancel;
    NSTimeInterval _lastFolderPost, _lastLyricsPost, _lastGapsPost;
    CCCatalogNode *_sheetNode;
    BOOL _sheetLoading;
    CCCancel *_gapsCancel, *_rulesCancel;
    NSInteger _rulesGeneration, _diskGeneration;
    CCCatalogRelations *_relations;
    NSArray<CCDownloadFile *> *_runFiles;
    NSString *_runFolder, *_albumParent;
    BOOL _runIsSelection, _runHadLyrics;
}

+ (CCModel *)shared {
    static CCModel *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [CCModel new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _settings = [CCSettings load];
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { [CCModel.shared rescanDisk]; }];
        _rows = [NSMutableDictionary dictionary];
        _folderCurrent = @"";
        _gapRows = @[];
        _player = [CCPlayer new];
        _player.volume = _settings.playerVolume;
        __weak CCModel *weak = self;
        _player.onFailure = ^(NSString *reason) { [weak toastSymbol:@"exclamationmark.triangle" text:LF(@"player.failed", reason)]; };
        _player.localCopyOf = ^NSString *(CCCatalogNode *node) { return [CCLibrary localCopy:node under:weak.settings.destination] ?: [weak.disk localPathOf:node.path]; };
        _player.onVolume = ^(double volume) {
            weak.settings.playerVolume = volume;
            [weak saveSettings];
        };
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if (version) [CCApiClient setVersion:version];
        _library = [[CCLibrary alloc] initWithApi:[[CCApiClient alloc] initWithConfiguration:nil]
                                           engine:[[CCDownloadEngine alloc] initWithConfiguration:nil]
                                            cache:[[CCCatalogCache alloc] initWithDirectory:CCSettings.cacheDirectory]];
    }
    return self;
}

- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:CCModelDidChangeNotification object:self]; }

- (void)setPage:(CCPage)page {
    if (_page == page) return;
    _page = page;
    [NSNotificationCenter.defaultCenter postNotificationName:CCModelPageNotification object:self];
}

- (void)toastSymbol:(NSString *)symbol text:(NSString *)text {
    [NSNotificationCenter.defaultCenter postNotificationName:CCModelToastNotification object:self userInfo:@{ @"symbol": symbol, @"text": text }];
}

// ───────────── startup and catalog ─────────────

- (void)start {
    _catalogLoading = YES;
    [self changed];
    BOOL lyrics = self.settings.lyricsEnabled, refreshOnLaunch = self.settings.refreshOnLaunch;
    Background(^{
        BOOL cached = [self.library loadCached];
        Main(^{
            if (cached) {
                self->_catalogLoading = NO;
                [self catalogSwapped];
            }
            if (!cached || (refreshOnLaunch && self.library.catalogIsStale)) [self refreshCatalog];
        });
        if ([self.library loadCachedLyrics]) Main(^{ [self changed]; });
        // The words are kept until the API has something new; only then are they fetched again.
        if (refreshOnLaunch && self.library.cache.songsTime && [self.library lyricsChangedOnServer]) Main(^{ [self updateLyrics]; });
    });
}

- (CCCatalog *)catalog { return self.library.catalog; }

- (void)rescanDisk {
    CCCatalog *catalog = self.catalog;
    if (!catalog || _downloading) return;
    NSInteger generation = ++_diskGeneration;
    NSString *destination = self.settings.destination;
    Background(^{
        CCDiskState *state = [CCDiskState scan:catalog under:destination];
        Main(^{
            if (generation != self->_diskGeneration) return;
            self->_disk = state;
            [self changed];
        });
    });
}

- (long long)missingSelectedBytes {
    long long bytes = 0;
    for (CCCatalogNode *node in self.catalog.selectedFilesList)
        if (![_disk has:node.path]) bytes += node.size;
    return bytes;
}

- (void)catalogSwapped {
    _relations = nil;
    [self rescanDisk];
    CCCatalog *catalog = self.catalog;
    Background(^{
        // Tens of thousands of names: built aside, for a menu to read at once.
        CCCatalogRelations *relations = [[CCCatalogRelations alloc] initWithCatalog:catalog];
        Main(^{
            if (self.catalog == catalog) self->_relations = relations;
        });
    });
    for (CCCatalogSection *section in self.catalog.sections) _rows[section.identifier].section = section;
    [NSNotificationCenter.defaultCenter postNotificationName:CCModelCatalogNotification object:self];
    [self changed];
}

- (void)refreshCatalog {
    if (_catalogRefreshing || _downloading) return;
    _catalogRefreshing = YES;
    _catalogError = nil;
    if (!self.catalog) _catalogLoading = YES;
    [self changed];
    Background(^{
        NSError *error = nil;
        CCCatalog *fresh = [self.library fetchCatalog:nil error:&error];
        NSString *message = error.localizedDescription ?: @"";
        Main(^{
            self->_catalogRefreshing = NO;
            self->_catalogLoading = NO;
            if (fresh) {
                self->_catalogOffline = NO;
                [self.library adoptCatalog:fresh];
                [self catalogSwapped];
            } else if (self.catalog) {
                self->_catalogOffline = YES;
                [self changed];
            } else {
                self->_catalogError = message;
                [self changed];
            }
        });
    });
}

- (NSString *)relativeDate:(NSDate *)date {
    NSRelativeDateTimeFormatter *f = [NSRelativeDateTimeFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:CCLocalization.shared.code];
    f.dateTimeStyle = NSRelativeDateTimeFormatterStyleNamed;
    return [f localizedStringForDate:date relativeToDate:[NSDate date]];
}

// ───────────── selection ─────────────

- (long long)selectedBytes { return self.catalog.selectedBytes; }
- (int)selectedFiles { return self.catalog.selectedFiles; }

- (void)setNode:(CCCatalogNode *)node selected:(BOOL)selected {
    [CCCatalog select:node selected:selected];
    [self changed];
}

- (void)setNodes:(NSArray<CCCatalogNode *> *)nodes selected:(BOOL)selected {
    for (CCCatalogNode *node in nodes) [CCCatalog select:node selected:selected];
    [self changed];
}

- (void)setSection:(CCCatalogSection *)section selected:(BOOL)selected { [self setNodes:section.rows selected:selected]; }

- (void)selectEverything:(BOOL)selected {
    if (self.catalog) [self setNode:self.catalog.root selected:selected];
}

- (CCLibraryRows *)rowsForSection:(NSString *)identifier {
    CCLibraryRows *rows = _rows[identifier];
    if (rows) return rows;
    CCCatalogSection *section = [self.catalog section:identifier];
    if (!section) return nil;
    return _rows[identifier] = [[CCLibraryRows alloc] initWithSection:section];
}

// ───────────── download ─────────────

static long long FreeSpace(NSString *folder) {
    // The destination's nearest parent that exists: the folder itself may not be there yet.
    NSString *path = folder;
    NSFileManager *fm = NSFileManager.defaultManager;
    while (path.length > 1 && ![fm fileExistsAtPath:path]) path = path.stringByDeletingLastPathComponent;
    NSNumber *important = nil;
    if ([[NSURL fileURLWithPath:path] getResourceValue:&important forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil] && important.longLongValue > 0)
        return important.longLongValue;
    NSNumber *free = [fm attributesOfFileSystemForPath:path error:nil][NSFileSystemFreeSize];
    return free ? free.longLongValue : LLONG_MAX;
}

- (void)download {
    if (_overlayVisible || self.selectedFiles == 0) return;
    [self confirmAndRun:self.library.selectedDownloadFiles isSelection:YES bytes:self.selectedBytes];
}

- (void)downloadNode:(CCCatalogNode *)node {
    if (_overlayVisible || node.isDirectory) return;
    [self confirmAndRun:@[ [CCDownloadFile path:node.path size:node.size] ] isSelection:NO bytes:node.size];
}

- (void)downloadAlbum:(CCCatalogNode *)node {
    if (_overlayVisible || !node.isDirectory || node.fileCount == 0) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.message = L(@"download.pickAlbumFolder");
    NSString *start = _albumParent ?: self.settings.destination.stringByDeletingLastPathComponent;
    panel.directoryURL = [NSURL fileURLWithPath:start];
    void (^picked)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        self->_albumParent = panel.URL.path;
        NSArray *files = [CCLibrary albumFiles:node];
        [self confirmAndRun:files isSelection:NO bytes:node.size to:panel.URL.path];
    };
    NSWindow *window = NSApp.mainWindow ?: NSApp.keyWindow;
    if (window) [panel beginSheetModalForWindow:window completionHandler:picked];
    else picked([panel runModal]);
}

- (void)downloadRuleNode:(CCCatalogNode *)node {
    if (_overlayVisible || node.isDirectory) return;
    CCRuleOptions *options = self.ruleOptions;
    BOOL clip = NO;
    for (CCSongGroup *g in self.rulesResult.kept)
        for (CCSongVersion *v in g.versions)
            if (g.isClip && [v.file.path isEqualToString:node.path]) clip = YES;
    NSString *target = options.oneFolder ? [NSString stringWithFormat:@"%@/%@", clip ? options.clipsFolderName : options.folderName, node.name] : nil;
    [self confirmAndRun:@[ [CCDownloadFile path:node.path size:node.size target:target] ] isSelection:NO bytes:node.size];
}

- (void)downloadRuleGroups:(NSArray<CCSongGroup *> *)groups {
    if (_overlayVisible || groups.count == 0) return;
    NSArray *files = [CCSongRules files:groups options:self.ruleOptions];
    long long bytes = 0;
    for (CCDownloadFile *f in files) bytes += f.size;
    [self confirmAndRun:files isSelection:NO bytes:bytes];
}

- (void)confirmAndRun:(NSArray<CCDownloadFile *> *)wanted isSelection:(BOOL)isSelection bytes:(long long)wantedBytes {
    [self confirmAndRun:wanted isSelection:isSelection bytes:wantedBytes to:nil];
}

/// With a folder of its own the run looks only there: a copy in the download folder is no reason to skip a track.
- (void)confirmAndRun:(NSArray<CCDownloadFile *> *)wanted isSelection:(BOOL)isSelection bytes:(long long)wantedBytes to:(nullable NSString *)folder {
    NSString *destination = folder ?: self.settings.destination;
    CCCatalog *catalog = self.catalog;
    Background(^{
        // Looked at afresh: only what is not in the folder yet is offered.
        CCDiskState *state = folder ? nil : [CCDiskState scan:catalog under:destination];
        NSMutableArray<CCDownloadFile *> *missing = [NSMutableArray array];
        long long bytes = 0;
        for (CCDownloadFile *f in wanted) {
            NSString *target = folder ? [CCLocalPath resolve:f.target ?: f.apiPath under:folder] : nil;
            if (folder ? (target && [CCDownloadEngine isComplete:target size:f.size]) : [state has:f.apiPath]) continue;
            [missing addObject:f];
            bytes += f.size;
        }
        NSArray<CCDownloadFile *> *files = missing;
        long long needed = [CCLibrary bytesStillNeeded:files under:destination];
        long long free = FreeSpace(destination);
        Main(^{
            if (state) self->_disk = state;
            if (files.count == 0) {
                [self toastSymbol:@"checkmark.circle" text:L(@"download.allThere")];
                [self changed];
                return;
            }
            void (^answered)(BOOL) = ^(BOOL ok) {
                if (ok) [self begin:files isSelection:isSelection to:folder];
            };
            if (needed > free && self.confirm) {
                self.confirm(L(@"download.noSpaceTitle"), LF(@"download.noSpaceBody", CCFormatBytes(needed), CCFormatBytes(free)), L(@"download.anyway"), YES, answered);
            } else if (self.settings.confirmDownloads && self.confirm && files.count > 1) {   // one file off its row needs no second click
                NSString *body = LF(@"download.confirmBody", CCFormatCount((long long)files.count), destination);
                if (self.settings.lyricsEnabled) body = [NSString stringWithFormat:@"%@ %@", body, L(@"download.confirmLyrics")];
                self.confirm(LF(@"download.confirmTitle", CCFormatBytes(bytes)), body, L(@"download.start"), NO, answered);
            } else {
                [self begin:files isSelection:isSelection to:folder];
            }
        });
    });
}

- (void)begin:(NSArray<CCDownloadFile *> *)files isSelection:(BOOL)isSelection to:(nullable NSString *)folder {
    if (_downloading || files.count == 0) return;
    _runFiles = files;
    _runFolder = folder;
    _runIsSelection = isSelection;
    CCSettings *s = self.settings;
    NSString *destination = folder ?: s.destination;
    NSInteger parallel = s.parallel;
    BOOL wantLyrics = s.lyricsEnabled;
    _runHadLyrics = wantLyrics;
    CCLyricsOptions *options = wantLyrics ? [CCLyricsOptions embed:s.lyricsEmbed sidecar:s.lyricsSidecar timedInTag:s.lyricsTimedInTag] : nil;
    CCCancel *cancel = [CCCancel new];
    _downloadCancel = cancel;

    CCDownloadProgress *start = [CCDownloadProgress new];
    start.totalFiles = (NSInteger)files.count;
    for (CCDownloadFile *f in files) start.totalBytes += f.size;
    _progress = start;
    _report = nil;
    _downloading = YES;
    _stopping = NO;
    _gettingLyrics = wantLyrics;
    _overlayVisible = YES;
    [self postDownloadState];

    Background(^{
        CCLyricsIndex *index = nil;
        NSError *lyricsError = nil;
        if (wantLyrics) index = [self.library ensureLyricsForce:NO progress:nil cancel:cancel error:&lyricsError];
        NSString *lyricsFailure = !wantLyrics || index || cancel.cancelled ? nil : lyricsError.localizedDescription ?: @"";
        Main(^{
            self->_gettingLyrics = NO;
            if (lyricsFailure) {
                self->_runHadLyrics = NO;
                [self toastSymbol:@"exclamationmark.triangle" text:LF(@"lyrics.failed", lyricsFailure)];
            }
            [self postDownloadState];
            [self changed];
        });
        CCDownloadReport *report;
        if (cancel.cancelled) {
            report = [CCDownloadReport new];
            report.stopped = YES;
        } else {
            report = [self.library download:files to:destination parallel:parallel lyrics:index options:options
                                   progress:^(CCDownloadProgress *progress) {
                Main(^{
                    if (self->_downloadCancel != cancel) return;
                    self->_progress = progress;
                    [NSNotificationCenter.defaultCenter postNotificationName:CCModelDownloadProgressNotification object:self];
                });
            } cancel:cancel];
        }
        Main(^{ [self finished:report]; });
    });
}

- (void)finished:(CCDownloadReport *)report {
    _downloading = NO;
    _stopping = NO;
    _gettingLyrics = NO;
    _report = report;
    _downloadCancel = nil;
    // What arrived is done with, what failed stays ticked; a stopped run keeps everything for the run that continues it.
    if (!report.stopped && _runIsSelection) [self.library keepOnlySelected:[report.failures valueForKey:@"apiPath"]];
    [self postDownloadState];
    [self changed];
    [self rescanDisk];
}

- (BOOL)lastRunHadLyrics { return _runHadLyrics && _report != nil && !_report.stopped; }

- (void)postDownloadState {
    [NSNotificationCenter.defaultCenter postNotificationName:CCModelDownloadStateNotification object:self];
}

- (void)stopDownload {
    if (!_downloading || _stopping) return;
    _stopping = YES;
    [_downloadCancel cancel];
    [self postDownloadState];
}

- (void)closeOverlay {
    if (_downloading) return;
    _overlayVisible = NO;
    [self postDownloadState];
    [self changed];
}

- (void)retryFailed {
    if (_downloading || _report.failures.count == 0) return;
    NSSet *failed = [NSSet setWithArray:[_report.failures valueForKey:@"apiPath"]];
    NSMutableArray *again = [NSMutableArray array];
    for (CCDownloadFile *f in _runFiles)
        if ([failed containsObject:f.apiPath]) [again addObject:f];
    if (_runIsSelection) [self.library keepOnlySelected:failed.allObjects];
    [self changed];
    [self begin:again isSelection:_runIsSelection to:_runFolder];
}

- (void)showDownloadFolder {
    NSString *folder = (_overlayVisible ? _runFolder : nil) ?: self.settings.destination;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:folder]];
}

- (void)chooseDownloadFolder:(NSWindow *)window completion:(void (^)(void))completion {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.message = L(@"download.pickFolder");
    NSString *current = self.settings.destination;
    NSFileManager *fm = NSFileManager.defaultManager;
    while (current.length > 1 && ![fm fileExistsAtPath:current]) current = current.stringByDeletingLastPathComponent;
    panel.directoryURL = [NSURL fileURLWithPath:current];
    [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        self.settings.destination = panel.URL.path;
        [self saveSettings];
        [self changed];
        [self rescanDisk];
        if (completion) completion();
    }];
}

// ───────────── lyrics ─────────────

- (void)setLyricsEnabled:(BOOL)enabled {
    self.settings.lyricsEnabled = enabled;
    [self saveSettings];
    if (enabled) [self fetchLyrics:NO];
    else [self changed];
}

- (void)updateLyrics { [self fetchLyrics:YES]; }

- (void)fetchLyrics:(BOOL)force {
    if (_lyricsLoading) return;
    _lyricsLoading = YES;
    _lyricsDone = 0;
    _lyricsTotal = 0;
    _lyricsError = nil;
    [self changed];
    CCCancel *cancel = [CCCancel new];
    _lyricsCancel = cancel;
    Background(^{
        NSError *error = nil;
        CCLyricsIndex *index = [self.library ensureLyricsForce:force progress:^(NSInteger done, NSInteger total) {
            Main(^{
                self->_lyricsDone = done;
                self->_lyricsTotal = total;
                [self changed];
            });
        } cancel:cancel error:&error];
        NSString *message = error.localizedDescription ?: @"";
        Main(^{
            self->_lyricsLoading = NO;
            self->_lyricsError = index ? nil : message;
            [self changed];
        });
    });
}

- (void)addLyricsToFolder:(NSString *)folder {
    if (_folderRunning) return;
    CCSettings *s = self.settings;
    CCLyricsOptions *options = [CCLyricsOptions embed:s.lyricsEmbed sidecar:s.lyricsSidecar timedInTag:s.lyricsTimedInTag];
    CCCancel *cancel = [CCCancel new];
    _folderCancel = cancel;
    _folderRunning = YES;
    _folderDone = 0;
    _folderTotal = 0;
    _folderCurrent = @"";
    _folderReport = nil;
    _lyricsError = nil;
    _lastFolderPost = 0;
    [self changed];
    Background(^{
        NSError *error = nil;
        CCLibrary *library = self.library; // the block below is short-lived, not a cycle
        CCLyricsRunReport *report = [library addLyricsToFolder:folder options:options progress:^(NSInteger done, NSInteger total, NSString *name) {
            Main(^{
                self->_folderDone = done;
                self->_folderTotal = total;
                self->_folderCurrent = name;
                NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
                if (now - self->_lastFolderPost < 0.05) return;
                self->_lastFolderPost = now;
                [self changed];
            });
        } cancel:cancel error:&error];
        NSString *message = error.localizedDescription ?: @"";
        Main(^{
            self->_folderRunning = NO;
            self->_folderReport = report;
            if (!report && !cancel.cancelled) self->_lyricsError = message;
            [self changed];
        });
    });
}

- (void)stopFolder { [_folderCancel cancel]; }

// ───────────── player and rows ─────────────

- (void)playNode:(CCCatalogNode *)node {
    NSString *local = [CCLibrary localCopy:node under:self.settings.destination] ?: [_disk localPathOf:node.path];
    [self.player play:node localCopy:local];
}

- (void)previewNode:(CCCatalogNode *)node {
    [NSNotificationCenter.defaultCenter postNotificationName:CCModelPreviewNotification object:self userInfo:@{ @"node": node }];
}

- (CCCatalogRelations *)relations { return _relations; }

- (NSString *)sectionOf:(CCCatalogNode *)node {
    for (CCCatalogSection *section in self.catalog.sections)
        for (CCCatalogNode *row in section.rows)
            if (row == node || [node.path hasPrefix:[row.path stringByAppendingString:@"/"]]) return section.identifier;
    return nil;
}

- (void)revealNode:(CCCatalogNode *)node {
    [NSNotificationCenter.defaultCenter postNotificationName:CCModelRevealNotification object:self userInfo:@{ @"node": node }];
}

- (void)findVersionsOf:(CCCatalogNode *)node {
    [NSNotificationCenter.defaultCenter postNotificationName:CCModelRevealNotification object:self userInfo:@{ @"node": node, @"query": [CCWebLyrics bare:node.name] }];
}

- (void)postLyricsSheet:(NSDictionary *)info {
    [NSNotificationCenter.defaultCenter postNotificationName:CCModelLyricsSheetNotification object:self userInfo:info];
}

/// The sheet opens at once: the first time, the songs take a minute to arrive, and a click that shows nothing looks broken.
- (void)showLyricsOf:(CCCatalogNode *)node {
    _sheetNode = node;
    [self postLyricsSheet:@{ @"title": node.displayName, @"note": L(@"player.loading") }];
    if (_sheetLoading) return;   // the songs on their way serve whichever file was asked for last
    _sheetLoading = YES;
    Background(^{
        NSError *error = nil;
        CCLibrary *library = self.library;
        CCLyricsIndex *index = library.lyrics;
        if (!index && [library loadCachedLyrics]) index = library.lyrics;   // an old copy now beats a minute of waiting
        if (!index)
            index = [library ensureLyricsForce:NO progress:^(NSInteger done, NSInteger total) {
                Main(^{
                    if (self->_sheetNode && self->_sheetLoading)
                        [self postLyricsSheet:@{ @"progress": LF(@"lyrics.loading", CCFormatCount(done), CCFormatCount(total)) }];
                });
            } cancel:nil error:&error];
        NSString *failure = error.localizedDescription ?: @"";
        Main(^{
            self->_sheetLoading = NO;
            CCCatalogNode *asked = self->_sheetNode;
            if (!asked) return;
            NSString *path = asked.path, *title = asked.displayName;
            Background(^{
                CCLyricsMatch *match = [index find:path];
                NSString *words = match.song.lyrics.length > 0 ? match.song.lyrics : match.song.syncedLyrics;
                Main(^{
                    if (self->_sheetNode != asked) return;
                    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:title forKey:@"title"];
                    if (!index) info[@"note"] = LF(@"lyrics.failed", failure);
                    else if (words.length == 0) info[@"note"] = L(@"lyrics.view.none");
                    else if (match.fit == CCLyricsFitOtherRecording) info[@"note"] = L(@"lyrics.view.other");
                    if (words.length > 0) info[@"words"] = words;
                    [self postLyricsSheet:info];
                });
            });
        });
    });
}

- (void)lyricsSheetClosed { _sheetNode = nil; }

// ───────────── missing lyrics ─────────────

- (NSString *)gapsFolder { return _gapsFolder ?: self.settings.destination; }

- (CCLyricsOptions *)currentLyricsOptions {
    CCSettings *s = self.settings;
    return [CCLyricsOptions embed:s.lyricsEmbed sidecar:s.lyricsSidecar timedInTag:s.lyricsTimedInTag];
}

- (void)scanGaps {
    if (_gapsScanning || _gapsSearching) return;
    NSString *folder = self.gapsFolder;
    CCLyricsOptions *options = self.currentLyricsOptions;
    CCCancel *cancel = [CCCancel new];
    _gapsCancel = cancel;
    _gapsScanning = YES;
    _gapsDone = _gapsTotal = 0;
    _gapScan = nil;
    _gapRows = @[];
    _gapsSearched = NO;
    _gapsError = nil;
    [self changed];
    Background(^{
        NSError *error = nil;
        CCLyricsGapScan *scan = [self.library scanForGaps:folder options:options progress:^(NSInteger done, NSInteger total, NSString *name) {
            Main(^{
                self->_gapsDone = done;
                self->_gapsTotal = total;
                NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
                if (now - self->_lastGapsPost < 0.05) return;
                self->_lastGapsPost = now;
                [self changed];
            });
        } cancel:cancel error:&error];
        NSMutableArray *rows = [NSMutableArray array];
        for (CCLyricsGap *gap in scan.gaps) {
            CCGapRow *row = [CCGapRow new];
            row.gap = gap;
            [rows addObject:row];
        }
        NSString *message = cancel.cancelled ? nil : error.localizedDescription;
        Main(^{
            self->_gapsScanning = NO;
            self->_gapScan = scan;
            self->_gapRows = rows;
            self->_gapsError = message;
            [self changed];
        });
    });
}

- (void)searchGaps {
    if (_gapsScanning || _gapsSearching || _gapRows.count == 0) return;
    NSArray *gaps = [_gapRows valueForKey:@"gap"];
    NSDictionary *rowOf = [NSDictionary dictionaryWithObjects:_gapRows forKeys:[gaps valueForKey:@"relative"]];
    for (CCGapRow *row in _gapRows) {
        row.state = CCGapWaiting;
        row.status = nil;
    }
    CCLyricsOptions *options = self.currentLyricsOptions;
    CCCancel *cancel = [CCCancel new];
    _gapsCancel = cancel;
    _gapsSearching = YES;
    _gapsSearched = NO;
    _gapsDone = 0;
    _gapsTotal = (NSInteger)gaps.count;
    _gapsFound = _gapsNotFound = 0;
    [self changed];
    Background(^{
        CCWebLyrics *web = [[CCWebLyrics alloc] initWithConfiguration:nil];
        [self.library searchWeb:gaps web:web options:options progress:^(CCLyricsGapResult *result) {
            Main(^{
                CCGapRow *row = rowOf[result.gap.relative];
                CCWebMatch *m = result.found.match;
                if (m) {
                    row.state = m.fit == CCLyricsFitSameRecording ? CCGapFound : CCGapFoundOther;
                    row.status = LF(m.fit == CCLyricsFitSameRecording ? @"gaps.found" : @"gaps.foundOther", m.source);
                    self->_gapsFound++;
                } else if (result.found.failed.count > 0 && !result.found.closest) {
                    row.state = CCGapFailed;
                    row.status = LF(@"gaps.failed", [result.found.failed componentsJoinedByString:@", "]);
                    self->_gapsNotFound++;
                } else {
                    row.state = CCGapNotFound;
                    row.status = result.found.closest ? [NSString stringWithFormat:@"%@ · %@", L(@"gaps.notFound"), LF(@"gaps.closest", result.found.closest)] : L(@"gaps.notFound");
                    self->_gapsNotFound++;
                }
                self->_gapsDone++;
                [self changed];
            });
        } cancel:cancel];
        Main(^{
            self->_gapsSearching = NO;
            self->_gapsSearched = YES;
            [self changed];
        });
    });
}

- (void)stopGaps { [_gapsCancel cancel]; }

// ───────────── by rules ─────────────

- (CCRuleOptions *)ruleOptions {
    CCSettings *s = self.settings;
    CCRuleOptions *o = [CCRuleOptions new];
    o.sections = [s.rulesSections filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF IN %@", CCCatalog.ruleSectionIds]];
    o.oneVersion = s.rulesOneVersion;
    o.skipReleased = s.rulesSkipReleased;
    o.neverOffer = s.rulesNeverOffer;
    o.skipUnfinished = s.rulesSkipUnfinished;
    o.oneFolder = s.rulesOneFolder;
    o.folderName = L(@"rules.folderName");
    o.withClips = s.rulesWithClips;
    o.clipPaths = s.rulesClipPaths;
    o.clipsFolderName = L(@"rules.clipsFolderName");
    return o;
}

- (void)recomputeRules {
    if (!self.catalog) return;
    [_rulesCancel cancel];
    CCCancel *cancel = [CCCancel new];
    _rulesCancel = cancel;
    NSInteger generation = ++_rulesGeneration;
    CCRuleOptions *options = self.ruleOptions;
    _rulesLoading = YES;
    _rulesError = nil;
    [self changed];
    Background(^{
        NSError *error = nil;
        CCRuleResult *result = [self.library applyRules:options cancel:cancel error:&error];
        NSString *message = error.localizedDescription;
        Main(^{
            if (generation != self->_rulesGeneration) return;
            self->_rulesLoading = NO;
            self->_rulesResult = result;
            self->_rulesError = result ? nil : message;
            [self changed];
        });
    });
}

// ───────────── settings ─────────────

- (void)saveSettings { [self.settings save]; }

- (void)resetSettings {
    [self.settings resetToDefaults];
    [self saveSettings];
    self.player.volume = self.settings.playerVolume;
    self->_rulesResult = nil;
    [self changed];
}

// ───────────── screenshots ─────────────

- (void)previewOverlayRunning {
    CCDownloadProgress *p = [CCDownloadProgress new];
    p.totalFiles = 16;
    p.totalBytes = 94LL * 1024 * 1024;
    p.downloaded = 5;
    p.doneBytes = 41LL * 1024 * 1024;
    p.bytesPerSecond = 3.4 * 1024 * 1024;
    p.active = @[ @"Compilation/1. Released Discography/2. Goodbye & Good Riddance/06 Lucid Dreams.mp3",
                  @"Compilation/1. Released Discography/2. Goodbye & Good Riddance/07 Armed & Dangerous.mp3" ];
    _progress = p;
    _report = nil;
    _downloading = YES;
    _overlayVisible = YES;
    [self postDownloadState];
}

- (void)previewOverlayDone {
    CCDownloadReport *r = [CCDownloadReport new];
    r.downloaded = 15;
    r.alreadyThere = 0;
    r.bytes = 88LL * 1024 * 1024;
    CCDownloadFailure *f = [CCDownloadFailure path:@"Compilation/1. Released Discography/2. Goodbye & Good Riddance/07 Armed & Dangerous.mp3" reason:@"HTTP 404"];
    r.failures = @[ f ];
    _progress.downloaded = 15;
    _progress.failed = 1;
    _progress.doneBytes = _progress.totalBytes;
    _progress.active = @[];
    _report = r;
    _downloading = NO;
    [self postDownloadState];
}

@end
