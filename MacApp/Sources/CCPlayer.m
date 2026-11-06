#import "CCPlayer.h"

NSNotificationName const CCPlayerDidChangeNotification = @"CCPlayerDidChange";
NSNotificationName const CCPlayerTimeNotification = @"CCPlayerTime";

static void *kStatusContext = &kStatusContext;
static void *kControlContext = &kControlContext;

@implementation CCPlayer {
    AVPlayer *_player;
    AVPlayerItem *_item;
    id _timeObserver;
    NSArray<CCCatalogNode *> *_siblings;
}

- (instancetype)init {
    if ((self = [super init])) {
        _volume = 0.8;
        _player = [AVPlayer new];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        [_player addObserver:self forKeyPath:@"timeControlStatus" options:0 context:kControlContext];
        __weak CCPlayer *weak = self;
        _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 4) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) { [weak ticked:time]; }];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reachedEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(failedToEnd:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    }
    return self;
}

- (void)post { [NSNotificationCenter.defaultCenter postNotificationName:CCPlayerDidChangeNotification object:self]; }

- (void)ticked:(CMTime)time {
    if (!_item) return;
    double t = CMTimeGetSeconds(time);
    if (isfinite(t)) _currentTime = t;
    double d = CMTimeGetSeconds(_item.duration);
    if (isfinite(d) && d > 0) _duration = d;
    [NSNotificationCenter.defaultCenter postNotificationName:CCPlayerTimeNotification object:self];
}

- (void)setVolume:(double)volume {
    _volume = MAX(0, MIN(1, volume));
    _player.volume = (float)_volume;
}

- (void)saveVolume {
    if (self.onVolume) self.onVolume(_volume);
}

- (BOOL)isPlayingNode:(CCCatalogNode *)node { return _node != nil && [_node.path isEqualToString:node.path]; }

- (NSUInteger)indexInFolder {
    for (NSUInteger i = 0; i < _siblings.count; i++)
        if ([_siblings[i].path isEqualToString:_node.path]) return i;
    return NSNotFound;
}

- (NSArray<CCCatalogNode *> *)queue { return _siblings ?: @[]; }

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    _player.muted = muted;
    [self post];
}

- (BOOL)hasNext {
    NSUInteger i = self.indexInFolder;
    return i != NSNotFound && i + 1 < _siblings.count;
}

- (BOOL)hasPrevious {
    NSUInteger i = self.indexInFolder;
    return i != NSNotFound && i > 0;
}

- (void)stopWatchingItem {
    if (!_item) return;
    [_item removeObserver:self forKeyPath:@"status" context:kStatusContext];
    _item = nil;
}

- (void)play:(CCCatalogNode *)node localCopy:(NSString *)path {
    NSMutableArray *siblings = [NSMutableArray array];
    for (CCCatalogNode *n in node.parent.children)
        if (!n.isDirectory && [CCLibrary isPlayable:n.name]) [siblings addObject:n];
    _siblings = siblings.count > 0 ? siblings : @[ node ];
    _node = node;
    _currentTime = 0;
    _duration = 0;
    _loading = YES;
    _playing = YES;
    NSURL *url = path ? [NSURL fileURLWithPath:path] : [CCApiClient downloadURL:node.path];

    [self stopWatchingItem];
    NSDictionary *options = path ? @{} : @{ @"AVURLAssetHTTPHeaderFieldsKey": @{ @"User-Agent": CCApiClient.userAgent } };
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
    _item = [AVPlayerItem playerItemWithAsset:asset];
    [_item addObserver:self forKeyPath:@"status" options:0 context:kStatusContext];
    _player.volume = (float)_volume;
    [_player replaceCurrentItemWithPlayerItem:_item];
    [_player play];
    [self post];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kStatusContext && context != kControlContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (context == kStatusContext) [self statusChanged];
        else [self controlChanged];
    });
}

- (void)controlChanged {
    AVPlayerTimeControlStatus status = _player.timeControlStatus;
    BOOL wasLoading = _loading;
    if (status == AVPlayerTimeControlStatusPlaying) _loading = NO;
    if (status == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) _loading = YES;
    if (status == AVPlayerTimeControlStatusPaused) _loading = NO;
    if (wasLoading != _loading) [self post];
}

- (void)fail:(NSString *)reason {
    _playing = NO;
    _loading = NO;
    [_player pause];
    if (self.onFailure) self.onFailure(reason ?: @"");
    [self post];
}

- (void)statusChanged {
    if (_item.status == AVPlayerItemStatusFailed) {
        [self fail:_item.error.localizedDescription];
    } else if (_item.status == AVPlayerItemStatusReadyToPlay) {
        double d = CMTimeGetSeconds(_item.duration);
        if (isfinite(d) && d > 0) _duration = d;
        [self post];
    }
}

- (void)failedToEnd:(NSNotification *)n {
    if (n.object != _item) return;
    NSError *error = n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    dispatch_async(dispatch_get_main_queue(), ^{ [self fail:error.localizedDescription]; });
}

- (void)reachedEnd:(NSNotification *)n {
    if (n.object != _item) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.hasNext) {
            [self next];
            return;
        }
        // The end of the folder: stopped, and back at the start of the track.
        self->_playing = NO;
        [self->_player pause];
        [self->_player seekToTime:kCMTimeZero];
        self->_currentTime = 0;
        [self post];
    });
}

- (void)togglePlay {
    if (!_node) return;
    if (_playing) {
        _playing = NO;
        [_player pause];
    } else {
        _playing = YES;
        [_player play];
    }
    [self post];
}

- (void)pause {
    if (_playing) [self togglePlay];
}

- (void)go:(NSInteger)delta {
    NSUInteger i = self.indexInFolder;
    if (i == NSNotFound) return;
    NSInteger to = (NSInteger)i + delta;
    if (to < 0 || to >= (NSInteger)_siblings.count) return;
    CCCatalogNode *node = _siblings[(NSUInteger)to];
    [self play:node localCopy:self.localCopyOf ? self.localCopyOf(node) : nil];
}

- (void)next { [self go:1]; }
- (void)previous {
    if (_currentTime > 3) {
        [self seekToFraction:0];
        [NSNotificationCenter.defaultCenter postNotificationName:CCPlayerTimeNotification object:self];
        return;
    }
    [self go:-1];
}

- (void)seekToFraction:(double)fraction {
    if (_duration <= 0) return;
    double t = MAX(0, MIN(1, fraction)) * _duration;
    _currentTime = t;
    [_player seekToTime:CMTimeMakeWithSeconds(t, 600) toleranceBefore:CMTimeMakeWithSeconds(0.1, 600) toleranceAfter:CMTimeMakeWithSeconds(0.1, 600)];
}

- (void)close {
    [_player pause];
    [_player replaceCurrentItemWithPlayerItem:nil];
    [self stopWatchingItem];
    _node = nil;
    _playing = NO;
    _loading = NO;
    [self post];
}

@end
