// Finding the words for a file and putting them on it: the port of Lyrics.cs and Id3Lyrics.cs. Wrong lyrics are worse
// than none. tests/fixtures/lyrics-match.json holds the cases this and the C# class must both pass.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CCSong : NSObject
@property (nonatomic) long long identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy, nullable) NSString *path;
@property (nonatomic, copy, nullable) NSString *eraName;
@property (nonatomic, copy, nullable) NSString *eraDescription;
@property (nonatomic, copy, nullable) NSArray<NSString *> *trackTitles;
@property (nonatomic, copy, nullable) NSString *fileNames;
@property (nonatomic, copy, nullable) NSString *lyrics;
@property (nonatomic, copy, nullable) NSString *syncedLyrics;
@property (nonatomic, copy, nullable) NSString *leakType;
@property (nonatomic, copy, nullable) NSString *length;
+ (nullable instancetype)fromJSON:(id)json;
- (NSDictionary *)JSON;
@end

typedef NS_ENUM(NSInteger, CCLyricsMatchKind) {
    /// The API lists this very file under the song.
    CCLyricsMatchPath,
    /// The song's list of file names holds this name.
    CCLyricsMatchFileName,
    /// The name is one of the song's titles, once session and credit marks are set aside.
    CCLyricsMatchTitle,
    /// The same, with every bracket, track number, date and mix mark set aside.
    CCLyricsMatchLoose,
};
/// "Path", "FileName", "Title", "Loose": the names the fixture uses.
NSString *CCLyricsMatchKindName(CCLyricsMatchKind kind);

/// Whether the words are of the recording the file holds, which is not a given: the API's session entry of "734" runs to
/// 22,000 characters of takes, its released entry to 2,000, and only one of them fits a given file.
typedef NS_ENUM(NSInteger, CCLyricsFit) {
    /// A session file with a session's words, or any other file with a finished song's.
    CCLyricsFitSameRecording,
    /// The nearest the API has: the song's words, but from the other kind of recording.
    CCLyricsFitOtherRecording,
};
/// "SameRecording", "OtherRecording": the names the fixture uses.
NSString *CCLyricsFitName(CCLyricsFit fit);

@interface CCLyricsMatch : NSObject
@property (nonatomic, strong, readonly) CCSong *song;
@property (nonatomic, readonly) CCLyricsMatchKind kind;
@property (nonatomic, readonly) CCLyricsFit fit;
@end

/// Letters and digits only, lower case: the form names are compared in.
NSString *CCLyricsFold(NSString *text);

@interface CCLyricsIndex : NSObject
- (instancetype)initWithSongs:(NSArray<CCSong *> *)songs;
@property (nonatomic, readonly) NSInteger songCount;
@property (nonatomic, readonly) NSInteger withLyrics;
/// The song's words for a file: an API path, or any path ending in the file's name for files already on disk.
- (nullable CCLyricsMatch *)find:(NSString *)path;
/// "3:42", when the API lists this very file with a length.
- (nullable NSString *)lengthOf:(NSString *)path;
/// For a file from elsewhere: its own name first, then with what uploaders add set aside (see plainName:).
- (nullable CCLyricsMatch *)findOnDisk:(NSString *)path;
/// "Juice WRLD _ @channel - Calm_Down Unreleased — copy.mp3" is "Calm Down.mp3": artist, uploader, "Unreleased", a copy mark
/// and a trailing "with stems", "extended" or "unheard" say nothing about the song. Only for files outside the catalog.
+ (NSString *)plainName:(NSString *)name;
+ (BOOL)hasWords:(CCSong *)song;
/// A file cut from a studio session. Going by its own name and tree: the catalog's era folders are called "(Sessions)"
/// too, and what is in those is the finished song.
+ (BOOL)isSessionFile:(NSString *)path;
+ (NSString *)key:(NSString *)name loose:(BOOL)loose;
@end

/// The API's timed words are "[0:07.04] Yeah"; players expect the LRC form, "[00:07.04]Yeah".
@interface CCLrc : NSObject
+ (nullable NSString *)normalize:(nullable NSString *)synced;
+ (NSString *)plain:(NSString *)text;
@end

/// Reads and writes the USLT frame of an MP3's ID3v2 tag, leaving every other frame exactly as it was. The new file is
/// written beside the old one and moved over it, so a failure cannot leave a damaged track.
@interface CCId3Lyrics : NSObject
/// An .mp3 with no tag, or an ID3v2.3/2.4 tag. An older tag is left alone.
+ (BOOL)canTag:(NSString *)file error:(NSError **)error;
+ (BOOL)has:(NSString *)file error:(NSError **)error;
+ (BOOL)write:(NSString *)lyrics to:(NSString *)file error:(NSError **)error;
@end

@interface CCLyricsOptions : NSObject
@property (nonatomic) BOOL embed, sidecar, timedInTag;
+ (instancetype)embed:(BOOL)embed sidecar:(BOOL)sidecar timedInTag:(BOOL)timed;
@end

typedef NS_ENUM(NSInteger, CCLyricsResult) { CCLyricsResultNone, CCLyricsResultWritten, CCLyricsResultAlreadyThere, CCLyricsResultFailed };

@interface CCLyricsWriter : NSObject
/// Puts a song's words on a file: in its tag where the format allows, and beside it as name.lrc (timed) or name.txt
/// (words only). A format this app cannot tag (WAV, M4A, AIFF, a ZIP of a session) always gets the file beside it, or the words would go nowhere.
+ (CCLyricsResult)apply:(CCSong *)song to:(NSString *)file options:(CCLyricsOptions *)options;
/// replace: words already there give way. Only for better ones, the session's own over the song's.
+ (CCLyricsResult)applyWords:(nullable NSString *)words synced:(nullable NSString *)synced to:(NSString *)file options:(CCLyricsOptions *)options replace:(BOOL)replace;
/// Whether a file already carries words, in its tag or beside it.
+ (BOOL)has:(NSString *)file;
@end

NS_ASSUME_NONNULL_END
