// The app's work without a window: what the catalog holds, what the lyrics add-on knows, and the runs that turn a
// selection into files. The port of Library.cs. Everything that talks to the network blocks; call it off the main thread.
#import <Foundation/Foundation.h>
#import "CCCatalog.h"
#import "CCDownload.h"
#import "CCLyrics.h"
#import "CCSongRules.h"
#import "CCWebLyrics.h"

NS_ASSUME_NONNULL_BEGIN

@interface CCLyricsRunReport : NSObject
@property (nonatomic) NSInteger written, alreadyThere, notFound, failed;
@property (nonatomic, copy) NSArray<NSString *> *missing;
@property (nonatomic) BOOL stopped;
@end

typedef NS_ENUM(NSInteger, CCPreviewKind) { CCPreviewNone, CCPreviewImage, CCPreviewVideo, CCPreviewText };

typedef NS_ENUM(NSInteger, CCLyricsGapKind) { CCLyricsGapNoWords, CCLyricsGapOtherRecording };

/// A file with no words, or a session file with only the finished song's.
@interface CCLyricsGap : NSObject
@property (nonatomic, copy) NSString *file, *relative;
@property (nonatomic) CCLyricsGapKind kind;
@property (nonatomic, copy, nullable) NSString *hasWordsOf;
@end

@interface CCLyricsGapScan : NSObject
@property (nonatomic) NSInteger files, fine;
@property (nonatomic, copy) NSArray<CCLyricsGap *> *gaps;
@end

@interface CCLyricsGapResult : NSObject
@property (nonatomic, strong) CCLyricsGap *gap;
@property (nonatomic, strong) CCWebLyricsResult *found;
@property (nonatomic) CCLyricsResult written;
@end

/// What of the catalog is already in a folder, wherever in it: a By Rules download keeps everything in one folder, and
/// a file may have been tagged or given its right extension since. Built by walking the folder once, so ask it freely.
@interface CCDiskState : NSObject
+ (instancetype)scan:(CCCatalog *)catalog under:(NSString *)destination;
/// The folder's own files that are in the catalog, each counted once: one file can sit at several catalog paths.
@property (nonatomic, readonly) NSInteger files;
@property (nonatomic, readonly) long long bytes;
- (BOOL)has:(NSString *)apiPath;
- (nullable NSString *)localPathOf:(NSString *)apiPath;
/// How many of a section's files are there.
- (NSInteger)filesInSection:(NSString *)identifier;
@end

@interface CCLibrary : NSObject
- (instancetype)initWithApi:(CCApiClient *)api engine:(CCDownloadEngine *)engine cache:(CCCatalogCache *)cache;
@property (nonatomic, strong, readonly) CCApiClient *api;
@property (nonatomic, strong, readonly) CCDownloadEngine *engine;
@property (nonatomic, strong, readonly) CCCatalogCache *cache;
/// Swapped on the main thread once the app is running.
@property (atomic, strong, nullable) CCCatalog *catalog;
@property (atomic, strong, nullable) CCLyricsIndex *lyrics;
@property (nonatomic, readonly, nullable) NSDate *updatedAt;
@property (nonatomic, readonly) BOOL catalogIsStale;

/// Reads the last catalog into `catalog`. YES when there was one.
- (BOOL)loadCached;
/// Reads the cached songs into `lyrics`, whatever their age, without touching the network.
- (BOOL)loadCachedLyrics;
/// One small request: does the API now hold a different number of songs than the kept copy? No when it cannot tell.
- (BOOL)lyricsChangedOnServer;

/// Fetches and caches the tree, and returns the new catalog with nothing selected yet.
- (nullable CCCatalog *)fetchCatalog:(nullable CCCancel *)cancel error:(NSError **)error;
/// Adopts a fetched catalog, keeping the selection. On the thread that owns the selection.
- (void)adoptCatalog:(CCCatalog *)fresh;
/// Both of the above in one go (for callers with no window to keep responsive).
- (BOOL)refresh:(nullable CCCancel *)cancel error:(NSError **)error;
+ (void)carrySelectionFrom:(nullable CCCatalog *)from to:(CCCatalog *)to;

/// The songs and their words: from the cache when it is recent, else about thirty polite requests. Offline with an old
/// copy, old words are better than a failed run.
- (nullable CCLyricsIndex *)ensureLyricsForce:(BOOL)force progress:(nullable void (^)(NSInteger done, NSInteger total))progress
                                       cancel:(nullable CCCancel *)cancel error:(NSError **)error;

/// What is selected, as work for the engine. On the thread that owns the selection.
- (NSArray<CCDownloadFile *> *)selectedDownloadFiles;
/// Downloads the files; with an index and options, each audio file gets its words as soon as it is on disk.
- (CCDownloadReport *)download:(NSArray<CCDownloadFile *> *)files to:(NSString *)destination parallel:(NSInteger)parallel
                         lyrics:(nullable CCLyricsIndex *)index options:(nullable CCLyricsOptions *)options
                       progress:(nullable void (^)(CCDownloadProgress *progress))progress cancel:(nullable CCCancel *)cancel;
/// Retries only what failed, which stays selected until it has come through.
- (void)keepOnlySelected:(NSArray<NSString *> *)paths;
/// How much of the selection is not on disk yet (a whole file or a .part counts for what it already holds).
/// Every file of a catalog folder, laid out under one folder named after it.
+ (NSArray<CCDownloadFile *> *)albumFiles:(CCCatalogNode *)album;
+ (long long)bytesStillNeeded:(NSArray<CCDownloadFile *> *)files under:(NSString *)destination;

/// The songs a set of rules keeps. Needs the songs, so it fetches them when they are not known yet. nil with error if not.
- (nullable CCRuleResult *)applyRules:(CCRuleOptions *)options cancel:(nullable CCCancel *)cancel error:(NSError **)error;
+ (BOOL)isAudio:(NSString *)name;
/// What the player plays: audio.
+ (BOOL)isPlayable:(NSString *)name;
/// How a file can be looked at before it is downloaded.
+ (CCPreviewKind)previewOf:(NSString *)name;
/// What lyrics can go with: audio, and a studio session's archive, which gets them beside it.
+ (BOOL)wantsLyrics:(NSString *)path;
/// A place to play a file from: the downloaded copy if there is one of the right size, else nil (stream it).
+ (nullable NSString *)localCopy:(CCCatalogNode *)file under:(NSString *)destination;
/// How the last download's lyrics went: the recording's own words, the nearest the API has, and none.
@property (nonatomic, readonly) NSInteger lastLyricsSame, lastLyricsOther, lastLyricsNone;
/// Everything in a folder whose words are missing or are not of its recording, with the API consulted first (and what
/// it has written as it goes). nil when the songs could not be fetched or the run was stopped (see error).
- (nullable CCLyricsGapScan *)scanForGaps:(NSString *)folder options:(CCLyricsOptions *)options
                                 progress:(nullable void (^)(NSInteger done, NSInteger total, NSString *name))progress
                                   cancel:(nullable CCCancel *)cancel error:(NSError **)error;
/// Asks the sites about each gap, three at a time. A session file that has the song's words only gives them up for a session's.
- (NSArray<CCLyricsGapResult *> *)searchWeb:(NSArray<CCLyricsGap *> *)gaps web:(CCWebLyrics *)web options:(CCLyricsOptions *)options
                                   progress:(nullable void (^)(CCLyricsGapResult *result))progress cancel:(nullable CCCancel *)cancel;
/// The add-on on its own: words for the audio files of any folder, found by their path below it. nil when the songs
/// could not be fetched (see error).
- (nullable CCLyricsRunReport *)addLyricsToFolder:(NSString *)folder options:(CCLyricsOptions *)options
                                         progress:(nullable void (^)(NSInteger done, NSInteger total, NSString *name))progress
                                           cancel:(nullable CCCancel *)cancel error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
