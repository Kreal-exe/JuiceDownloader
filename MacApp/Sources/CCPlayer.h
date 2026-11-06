// Playing a track of the catalog: its downloaded copy, or a stream sent with the app's User-Agent. Next and previous walk
// the playable files of the same folder, then stop at the end.
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import "CCLibrary.h"

NS_ASSUME_NONNULL_BEGIN

/// The track, the state or the time changed.
FOUNDATION_EXPORT NSNotificationName const CCPlayerDidChangeNotification;
/// A time tick only: the bar's clock and slider listen.
FOUNDATION_EXPORT NSNotificationName const CCPlayerTimeNotification;

@interface CCPlayer : NSObject
@property (nonatomic, strong, readonly, nullable) CCCatalogNode *node;
/// Playing or about to: what the play button shows.
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL loading;
@property (nonatomic, readonly) double currentTime, duration;
@property (nonatomic, readonly) BOOL hasNext, hasPrevious;
/// The playable files of the folder, in order: what plays next, and what the queue panel lists.
@property (nonatomic, readonly) NSArray<CCCatalogNode *> *queue;
/// Silent without losing the volume.
@property (nonatomic) BOOL muted;
@property (nonatomic) double volume;
/// A source that would not play.
@property (nonatomic, copy, nullable) void (^onFailure)(NSString *reason);
/// The volume has settled on a new value, to keep.
@property (nonatomic, copy, nullable) void (^onVolume)(double volume);
/// Finds the copy to play for a track Next or Previous moves to: the model knows the download folder.
@property (nonatomic, copy, nullable) NSString *_Nullable (^localCopyOf)(CCCatalogNode *node);

- (void)play:(CCCatalogNode *)node localCopy:(nullable NSString *)path;
- (void)togglePlay;
- (void)pause;
- (void)next;
/// Back to the start of the track, or within its first seconds to the track before.
- (void)previous;
- (void)seekToFraction:(double)fraction;
- (void)saveVolume;
- (void)close;
- (BOOL)isPlayingNode:(CCCatalogNode *)node;
@end

NS_ASSUME_NONNULL_END
