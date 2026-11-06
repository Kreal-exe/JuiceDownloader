// "Download by rules": the catalog's takes as songs, and a file's other places in it. The port of SongRules.cs.
#import <Foundation/Foundation.h>
#import "CCCatalog.h"
#import "CCDownload.h"
#import "CCLyrics.h"

NS_ASSUME_NONNULL_BEGIN

/// What "Download by rules" keeps.
@interface CCRuleOptions : NSObject
/// Section ids to take songs from. The Compilation's trees are the finished songs; the rest of the catalog is raw material.
@property (nonatomic, copy) NSArray<NSString *> *sections;
/// One file per song, the best of its takes.
@property (nonatomic) BOOL oneVersion;
/// Leave out songs that came out officially: their demos are not unreleased music. Off by default.
@property (nonatomic) BOOL skipReleased;
/// Files the user took out of the folder for good: never offered again.
@property (nonatomic, copy, nullable) NSArray<NSString *> *neverOffer;
/// Leave out what was never finished: hook only, or only ever with a verse left open. Off by default.
@property (nonatomic) BOOL skipUnfinished;
/// Everything in one folder, not by era.
@property (nonatomic) BOOL oneFolder;
@property (nonatomic, copy) NSString *folderName;
/// Lives, snippets and bits too short to be songs, each as it is, in a folder of their own. Off by default.
@property (nonatomic) BOOL withClips;
/// Files the user called clips by hand: a live with no mark in its name. Left out like any clip, offered with them.
@property (nonatomic, copy, nullable) NSArray<NSString *> *clipPaths;
@property (nonatomic, copy) NSString *clipsFolderName;
@end

@interface CCSongVersion : NSObject
@property (nonatomic, strong) CCCatalogNode *file;
@property (nonatomic, strong, nullable) CCSong *song;
@property (nonatomic) NSInteger score;
@property (nonatomic, copy) NSString *why;
@end

/// One song and its takes: picked is what gets downloaded.
@interface CCSongGroup : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<CCSongVersion *> *versions;
@property (nonatomic, strong) CCSongVersion *picked;
@property (nonatomic) BOOL isReleasedSong, isUnfinished;
/// A live, a snippet or a bit too short to be a song: offered only with withClips.
@property (nonatomic) BOOL isClip;
@end

@interface CCRuleResult : NSObject
@property (nonatomic, copy) NSArray<CCSongGroup *> *kept;
@property (nonatomic) NSInteger filesConsidered, skippedVersions, skippedReleased, skippedUnfinished;
/// Files left out for having the very same audio as another one kept.
@property (nonatomic) NSInteger skippedCopies;
@property (nonatomic, readonly) long long bytes;
@end

@interface CCSongRules : NSObject
+ (CCRuleResult *)apply:(CCCatalog *)catalog songs:(NSArray<CCSong *> *)songs options:(CCRuleOptions *)options;
/// Where each picked file goes under the download folder: one folder, or the catalog's own.
+ (NSArray<CCDownloadFile *> *)files:(NSArray<CCSongGroup *> *)groups options:(CCRuleOptions *)options;
/// The names a run would fetch, one per line and sorted, for the list on the Download button. Nil when there is nothing.
+ (nullable NSString *)listOf:(NSArray<CCDownloadFile *> *)files;
/// The name a song goes by across its takes: no credits, no version, no session marks, but "(Remix)" and "(Pt. 2)" stay.
+ (NSString *)songKey:(NSString *)name;
@end

/// Files of different names that hold the very same audio, told apart by a sample from the middle of each without their tags.
@interface CCAudioCopies : NSObject
/// same remembers answers between runs, by the two paths. An answer that could not be had keeps both.
+ (CCRuleResult *)remove:(CCRuleResult *)result index:(CCLyricsIndex *)index api:(CCApiClient *)api
                    same:(NSMutableDictionary<NSString *, NSNumber *> *)same cancel:(nullable CCCancel *)cancel;
@end

/// A file's other places in the catalog, for "Also in" on a row's menu: the same song, whatever tree it landed in.
@interface CCCatalogRelations : NSObject
- (instancetype)initWithCatalog:(CCCatalog *)catalog;
- (NSArray<CCCatalogNode *> *)of:(CCCatalogNode *)file;
/// "Compilation/2. Unreleased Discography/7. Goodbye" reads as the way there, without the ordering numbers.
+ (NSString *)place:(CCCatalogNode *)file;
@end

NS_ASSUME_NONNULL_END
