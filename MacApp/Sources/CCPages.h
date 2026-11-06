// The pages of the sidebar, and the overlays laid over them.
#import <AVKit/AVKit.h>
#import <Cocoa/Cocoa.h>
#import "CCControls.h"
#import "CCModel.h"

NS_ASSUME_NONNULL_BEGIN

/// A list changed under the pointer: what is hovered must be worked out again.
FOUNDATION_EXPORT NSNotificationName const CCHoverDirtyNotification;

@interface CCPageView : CCFlippedView <CCLive>
/// Pulls everything it shows from CCModel.
- (void)refresh;
/// The once-only entrance animations (Entrance.Delay / Entrance.Stagger).
- (void)playEntrance;
@property (nonatomic) BOOL entrancePlayed;
/// The file of the row under the pointer, which Space opens.
- (nullable CCCatalogNode *)hoveredNode;
@end

@interface CCOverviewPage : CCPageView
@end

/// One view for the ten catalog sections: a search, Select All / None and a virtualized list of LibraryRows.
@interface CCSectionPage : CCPageView <NSTableViewDataSource, NSTableViewDelegate>
- (instancetype)initWithSection:(NSString *)identifier index:(NSInteger)index;
/// New rows: a new catalog, or the first time the page shows.
- (void)rebuildRows;
- (void)setNeedsRebuild;
- (void)rebuildIfNeeded;
/// Opens the first folder (screenshots).
- (void)expandFirstForCapture;
/// Clears the search, opens the way to a row, scrolls to it and flashes it.
- (void)reveal:(CCCatalogNode *)node;
/// Puts a search on the page: every version of a song.
- (void)searchFor:(NSString *)text;
@end

@interface CCLyricsPage : CCPageView
@end

/// Download by rules: the preset, the toggles, and the songs they keep.
@interface CCRulesPage : CCPageView
@end

/// Missing Lyrics: what a folder lacks, and asking the web for it.
@interface CCGapsPage : CCPageView
@end

@interface CCSettingsPage : CCPageView
/// Window-level services the page needs.
@property (nonatomic, copy, nullable) void (^applyAppearance)(void);
@end

@interface CCAboutPage : CCPageView
@end

/// A scroll view with a flipped document whose width follows the clip view.
@interface CCScrollPage : NSScrollView
@property (nonatomic, readonly) CCFlippedView *document;
@end

@interface CCDownloadOverlay : CCFlippedView <CCLive>
- (void)show;
- (void)hide;
- (void)refresh;
- (void)celebrate;
@end

@interface CCConfirmDialog : CCFlippedView <CCLive>
- (void)showTitle:(NSString *)title body:(NSString *)body ok:(NSString *)okText danger:(BOOL)danger answer:(void (^)(BOOL ok))answer;
@property (nonatomic, readonly) BOOL isOpen;
- (void)closeWith:(BOOL)result;
@end

/// The bar under the pages while a track is loaded.
@interface CCPlayerBar : CCBox
- (void)refresh;
- (void)tick;
/// The list of what plays next. Opens above the bar, so the window places it.
@property (nonatomic, strong, readonly) NSView *queuePanel;
/// Goes between the pages and the bar.
@property (nonatomic, strong, readonly) NSView *queueBackdrop;
@end

/// Looks at a file before it is downloaded: walks the previewable files of its folder.
@interface CCPreviewSheet : CCFlippedView <CCLive>
- (void)show:(CCCatalogNode *)node;
- (void)step:(NSInteger)delta;
- (void)hide;
- (void)refresh;
@property (nonatomic, readonly) BOOL isOpen;
@property (nonatomic, readonly, nullable) CCCatalogNode *current;
@end

@interface CCLyricsSheet : CCFlippedView <CCLive>
- (void)showTitle:(NSString *)title note:(nullable NSString *)note words:(nullable NSString *)words;
- (void)showProgress:(NSString *)note;
- (void)hide;
@property (nonatomic, readonly) BOOL isOpen;
@end

@interface CCToast : CCBox
- (void)showSymbol:(NSString *)symbol text:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
