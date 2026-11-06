// The second opinion after the API, the port of WebLyrics.cs: LRCLIB, NetEase and Genius in turn, then lyrics.ovh, which
// cannot search and only answers about the very name it is given. Everything here is a Juice WRLD song, so a candidate has
// to be credited to him and carry the name asked for. A title's brackets count: "Stuck (Snippet)" is not "Stuck", and on a
// session file only a page that says "session" counts as the session's words. Blocks its thread; call it off the main thread.
#import <Foundation/Foundation.h>
#import "CCDownload.h"
#import "CCLyrics.h"

NS_ASSUME_NONNULL_BEGIN

@interface CCWebMatch : NSObject
@property (nonatomic, copy) NSString *source, *artist, *title, *lyrics;
@property (nonatomic, copy, nullable) NSString *synced, *url;
@property (nonatomic) CCLyricsFit fit;
@end

/// What the sites said about a file: the words, or the nearest thing refused and the sources that failed.
@interface CCWebLyricsResult : NSObject
@property (nonatomic, strong, nullable) CCWebMatch *match;
@property (nonatomic, copy, nullable) NSString *closest;
@property (nonatomic, copy) NSArray<NSString *> *failed;
@end

@interface CCWebLyrics : NSObject
- (instancetype)initWithConfiguration:(nullable NSURLSessionConfiguration *)configuration;
/// NO for tests: no waiting between requests.
@property (nonatomic) BOOL paced;
- (CCWebLyricsResult *)find:(NSString *)path cancel:(nullable CCCancel *)cancel;

/// The song's name with everything that is not its name taken off.
+ (NSString *)bare:(NSString *)name;
/// Tidied words, or nil for an "[Instrumental]" or a stub.
+ (nullable NSString *)tidy:(nullable NSString *)text;
/// The text of a Genius song page: one container per section, each a small tree, with adverts marked inside.
+ (NSString *)geniusLyrics:(NSString *)page;
+ (void)neteaseWords:(NSString *)lrc plain:(NSString *_Nonnull *_Nonnull)plain timed:(NSString *_Nonnull *_Nonnull)timed;
+ (NSString *)slug:(NSString *)names;
/// 1 for the same text, 0 for nothing in common: edit distance over the longer length.
+ (double)similarity:(NSString *)a to:(NSString *)b;
@end

NS_ASSUME_NONNULL_END
