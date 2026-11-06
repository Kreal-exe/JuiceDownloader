#import "CCWindow.h"
#import "CCControls.h"
#import "CCPages.h"
#include <dlfcn.h>

static CCModel *M(void) { return CCModel.shared; }

// ───────────── ambient background ─────────────

/// The background colour plus three soft colour blobs that drift slowly (StartAmbientAnimation).
@interface CCBackgroundView : NSView <CCLive>
@property (nonatomic) BOOL translucent;
@end

@implementation CCBackgroundView {
    NSArray<CAGradientLayer *> *_blobs;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        NSMutableArray *blobs = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            CAGradientLayer *blob = [CAGradientLayer layer];
            blob.type = kCAGradientLayerRadial;
            blob.startPoint = CGPointMake(0.5, 0.5);
            blob.endPoint = CGPointMake(1, 1);
            [self.layer addSublayer:blob];
            [blobs addObject:blob];
        }
        _blobs = blobs;
        [self applyTheme];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)setTranslucent:(BOOL)translucent {
    _translucent = translucent;
    [self applyTheme];
}

- (void)applyTheme {
    NSArray *colors = CCTheme.blobColors;
    CCWithoutAnimation(^{
        self.layer.backgroundColor = (self.translucent ? CCTheme.bgTranslucent : CCTheme.bg).CGColor;
        for (NSUInteger i = 0; i < 3; i++) {
            NSColor *c = colors[i];
            self->_blobs[i].colors = CCCGColors(@[ c, [c colorWithAlphaComponent:0] ]);
        }
    });
}

- (void)layout {
    [super layout];
    CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    BOOL down = CCLayerYDown(self.layer);
    // Frames in top-left coordinates, mirroring the XAML margins.
    NSArray<NSValue *> *frames = @[
        [NSValue valueWithRect:NSMakeRect(-220, -320, 820, 820)],
        [NSValue valueWithRect:NSMakeRect(w + 200 - 720, -260, 720, 720)],
        [NSValue valueWithRect:NSMakeRect(w - 120 - 640, h + 380 - 640, 640, 640)],
    ];
    CCWithoutAnimation(^{
        for (NSUInteger i = 0; i < 3; i++) {
            NSRect f = frames[i].rectValue;
            if (!down) f.origin.y = h - f.origin.y - f.size.height;
            self->_blobs[i].frame = f;
        }
    });
}

- (void)startDrifting {
    if (!CCMotionEnabled()) return;
    double drift[3][3] = { { 70, 40, 26 }, { -60, 50, 31 }, { 40, -60, 37 } };
    double sign = CCLayerYDown(self.layer) ? 1 : -1;
    for (int i = 0; i < 3; i++) {
        for (int axis = 0; axis < 2; axis++) {
            double distance = drift[i][axis] * (axis == 1 ? sign : 1);
            double seconds = drift[i][2] * (axis == 1 ? 1.3 : 1);
            CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:axis == 0 ? @"transform.translation.x" : @"transform.translation.y"];
            NSMutableArray *values = [NSMutableArray array];
            for (int k = 0; k <= 120; k++) [values addObject:@(distance * CCEaseSine(k / 120.0))];
            a.values = values;
            a.duration = seconds;
            a.autoreverses = YES;
            a.repeatCount = HUGE_VALF;
            [_blobs[i] addAnimation:a forKey:axis == 0 ? @"x" : @"y"];
        }
    }
}

@end

// ───────────── sidebar ─────────────

@interface CCNavItem : NSView <CCLive>
@property (nonatomic) BOOL selected;
@property (nonatomic, copy) void (^onClick)(void);
@end

@implementation CCNavItem {
    CCBox *_box;
    CCIcon *_icon;
    CCLabel *_label;
    NSTrackingArea *_tracking;
    BOOL _hovered;
}

- (instancetype)initWithSymbol:(NSString *)symbol key:(NSString *)key {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        CCSize(self, 0, 31);
        _box = [[CCBox alloc] initWithFrame:NSZeroRect];
        _box.radius = 12;
        _icon = [CCIcon symbol:symbol size:17 weight:NSFontWeightRegular role:CCRoleMuted];
        _label = [CCLabel key:key size:14 weight:NSFontWeightMedium role:CCRoleMuted];
        NSStackView *row = CCHStack(@[ _icon, _label ], 14);
        [self addSubview:_box];
        [self addSubview:row];
        CCPin(_box, self, NSEdgeInsetsMake(0, 0, 0, 0));
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [row.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_icon.widthAnchor constraintEqualToConstant:22],
        ]];
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityRadioButtonRole;
        self.accessibilityLabel = L(key);
        [self applyTheme];
    }
    return self;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.accessibilityValue = @(selected);
    [self applyTheme];
}

- (void)applyTheme {
    BOOL selected = self.selected, hovered = _hovered;
    _box.fill = ^NSColor *{ return selected ? CCTheme.accentSoft : hovered ? CCTheme.hover : NSColor.clearColor; };
    _label.role = selected || hovered ? CCRoleText : CCRoleMuted;
    _label.font = CCFont(14, selected ? NSFontWeightSemibold : NSFontWeightMedium);
    _icon.role = selected ? CCRoleAccent : hovered ? CCRoleText : CCRoleMuted;
}

- (void)applyLanguage { self.accessibilityLabel = _label.stringValue; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)mouseEntered:(NSEvent *)event { _hovered = YES; [self applyTheme]; }
- (void)mouseExited:(NSEvent *)event { _hovered = NO; [self applyTheme]; }
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds) && self.onClick) self.onClick();
}
- (BOOL)accessibilityPerformPress {
    if (self.onClick) self.onClick();
    return YES;
}

@end

// ───────────── window ─────────────

@interface CCWindow : NSWindow
@property (nonatomic, copy) void (^onEscape)(void);
@end

@implementation CCWindow
- (void)cancelOperation:(id)sender {
    if (self.onEscape) self.onEscape();
}
@end

@implementation CCWindowController {
    NSVisualEffectView *_vibrancy;
    CCBackgroundView *_background;
    NSView *_chrome;
    NSArray<CCNavItem *> *_navItems;
    CCBox *_indicator;
    NSLayoutConstraint *_indicatorTop;
    CCTween *_indicatorTween;
    NSView *_pageHost;
    NSArray<CCPageView *> *_pages;
    CCPage _shownPage;
    CCButton *_themeButton, *_refreshButton, *_download;
    CCSpinner *_refreshSpinner;
    CCCounter *_selectedBytes;
    CCLabel *_selectedFiles;
    CCDownloadOverlay *_overlay;
    CCConfirmDialog *_confirm;
    CCToast *_toast;
    CCPlayerBar *_playerBar;
    NSLayoutConstraint *_pageBottom;
    CCTween *_pageBottomTween;
    BOOL _barShown, _hoverQueued;
    CCLyricsSheet *_lyricsSheet;
    CCPreviewSheet *_preview;
    id _eventMonitor;
    BOOL _wasDark;
    __weak CCDownloadReport *_celebrated;
}

- (instancetype)init {
    CCSettings *s = M().settings;
    NSRect visible = NSScreen.mainScreen.visibleFrame;
    CGFloat width = s.windowWidth >= 980 ? s.windowWidth : 1240;
    CGFloat height = s.windowHeight >= 480 ? s.windowHeight : 800;
    width = MAX(980, MIN(width, visible.size.width - 16));
    height = MAX(MIN(480, visible.size.height - 16), MIN(height, visible.size.height - 16));
    NSRect frame = NSMakeRect(NSMidX(visible) - width / 2, NSMidY(visible) - height / 2, width, height);

    CCWindow *window = [[CCWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                                                             NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"JuiceDownloader";
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.toolbar = [[NSToolbar alloc] initWithIdentifier:@"main"];
    window.toolbarStyle = NSWindowToolbarStyleUnified;
    window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    window.contentMinSize = NSMakeSize(980, 480);
    window.releasedWhenClosed = NO;
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    if ((self = [super initWithWindow:window])) {
        window.delegate = self;
        __weak CCWindowController *weak = self;
        window.onEscape = ^{ [weak escape]; };
        [self build];
        [self observe];
        [self applyAppearance];
        _shownPage = (CCPage)-1;
        [self showPage:M().page];
        [self refresh];
    }
    return self;
}

- (void)build {
    NSView *root = CCAuto([CCFlippedView new]);
    root.wantsLayer = YES;
    self.window.contentView = root;

    _vibrancy = CCAuto([NSVisualEffectView new]);
    _vibrancy.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _vibrancy.material = NSVisualEffectMaterialUnderWindowBackground;
    _vibrancy.state = NSVisualEffectStateActive;
    [root addSubview:_vibrancy];
    CCPin(_vibrancy, root, NSEdgeInsetsMake(0, 0, 0, 0));

    _background = CCAuto([CCBackgroundView new]);
    [root addSubview:_background];
    CCPin(_background, root, NSEdgeInsetsMake(0, 0, 0, 0));

    _chrome = CCAuto([CCFlippedView new]);
    _chrome.wantsLayer = YES;
    [root addSubview:_chrome];
    CCPin(_chrome, root, NSEdgeInsetsMake(0, 0, 0, 0));

    NSView *titlebar = [self buildTitlebar];
    NSView *sidebar = [self buildSidebar];
    _pageHost = CCAuto([CCFlippedView new]);
    [_chrome addSubview:titlebar];
    [_chrome addSubview:sidebar];
    [_chrome addSubview:_pageHost];
    [NSLayoutConstraint activateConstraints:@[
        [titlebar.topAnchor constraintEqualToAnchor:_chrome.topAnchor],
        [titlebar.leadingAnchor constraintEqualToAnchor:_chrome.leadingAnchor],
        [titlebar.trailingAnchor constraintEqualToAnchor:_chrome.trailingAnchor],
        [titlebar.heightAnchor constraintEqualToConstant:52],
        [sidebar.topAnchor constraintEqualToAnchor:titlebar.bottomAnchor constant:4],
        [sidebar.leadingAnchor constraintEqualToAnchor:_chrome.leadingAnchor],
        [sidebar.bottomAnchor constraintEqualToAnchor:_chrome.bottomAnchor],
        [sidebar.widthAnchor constraintEqualToConstant:236],
        [_pageHost.topAnchor constraintEqualToAnchor:titlebar.bottomAnchor constant:4],
        [_pageHost.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [_pageHost.trailingAnchor constraintEqualToAnchor:_chrome.trailingAnchor],
    ]];
    _pageBottom = [_pageHost.bottomAnchor constraintEqualToAnchor:_chrome.bottomAnchor];
    _pageBottom.active = YES;

    // Under the pages, not over them: a list ends above the bar, and nothing is hidden behind it.
    _playerBar = [CCPlayerBar new];
    [_chrome addSubview:_playerBar.queueBackdrop];
    [_chrome addSubview:_playerBar];
    [_chrome addSubview:_playerBar.queuePanel];
    CCPin(_playerBar.queueBackdrop, _chrome, NSEdgeInsetsMake(0, 0, 0, 0));
    [NSLayoutConstraint activateConstraints:@[
        [_playerBar.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:32],
        [_playerBar.trailingAnchor constraintEqualToAnchor:_chrome.trailingAnchor constant:-32],
        [_playerBar.bottomAnchor constraintEqualToAnchor:_chrome.bottomAnchor constant:-14],
        [_playerBar.queuePanel.leadingAnchor constraintEqualToAnchor:_playerBar.leadingAnchor constant:96],
        [_playerBar.queuePanel.bottomAnchor constraintEqualToAnchor:_playerBar.topAnchor constant:-8],
    ]];

    CCSettingsPage *settings = [CCSettingsPage new];
    __weak CCWindowController *weak = self;
    settings.applyAppearance = ^{ [weak applyAppearance]; };
    NSMutableArray *pages = [NSMutableArray arrayWithObject:[CCOverviewPage new]];
    NSArray *sections = CCCatalog.sectionIds;
    for (NSUInteger i = 0; i < sections.count; i++) [pages addObject:[[CCSectionPage alloc] initWithSection:sections[i] index:(NSInteger)i]];
    [pages addObjectsFromArray:@[ [CCRulesPage new], [CCLyricsPage new], [CCGapsPage new], settings, [CCAboutPage new] ]];
    _pages = pages;
    for (CCPageView *page in _pages) {
        page.translatesAutoresizingMaskIntoConstraints = NO;
        page.wantsLayer = YES;
        page.hidden = YES;
        [_pageHost addSubview:page];
        CCPin(page, _pageHost, NSEdgeInsetsMake(0, 0, 0, 0));
    }

    _overlay = CCAuto([CCDownloadOverlay new]);
    _confirm = CCAuto([CCConfirmDialog new]);
    _lyricsSheet = CCAuto([CCLyricsSheet new]);
    _preview = CCAuto([CCPreviewSheet new]);
    _toast = [CCToast new];
    [root addSubview:_overlay];
    [root addSubview:_lyricsSheet];
    [root addSubview:_preview];
    [root addSubview:_confirm];
    [root addSubview:_toast];
    CCPin(_overlay, root, NSEdgeInsetsMake(0, 0, 0, 0));
    CCPin(_lyricsSheet, root, NSEdgeInsetsMake(0, 0, 0, 0));
    CCPin(_preview, root, NSEdgeInsetsMake(0, 0, 0, 0));
    CCPin(_confirm, root, NSEdgeInsetsMake(0, 0, 0, 0));
    [NSLayoutConstraint activateConstraints:@[
        [_toast.topAnchor constraintEqualToAnchor:root.topAnchor constant:64],
        [_toast.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-28],
    ]];

    M().confirm = ^(NSString *title, NSString *body, NSString *okText, BOOL danger, void (^answer)(BOOL)) {
        CCWindowController *s = weak;
        [s->_confirm showTitle:title body:body ok:okText danger:danger answer:answer];
    };
}

- (NSView *)buildTitlebar {
    NSView *bar = CCAuto([CCFlippedView new]);
    CCLogoView *logo = CCAuto([CCLogoView new]);
    CCSize(logo, 24, 24);
    CCLabel *name = [CCLabel key:@"app.name" size:14.5 weight:NSFontWeightSemibold role:CCRoleText];
    NSStackView *brand = CCHStack(@[ logo, name ], 10);
    [bar addSubview:brand];

    _themeButton = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:CCTheme.isDark ? @"moon" : @"sun.max"];
    _themeButton.symbolSize = 15;
    _themeButton.iconView.wantsLayer = YES;
    _themeButton.onClick = ^{
        CCSettings *s = M().settings;
        s.theme = CCTheme.isDark ? @"light" : @"dark";
        [M() saveSettings];
        [CCTheme applyMode:s.theme];
    };
    _refreshSpinner = [[CCSpinner alloc] initWithDiameter:14 lineWidth:2 sweep:270 period:0.9];
    _refreshSpinner.hidden = YES;
    _refreshButton = [CCButton buttonWithStyle:CCButtonSubtle title:nil symbol:@"arrow.clockwise"];
    _refreshButton.fontSize = 12.5;
    _refreshButton.onClick = ^{ [M() refreshCatalog]; };
    NSStackView *actions = CCHStack(@[ _themeButton, _refreshSpinner, _refreshButton ], 10);
    [bar addSubview:actions];
    [NSLayoutConstraint activateConstraints:@[
        // after the traffic lights
        [brand.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:86],
        [brand.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [actions.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-18],
        [actions.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];
    return bar;
}

- (NSView *)buildSidebar {
    NSView *sidebar = CCAuto([CCFlippedView new]);
    NSMutableArray *items = [NSMutableArray array];
    for (NSInteger i = 0; i < CCPageCount; i++) {
        CCNavItem *item = [[CCNavItem alloc] initWithSymbol:CCPageSymbol(i) key:[@"nav." stringByAppendingString:CCPageName(i)]];
        CCPage page = (CCPage)i;
        item.onClick = ^{ M().page = page; };
        [items addObject:item];
    }
    _navItems = items;
    NSStackView *nav = CCVStack(items, 3);
    for (NSView *item in items) [item.widthAnchor constraintEqualToAnchor:nav.widthAnchor].active = YES;

    // Sixteen rows: on a short window they scroll, with the indicator among them.
    CCScrollPage *navScroll = [CCScrollPage new];
    navScroll.automaticallyAdjustsContentInsets = NO;
    NSView *navDoc = navScroll.document;
    [navDoc addSubview:nav];
    [sidebar addSubview:navScroll];

    _indicator = [[CCBox alloc] initWithFrame:NSZeroRect];
    _indicator.radius = 2;
    _indicator.gradient = ^NSArray<NSColor *> *{ return CCTheme.accentGradient; };
    _indicator.layer.shadowOpacity = 0.8;
    _indicator.layer.shadowRadius = 6;
    _indicator.layer.shadowOffset = CGSizeZero;
    [navDoc addSubview:_indicator];
    _indicatorTop = [_indicator.topAnchor constraintEqualToAnchor:nav.topAnchor constant:4.5];

    // What is selected, and the way to get it.
    CCLabel *title = [CCLabel key:@"download.selected" size:13 weight:NSFontWeightSemibold role:CCRoleText];
    CCIcon *icon = [CCIcon symbol:@"arrow.down.circle" size:14 weight:NSFontWeightRegular role:CCRoleAccent];
    NSStackView *top = CCHStack(@[ icon, title, CCSpacer() ], 8);
    _selectedBytes = [CCCounter text:@"" size:22 weight:NSFontWeightBold role:CCRoleText];
    _selectedFiles = [CCLabel text:@"" size:11.5 weight:NSFontWeightRegular role:CCRoleFaint];
    _download = [CCButton buttonWithStyle:CCButtonPrimary title:nil symbol:nil];
    _download.locKey = @"download.button";
    _download.padding = NSEdgeInsetsMake(9, 14, 9, 14);
    _download.fontSize = 13.5;
    _download.onClick = ^{ [M() download]; };
    NSStackView *card = CCVStack(@[ top, _selectedBytes, _selectedFiles, _download ], 0);
    [card setCustomSpacing:8 afterView:top];
    [card setCustomSpacing:2 afterView:_selectedBytes];
    [card setCustomSpacing:12 afterView:_selectedFiles];
    for (NSView *v in @[ top, _download ]) [v.widthAnchor constraintEqualToAnchor:card.widthAnchor].active = YES;
    CCCard *selectedCard = [CCCard card];
    selectedCard.radius = 16;
    [selectedCard addSubview:card];
    CCPin(card, selectedCard, NSEdgeInsetsMake(14, 16, 14, 16));
    [sidebar addSubview:selectedCard];

    [NSLayoutConstraint activateConstraints:@[
        [navScroll.topAnchor constraintEqualToAnchor:sidebar.topAnchor],
        [navScroll.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
        [navScroll.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [navScroll.bottomAnchor constraintEqualToAnchor:selectedCard.topAnchor constant:-10],
        [nav.topAnchor constraintEqualToAnchor:navDoc.topAnchor constant:4],
        [nav.leadingAnchor constraintEqualToAnchor:navDoc.leadingAnchor constant:12],
        [nav.trailingAnchor constraintEqualToAnchor:navDoc.trailingAnchor constant:-12],
        [navDoc.bottomAnchor constraintEqualToAnchor:nav.bottomAnchor constant:4],
        _indicatorTop,
        [_indicator.leadingAnchor constraintEqualToAnchor:navDoc.leadingAnchor constant:4],
        [_indicator.widthAnchor constraintEqualToConstant:4],
        [_indicator.heightAnchor constraintEqualToConstant:22],
        [selectedCard.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:16],
        [selectedCard.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-16],
        [selectedCard.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor constant:-14],
    ]];
    return sidebar;
}

- (void)observe {
    NSNotificationCenter *c = NSNotificationCenter.defaultCenter;
    __weak CCWindowController *weak = self;
    [c addObserverForName:CCModelDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [weak refresh]; }];
    [c addObserverForName:CCModelPageNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [weak showPage:M().page]; }];
    [c addObserverForName:CCModelRevealNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [weak revealNotified:n]; }];
    [c addObserverForName:CCModelLyricsSheetNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        CCWindowController *s = weak;
        if (n.userInfo[@"progress"]) [s->_lyricsSheet showProgress:n.userInfo[@"progress"]];
        else [s->_lyricsSheet showTitle:n.userInfo[@"title"] note:n.userInfo[@"note"] words:n.userInfo[@"words"]];
    }];
    [c addObserverForName:CCModelPreviewNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        CCWindowController *s = weak;
        [s->_preview show:n.userInfo[@"node"]];
    }];
    [c addObserverForName:CCPlayerDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [weak playerChanged]; }];
    [c addObserverForName:CCPlayerTimeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        CCWindowController *s = weak;
        [s->_playerBar tick];
    }];
    // What is hovered is reckoned from the pointer: on every move, on every scroll, whenever a list changes under it.
    [c addObserverForName:NSViewBoundsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        NSView *view = n.object;
        if (view.window == weak.window) [weak queueHoverSync];
    }];
    [c addObserverForName:CCHoverDirtyNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [weak queueHoverSync]; }];
    self.window.acceptsMouseMovedEvents = YES;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskScrollWheel | NSEventMaskLeftMouseUp | NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        CCWindowController *s = weak;
        if (!s) return event;
        if (event.type == NSEventTypeKeyDown) return [s handleKey:event] ? nil : event;
        [s syncHover];
        return event;
    }];
    [c addObserverForName:CCModelCatalogNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [weak catalogChanged]; }];
    [c addObserverForName:CCModelDownloadStateNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [weak downloadStateChanged]; }];
    [c addObserverForName:CCModelDownloadProgressNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        CCWindowController *s = weak;
        [s->_overlay refresh];
    }];
    [c addObserverForName:CCModelToastNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        CCWindowController *s = weak;
        [s->_toast showSymbol:n.userInfo[@"symbol"] text:n.userInfo[@"text"]];
    }];
    [c addObserverForName:CCThemeDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [weak themeChanged]; }];
    [c addObserverForName:CCLanguageDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        CCWindowController *s = weak;
        [s.window.contentView cc_broadcastLanguage];
        [s refresh];
    }];
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"AppleInterfaceThemeChangedNotification" object:nil queue:nil
                                                           usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ [CCTheme systemAppearanceChanged]; });
    }];
    _wasDark = CCTheme.isDark;
}

- (void)themeChanged {
    [self.window.contentView cc_broadcastTheme];
    BOOL dark = CCTheme.isDark;
    if (dark != _wasDark) {
        _wasDark = dark;
        _themeButton.symbol = dark ? @"moon" : @"sun.max";
        CCTransformView(_themeButton.iconView, CCXformMake(1, 0, dark ? -180 : 180), 0, nil);
        CCTransformView(_themeButton.iconView, CCXformIdentity(), 500, CCEaseBack(0.5));
    }
    [self applyAppearance];
    [self refresh];
}

- (void)applyAppearance {
    BOOL translucent = M().settings.backdrop;
    _vibrancy.hidden = !translucent;
    _background.translucent = translucent;
    self.window.opaque = !translucent;
    self.window.backgroundColor = translucent ? NSColor.clearColor : CCTheme.bg;
}

- (void)refresh {
    CCModel *m = M();
    _selectedBytes.bytes = m.selectedBytes;
    _selectedFiles.stringValue = LF(@"library.folderLine", CCFormatCount(m.selectedFiles));
    _download.enabled = m.selectedFiles > 0 && !m.overlayVisible;
    _download.pulsing = _download.enabled;
    BOOL refreshing = m.catalogRefreshing;
    _refreshSpinner.hidden = !refreshing;
    _refreshButton.symbol = refreshing ? nil : @"arrow.clockwise";
    _refreshButton.title = L(refreshing ? @"catalog.refreshing" : @"catalog.refresh");
    _refreshButton.enabled = !refreshing && !m.downloading;
    _themeButton.toolTip = L(@"titlebar.theme");
    for (CCPageView *page in _pages)
        if (!page.hidden) [page refresh];
    if (m.overlayVisible) [_overlay refresh];
    [_preview refresh];
}

- (void)catalogChanged {
    for (CCPageView *page in _pages)
        if ([page isKindOfClass:CCSectionPage.class] && !page.hidden) [(CCSectionPage *)page rebuildRows];
    // Pages out of sight rebuild when they are next shown.
    for (CCPageView *page in _pages)
        if ([page isKindOfClass:CCSectionPage.class] && page.hidden) [(CCSectionPage *)page setNeedsRebuild];
}

- (void)downloadStateChanged {
    [_playerBar refresh];
    CCModel *m = M();
    if (m.overlayVisible && _overlay.hidden) [_overlay show];
    else if (!m.overlayVisible && !_overlay.hidden) [_overlay hide];
    [_overlay refresh];
    _download.enabled = m.selectedFiles > 0 && !m.overlayVisible;
    CCDownloadReport *report = m.report;
    if (m.overlayVisible && report && !report.stopped && report.failures.count == 0 && report.downloaded > 0 && report != _celebrated) {
        _celebrated = report;
        [_overlay celebrate];
    }
}

// ───────────── hover ─────────────

- (void)syncHover {
    NSWindow *window = self.window;
    NSView *content = window.contentView;
    NSView *hit = nil;
    NSPoint p = window.mouseLocationOutsideOfEventStream;
    if (window.isKeyWindow && NSPointInRect(p, [content convertRect:content.bounds toView:nil]))
        hit = [content hitTest:[content.superview convertPoint:p fromView:nil]];
    [content cc_syncHover:hit];
}

/// Many rows can arrive at once: once, when they all have.
- (void)queueHoverSync {
    // Once more when things have settled: the rows of a scrolled list arrive with the next display, after this turn.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncHover) object:nil];
    [self performSelector:@selector(syncHover) withObject:nil afterDelay:0.08];
    if (_hoverQueued) return;
    _hoverQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_hoverQueued = NO;
        [self syncHover];
    });
}

- (void)windowDidResignKey:(NSNotification *)notification { [self syncHover]; }
- (void)windowDidBecomeKey:(NSNotification *)notification { [self syncHover]; }

- (BOOL)handleKey:(NSEvent *)event {
    // Space plays or pauses, unless something is being typed or a dialog is up.
    // Left and right walk the preview's folder.
    if (event.window == self.window && _preview.isOpen && !_confirm.isOpen && (event.keyCode == 123 || event.keyCode == 124)) {
        [_preview step:event.keyCode == 123 ? -1 : 1];
        return YES;
    }
    if (event.window != self.window || event.keyCode != 49 || (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask & ~NSEventModifierFlagCapsLock)) return NO;
    if ([self.window.firstResponder isKindOfClass:NSText.class] || _confirm.isOpen || M().overlayVisible) return NO;
    // As in Quick Look: Space closes what it opened, and opens the file under the pointer at once.
    if (_preview.isOpen) {
        [_preview hide];
        return YES;
    }
    CCCatalogNode *hovered = _shownPage >= 0 ? [_pages[_shownPage] hoveredNode] : nil;
    if (hovered && !hovered.isDirectory && [CCLibrary previewOf:hovered.name] != CCPreviewNone) {
        [M() previewNode:hovered];
        return YES;
    }
    if (!M().player.node) return NO;
    [M().player togglePlay];
    return YES;
}

// ───────────── the player bar ─────────────

- (void)playerChanged {
    BOOL show = M().player.node != nil;
    [_playerBar refresh];
    for (CCPageView *page in _pages)
        if (!page.hidden) [page refresh];
    if (show == _barShown) return;
    _barShown = show;
    // The pages make room first; the bar rises into it.
    double to = show ? -(68 + 14 + 10) : 0;
    [_pageBottomTween stop];
    __weak CCWindowController *weak = self;
    if (show) {
        _playerBar.hidden = NO;
        CCEntrance(_playerBar, 0, 18);
    }
    if (!CCMotionEnabled()) {
        _pageBottom.constant = to;
        _playerBar.hidden = !show;
        return;
    }
    _pageBottomTween = [CCTween from:_pageBottom.constant to:to duration:320 delay:0 ease:CCEaseOut update:^(double v) {
        CCWindowController *s = weak;
        if (s) s->_pageBottom.constant = v;
    } completion:^(BOOL finished) {
        CCWindowController *s = weak;
        if (finished && s && !s->_barShown) s->_playerBar.hidden = YES;
    }];
}

// ───────────── navigation ─────────────

- (void)revealNotified:(NSNotification *)n {
    CCCatalogNode *node = n.userInfo[@"node"];
    NSString *section = [M() sectionOf:node];
    NSUInteger index = section ? [CCCatalog.sectionIds indexOfObject:section] : NSNotFound;
    if (index == NSNotFound) return;
    CCPage page = (CCPage)(CCPageAlbums + (NSInteger)index);
    M().page = page;
    CCSectionPage *target = (CCSectionPage *)_pages[page];
    NSString *query = n.userInfo[@"query"];
    if (query) [target searchFor:query];
    else [target reveal:node];
}


- (void)showPage:(CCPage)page {
    if (page == _shownPage) return;
    BOOL forward = (NSInteger)page >= (NSInteger)_shownPage;
    CCPageView *previous = (NSInteger)_shownPage >= 0 ? _pages[_shownPage] : nil;
    CCPageView *next = _pages[page];
    BOOL first = previous == nil;
    _shownPage = page;
    M().page = page;
    for (NSUInteger i = 0; i < _navItems.count; i++) _navItems[i].selected = i == (NSUInteger)page;
    [self moveIndicator:!first];
    [self queueHoverSync];

    next.hidden = NO;
    if ([next isKindOfClass:CCSectionPage.class]) [(CCSectionPage *)next rebuildIfNeeded];
    [next refresh];
    [_pageHost addSubview:next positioned:NSWindowAbove relativeTo:nil];
    if (!next.entrancePlayed) {
        [next.superview layoutSubtreeIfNeeded];
        [next playEntrance];
    }
    if (!first) CCSlideIn(next, forward ? 24 : -24, 60);

    if (previous) {
        if (!CCMotionEnabled()) {
            previous.hidden = YES;
            return;
        }
        CCAnimateNumber(previous.layer, @"opacity", 0, 160, CCEaseIn, 0);
        CCTransformView(previous, CCXformMake(1, forward ? -12 : 12, 0), 160, CCEaseIn);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.17 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_pages[self->_shownPage] == previous) return;
            previous.hidden = YES;
            CCWithoutAnimation(^{ previous.layer.opacity = 1; });
            CCTransformView(previous, CCXformIdentity(), 0, nil);
        });
    }
}

- (void)moveIndicator:(BOOL)animated {
    CGFloat to = 4.5 + (CGFloat)_shownPage * 34;
    [_indicatorTween stop];
    if (!animated) {
        _indicatorTop.constant = to;
        return;
    }
    __weak CCWindowController *weak = self;
    _indicatorTween = [CCTween from:_indicatorTop.constant to:to duration:420 delay:0 ease:CCEaseSpring update:^(double v) {
        CCWindowController *s = weak;
        if (s) s->_indicatorTop.constant = v;
    } completion:nil];
}

- (void)escape {
    if (_confirm.isOpen) [_confirm closeWith:NO];
    else if (_preview.isOpen) [_preview hide];
    else if (_lyricsSheet.isOpen) [_lyricsSheet hide];
    else if (M().downloading) [M() stopDownload];
    else if (M().overlayVisible) [M() closeOverlay];
}

// ───────────── window events ─────────────

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [(CCBackgroundView *)_background startDrifting];
    if (!CCMotionEnabled()) return;
    CCWithoutAnimation(^{ self->_chrome.layer.opacity = 0; });
    CCAnimateNumber(_chrome.layer, @"opacity", 1, 380, CCEaseOut, 0);
    CCTransformView(_chrome, CCXformMake(0.985, 0, 0), 0, nil);
    CCTransformView(_chrome, CCXformIdentity(), 650, CCEaseOutStrong);
}

- (void)windowWillClose:(NSNotification *)notification {
    NSSize size = self.window.frame.size;
    M().settings.windowMaximized = self.window.zoomed;
    if (!self.window.zoomed) {
        M().settings.windowWidth = size.width;
        M().settings.windowHeight = size.height;
    }
    [M() saveSettings];
    [NSApp terminate:nil];
}

- (void)windowDidResize:(NSNotification *)notification {
    CCXformRelayout(_chrome);
}

// ───────────── screenshots ─────────────

typedef CGImageRef (*CreateWindowImage)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);

- (void)saveWindowTo:(NSString *)path {
    // Deprecated in the SDK but still present at run time, and an app may always capture its own windows.
    CreateWindowImage create = (CreateWindowImage)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (!create) return;
    CGImageRef image = create(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)self.window.windowNumber,
                              kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
    if (!image) return;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    CGImageRelease(image);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
// The step block keeps itself alive until the app quits at the end of the run.
// Shoots the pages in the running theme, with nothing downloaded. --page <name> shoots that page only.
- (void)captureInto:(NSString *)folder {
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    __weak CCWindowController *weak = self;
    __block NSInteger step = 0;
    NSArray *shots = @[ @"overview", @"overview-selected", @"albums", @"albums-open", @"player", @"media", @"rules", @"lyrics", @"gaps", @"settings", @"about", @"confirm", @"overlay", @"overlay-done" ];
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger pageArg = [args indexOfObject:@"--page"];
    if (pageArg != NSNotFound && pageArg + 1 < args.count) shots = @[ args[pageArg + 1] ];
    __block void (^next)(void);
    void (^after)(double, void (^)(void)) = ^(double seconds, void (^block)(void)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
    };
    next = ^{
        CCWindowController *s = weak;
        if (!s) return;
        if (M().catalogRefreshing || M().catalogLoading || M().rulesLoading || M().gapsScanning || M().player.loading) {
            after(0.3, next);
            return;
        }
        if (step > 0) [s saveWindowTo:[folder stringByAppendingPathComponent:[shots[step - 1] stringByAppendingString:@".png"]]];
        if (step == (NSInteger)shots.count) {
            [NSApp terminate:nil];
            return;
        }
        if (step > 0 && [shots[step - 1] isEqualToString:@"player"]) [M().player close]; // one track, for a moment
        NSString *shot = shots[step++];
        CCCatalog *catalog = M().catalog;
        if ([shot isEqualToString:@"overview-selected"]) {
            [CCCatalog select:[catalog section:@"albums"].rows.firstObject selected:YES];
            [CCCatalog select:[catalog section:@"instrumentals"].rows.lastObject selected:YES];
            [[NSNotificationCenter defaultCenter] postNotificationName:CCModelDidChangeNotification object:M()];
        } else if ([shot isEqualToString:@"albums-open"]) {
            [(CCSectionPage *)s->_pages[CCPageAlbums] expandFirstForCapture];
            CCCatalogNode *first = [catalog section:@"albums"].rows.firstObject;
            [CCCatalog select:first.children.firstObject selected:NO];
            [[NSNotificationCenter defaultCenter] postNotificationName:CCModelDidChangeNotification object:M()];
        } else if ([shot isEqualToString:@"player"]) {
            CCCatalogNode *first = [catalog section:@"albums"].rows.firstObject.children.firstObject;
            if (first) [M() playNode:first];
        } else if ([shot isEqualToString:@"gaps"]) {
            M().page = CCPageGaps;
            [M() scanGaps];
        } else if ([shot isEqualToString:@"confirm"]) {
            M().page = CCPageOverview;
            [M() download];
        } else if ([shot isEqualToString:@"overlay"]) {
            [s->_confirm closeWith:NO];
            [M() previewOverlayRunning];
        } else if ([shot isEqualToString:@"overlay-done"]) {
            [M() previewOverlayDone];
        } else {
            for (NSInteger i = 0; i < CCPageCount; i++)
                if ([shot isEqualToString:CCPageName(i)]) M().page = (CCPage)i;
        }
        after(1.6, next);
    };
    after(1.0, next);
}

#pragma clang diagnostic pop

@end
