// Talking to juicewrldapi.com and fetching files: the port of ApiClient.cs, CatalogCache.cs and DownloadEngine.cs.
// Everything here blocks its calling thread, so call it off the main thread; Stop arrives through a CCCancel.
#import <Foundation/Foundation.h>
#import "CCCatalog.h"
#import "CCLyrics.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const CCErrorDomain;
/// The error of work given up because its CCCancel was cancelled.
#define CCErrorCancelled 1
#define CCErrorHTTP 2
#define CCErrorData 3

/// A cancellation token whose waits wake up at once.
@interface CCCancel : NSObject
@property (nonatomic, readonly) BOOL cancelled;
- (void)cancel;
/// Waits; NO when cancelled before the time was up.
- (BOOL)sleep:(NSTimeInterval)seconds;
@end

/// What the catalog needs from the API. See docs/architecture.md for what was learned about it.
@interface CCApiClient : NSObject
@property (class, nonatomic, readonly) NSString *baseURL;
@property (class, nonatomic, readonly) NSString *userAgent;
/// JuiceDownloader/<version>; a client without a usable User-Agent gets 403.
+ (void)setVersion:(NSString *)version;
+ (NSURL *)downloadURL:(NSString *)path;
/// nil configuration: the default one. The tests pass one with a stub protocol.
- (instancetype)initWithConfiguration:(nullable NSURLSessionConfiguration *)configuration;
/// The site asks for one second between requests (robots.txt), and the songs are a list of pages.
@property (nonatomic) NSTimeInterval pageDelay;
@property (nonatomic) NSTimeInterval buildingDelay;
/// The seconds a retry waits are 2, 4, 8 times this.
@property (nonatomic) NSTimeInterval retryUnit;
/// The whole tree in one request. The server may still be building it, which it says instead of answering.
- (nullable NSArray<CCApiItem *> *)fetchTree:(nullable CCCancel *)cancel error:(NSError **)error;
/// A few bytes of a file, for telling copies apart without fetching them.
- (nullable NSData *)bytesOf:(NSString *)path from:(long long)from to:(long long)to cancel:(nullable CCCancel *)cancel error:(NSError **)error;
/// Every song with its lyrics. Pages are counted here: the API's "next" links are http:// and redirect.
/// How many songs the API holds now, or 0 when it cannot say.
- (NSInteger)fetchSongCount;
- (nullable NSArray<CCSong *> *)fetchSongs:(nullable void (^)(NSInteger done, NSInteger total))progress cancel:(nullable CCCancel *)cancel error:(NSError **)error;
@end

/// The last catalog and lyrics seen, in the same JSON the Windows and Linux apps write.
@interface CCCatalogCache : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
- (nullable NSArray<CCApiItem *> *)loadTree;
- (nullable NSArray<CCSong *> *)loadSongs;
- (void)saveTree:(NSArray<CCApiItem *> *)items;
- (void)saveSongs:(NSArray<CCSong *> *)songs;
/// What is known of which files hold the same audio, by their two paths.
- (NSMutableDictionary<NSString *, NSNumber *> *)loadSameAudio;
- (void)saveSameAudio:(NSDictionary<NSString *, NSNumber *> *)known;
@property (nonatomic, readonly, nullable) NSDate *treeTime;
@property (nonatomic, readonly, nullable) NSDate *songsTime;
@end

@interface CCDownloadFile : NSObject
@property (nonatomic, copy, readonly) NSString *apiPath;
@property (nonatomic, readonly) long long size;
/// Where it goes under the download folder, when not at the catalog's own path.
@property (nonatomic, copy, readonly, nullable) NSString *target;
+ (instancetype)path:(NSString *)apiPath size:(long long)size;
+ (instancetype)path:(NSString *)apiPath size:(long long)size target:(nullable NSString *)target;
@end

@interface CCDownloadFailure : NSObject
@property (nonatomic, copy, readonly) NSString *apiPath;
@property (nonatomic, copy, readonly) NSString *reason;
+ (instancetype)path:(NSString *)apiPath reason:(NSString *)reason;
@end

@interface CCDownloadOptions : NSObject
@property (nonatomic, copy) NSString *destination;
@property (nonatomic) NSInteger parallel;     // 8, at most 32
@property (nonatomic) NSInteger maxAttempts;  // 5
@property (nonatomic) NSTimeInterval retryDelay;   // 2 s, doubling
/// A stream that stops sending must not hang a worker for ever: no bytes for this long counts as a dropped connection.
@property (nonatomic) NSTimeInterval stallTimeout; // 60 s
/// Runs on a worker for each file that is on disk when its transfer is over, whether it was just fetched or already there.
@property (nonatomic, copy, nullable) void (^afterFile)(NSString *apiPath, NSString *localPath);
@end

@interface CCDownloadProgress : NSObject
@property (nonatomic) NSInteger totalFiles, downloaded, alreadyThere, failed;
@property (nonatomic) long long totalBytes, doneBytes;
@property (nonatomic) double bytesPerSecond;
@property (nonatomic, copy) NSArray<NSString *> *active;
@property (nonatomic, readonly) NSInteger finished;
@property (nonatomic, readonly) double fraction;
@end

@interface CCDownloadReport : NSObject
@property (nonatomic) NSInteger downloaded, alreadyThere;
@property (nonatomic, copy) NSArray<CCDownloadFailure *> *failures;
@property (nonatomic) BOOL stopped;
@property (nonatomic) long long bytes;
@end

/// Fetches files side by side. A file is written to "name.part" and only takes its real name when every byte is there,
/// so whatever has the real name is complete: a stopped or crashed run resumes where it was, by HTTP range.
@interface CCDownloadEngine : NSObject
- (instancetype)initWithConfiguration:(nullable NSURLSessionConfiguration *)configuration;
/// Whether a file on disk needs no fetching: it has the catalog's size, or differs from it because of the words the
/// lyrics add-on wrote into its tag. Without the second case every tagged MP3 would be fetched again on each run.
+ (BOOL)isComplete:(NSString *)file size:(long long)size;
/// The session's settings for a run: as many connections to the host as files at a time.
- (NSURLSessionConfiguration *)configurationForParallel:(NSInteger)parallel;
- (CCDownloadReport *)run:(NSArray<CCDownloadFile *> *)files
                  options:(CCDownloadOptions *)options
                 progress:(nullable void (^)(CCDownloadProgress *progress))progress
                   cancel:(nullable CCCancel *)cancel;
@end

NS_ASSUME_NONNULL_END
