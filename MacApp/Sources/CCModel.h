// The app state of ViewModels/MainViewModel.cs: the catalog and what is selected in it, the download run, the lyrics
// add-on. Views listen for the notifications and pull what they show. The work itself is in CCLibrary.
#import <Cocoa/Cocoa.h>
#import "CCCore.h"
#import "CCLibrary.h"
#import "CCPlayer.h"
#import "CCSettings.h"

NS_ASSUME_NONNULL_BEGIN

/// Anything changed: the selection, a state, a setting.
FOUNDATION_EXPORT NSNotificationName const CCModelDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const CCModelPageNotification;
/// A new catalog is in: section pages rebuild their rows.
FOUNDATION_EXPORT NSNotificationName const CCModelCatalogNotification;
/// The overlay opened, closed, or the run started or ended.
FOUNDATION_EXPORT NSNotificationName const CCModelDownloadStateNotification;
/// A progress tick, four times a second: only the overlay listens.
FOUNDATION_EXPORT NSNotificationName const CCModelDownloadProgressNotification;
/// userInfo: "symbol", "text".
FOUNDATION_EXPORT NSNotificationName const CCModelToastNotification;

/// userInfo: "node". The window opens the node's section and shows it there.
FOUNDATION_EXPORT NSNotificationName const CCModelRevealNotification;
/// userInfo: "title", "note" (may be absent), "words" (may be absent). The lyrics sheet.
FOUNDATION_EXPORT NSNotificationName const CCModelLyricsSheetNotification;

/// userInfo: "node". The preview sheet.
FOUNDATION_EXPORT NSNotificationName const CCModelPreviewNotification;

typedef NS_ENUM(NSInteger, CCPage) {
    CCPageOverview,
    CCPageAlbums,
    CCPageUnofficial,
    CCPageUnreleased,
    CCPageCompilations,
    CCPageSessionEdits,
    CCPageOriginals,
    CCPageStudio,
    CCPageInstrumentals,
    CCPageRemixes,
    CCPageSnippets,
    CCPageMedia,
    CCPageRules,
    CCPageLyrics,
    CCPageGaps,
    CCPageSettings,
    CCPageAbout,
    CCPageCount,
};

/// The name of a page on the command line and in "nav.<name>": overview, albums, … media, rules, lyrics, gaps, settings, about.
NSString *CCPageName(CCPage page);
NSString *CCPageSymbol(CCPage page);
/// The section a page shows, by its place in the catalog's table; -1 for the other pages.
NSInteger CCPageSectionIndex(CCPage page);

typedef NS_ENUM(NSInteger, CCGapState) { CCGapWaiting, CCGapFound, CCGapFoundOther, CCGapNotFound, CCGapFailed };

/// One line of the Missing Lyrics list, updated as the web answers.
@interface CCGapRow : NSObject
@property (nonatomic, strong) CCLyricsGap *gap;
@property (nonatomic) CCGapState state;
/// What to say about it once it is not waiting.
@property (nonatomic, copy, nullable) NSString *status;
@end

@interface CCModel : NSObject
@property (class, nonatomic, readonly) CCModel *shared;
@property (nonatomic, strong, readonly) CCSettings *settings;
@property (nonatomic, strong, readonly) CCLibrary *library;
@property (nonatomic) CCPage page;

/// Reads what is cached and refreshes what is stale, in the background.
- (void)start;

// ── catalog ──
@property (nonatomic, readonly, nullable) CCCatalog *catalog;
/// Nothing to show yet: the first load or fetch is under way.
@property (nonatomic, readonly) BOOL catalogLoading;
@property (nonatomic, readonly) BOOL catalogRefreshing;
/// Failed with nothing cached.
@property (nonatomic, readonly, nullable) NSString *catalogError;
/// Showing the cache because the API did not answer.
@property (nonatomic, readonly) BOOL catalogOffline;
- (void)refreshCatalog;
/// "3 minutes ago", in the interface language.
- (NSString *)relativeDate:(NSDate *)date;

// ── selection ──
@property (nonatomic, readonly) long long selectedBytes;
@property (nonatomic, readonly) int selectedFiles;
- (void)setNode:(CCCatalogNode *)node selected:(BOOL)selected;
- (void)setNodes:(NSArray<CCCatalogNode *> *)nodes selected:(BOOL)selected;
- (void)setSection:(CCCatalogSection *)section selected:(BOOL)selected;
- (void)selectEverything:(BOOL)selected;
/// The rows of a section page; what is open there survives a page change and a refresh.
- (nullable CCLibraryRows *)rowsForSection:(NSString *)identifier;

// ── download ──
@property (nonatomic, readonly) BOOL overlayVisible;
@property (nonatomic, readonly) BOOL downloading;
@property (nonatomic, readonly) BOOL stopping;
@property (nonatomic, readonly) BOOL gettingLyrics;
@property (nonatomic, readonly, nullable) CCDownloadProgress *progress;
/// Set when the run is over.
@property (nonatomic, readonly, nullable) CCDownloadReport *report;
/// The run that just ended had lyrics, so its summary says how they went.
@property (nonatomic, readonly) BOOL lastRunHadLyrics;
/// What is already in the download folder: looked at on launch, after a run, when the folder changes and on coming back to the app.
@property (nonatomic, readonly, nullable) CCDiskState *disk;
- (void)rescanDisk;
/// How much of the selection is not in the folder yet.
- (long long)missingSelectedBytes;
/// The Download button: checks the room and asks first as the settings say, then opens the overlay.
- (void)download;
/// One file off a row, with the same questions and overlay. The selection is left alone.
- (void)downloadNode:(CCCatalogNode *)node;
/// A whole folder of the catalog into a folder the user picks, under its own name: the download folder is left out of it.
- (void)downloadAlbum:(CCCatalogNode *)node;
/// The same for a row of By Rules: it lands where the rules put their files.
- (void)downloadRuleNode:(CCCatalogNode *)node;
- (void)stopDownload;
- (void)closeOverlay;
- (void)retryFailed;
- (void)showDownloadFolder;
/// The folder panel; the block runs when a folder was chosen.
- (void)chooseDownloadFolder:(NSWindow *)window completion:(nullable void (^)(void))completion;

/// Asks before downloading; the block answers with YES to go ahead.
@property (nonatomic, copy, nullable) void (^confirm)(NSString *title, NSString *body, NSString *okText, BOOL danger, void (^answer)(BOOL ok));

// ── lyrics ──
@property (nonatomic, readonly) BOOL lyricsLoading;
@property (nonatomic, readonly) NSInteger lyricsDone, lyricsTotal;
@property (nonatomic, readonly, nullable) NSString *lyricsError;
- (void)setLyricsEnabled:(BOOL)enabled;
/// Fetches the songs again, whatever their age.
- (void)updateLyrics;
@property (nonatomic, readonly) BOOL folderRunning;
@property (nonatomic, readonly) NSInteger folderDone, folderTotal;
@property (nonatomic, readonly) NSString *folderCurrent;
@property (nonatomic, readonly, nullable) CCLyricsRunReport *folderReport;
- (void)addLyricsToFolder:(NSString *)folder;
- (void)stopFolder;

// ── player ──
@property (nonatomic, strong, readonly) CCPlayer *player;
- (void)playNode:(CCCatalogNode *)node;
- (void)previewNode:(CCCatalogNode *)node;

// ── rows ──
- (nullable CCCatalogRelations *)relations;
/// The id of the section a node is shown on.
- (nullable NSString *)sectionOf:(CCCatalogNode *)node;
- (void)revealNode:(CCCatalogNode *)node;
/// Opens the node's section with a search for the song's name.
- (void)findVersionsOf:(CCCatalogNode *)node;
/// Opens the lyrics sheet, fetching the songs when they are not loaded.
- (void)showLyricsOf:(CCCatalogNode *)node;
- (void)lyricsSheetClosed;

// ── missing lyrics ──
@property (nonatomic, copy) NSString *gapsFolder;
@property (nonatomic, readonly) BOOL gapsScanning, gapsSearching;
@property (nonatomic, readonly) NSInteger gapsDone, gapsTotal;
@property (nonatomic, readonly, nullable) CCLyricsGapScan *gapScan;
@property (nonatomic, readonly) NSArray<CCGapRow *> *gapRows;
/// Set when a search has run: its counts.
@property (nonatomic, readonly) NSInteger gapsFound, gapsNotFound;
@property (nonatomic, readonly) BOOL gapsSearched;
@property (nonatomic, readonly, nullable) NSString *gapsError;
- (void)scanGaps;
- (void)searchGaps;
- (void)stopGaps;

// ── by rules ──
@property (nonatomic, readonly) BOOL rulesLoading;
@property (nonatomic, readonly, nullable) CCRuleResult *rulesResult;
@property (nonatomic, readonly, nullable) NSString *rulesError;
- (CCRuleOptions *)ruleOptions;
/// Works the songs out again from the settings.
- (void)recomputeRules;
/// Downloads the groups' picked files: all that are kept, or a narrower run.
- (void)downloadRuleGroups:(NSArray<CCSongGroup *> *)groups;

- (void)saveSettings;
- (void)resetSettings;
- (void)toastSymbol:(NSString *)symbol text:(NSString *)text;

// ── screenshots (--capture) ──
/// Opens the overlay on a made-up run, nothing on the network: running, then over with a failure.
- (void)previewOverlayRunning;
- (void)previewOverlayDone;
@end

/// "2 h 5 min", "3 min", "12 s".
NSString *CCFormatDuration(double seconds);

NS_ASSUME_NONNULL_END
