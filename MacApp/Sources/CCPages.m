#import "CCPages.h"
#import "CCSettings.h"
#import <ImageIO/ImageIO.h>

NSNotificationName const CCHoverDirtyNotification = @"CCHoverDirty";

static CCModel *M(void) { return CCModel.shared; }

static CCLabel *H1(NSString *key) { return [CCLabel key:key size:28 weight:NSFontWeightSemibold role:CCRoleText]; }
static CCLabel *H2(NSString *key) { return [CCLabel key:key size:18 weight:NSFontWeightSemibold role:CCRoleText]; }
static CCLabel *Muted(NSString *text, CGFloat size) { return [CCLabel text:text size:size weight:NSFontWeightRegular role:CCRoleMuted]; }
static CCLabel *Caption(NSString *text) { return [CCLabel text:text size:11.5 weight:NSFontWeightRegular role:CCRoleFaint]; }

/// Makes a stack child as wide as the stack. A label stretched this way must not hug its text: labels hug at 750, above
/// the priority a window resize drags with, so a hugging label would hold the whole window at its own width.
static void Stretch(NSStackView *stack, NSView *child) {
    [child.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [child setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
}

static CCColorBlock SectionColor(NSInteger index) {
    return ^NSColor *{ return [CCTheme categoryColor:index]; };
}
static CCColorBlock SectionSoft(NSInteger index) {
    return ^NSColor *{ return [CCTheme categorySoft:index]; };
}

static CCCard *Card(NSView *content, NSEdgeInsets padding) {
    CCCard *card = [CCCard card];
    [card addSubview:content];
    CCPin(content, card, padding);
    return card;
}

static void Stagger(NSArray<NSView *> *views, double step, double base) {
    NSInteger i = 0;
    for (NSView *v in views) {
        if (v.hidden) continue;
        CCEntrance(v, base + i * step, 18);
        i++;
    }
}

/// Just below the window's own size priority: a long text gives way before the window does.
static void GiveWay(NSView *view) {
    [view setContentCompressionResistancePriority:NSLayoutPriorityWindowSizeStayPut - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
}

/// "Select: All None".
static NSStackView *SelectButtons(void (^all)(void), void (^none)(void)) {
    CCLabel *select = Caption(L(@"library.select"));
    select.locKey = @"library.select";
    CCButton *allButton = [CCButton buttonWithStyle:CCButtonSubtle title:nil symbol:nil];
    allButton.locKey = @"library.selectAll";
    allButton.onClick = all;
    CCButton *noneButton = [CCButton buttonWithStyle:CCButtonSubtle title:nil symbol:nil];
    noneButton.locKey = @"library.selectNone";
    noneButton.onClick = none;
    NSStackView *s = CCHStack(@[ select, allButton, noneButton ], 0);
    [s setCustomSpacing:4 afterView:select];
    return s;
}

static void ApplyCheck(CCCheck *check, int selected, int total, BOOL animated) {
    BOOL all = total > 0 && selected >= total;
    BOOL some = selected > 0 && !all;
    if (check.checked != all || check.mixed != some) [check setChecked:all mixed:some animated:animated];
    check.enabled = total > 0;
}

@implementation CCScrollPage

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.drawsBackground = NO;
        self.hasVerticalScroller = YES;
        self.autohidesScrollers = YES;
        self.scrollerStyle = NSScrollerStyleOverlay;
        self.borderType = NSNoBorder;
        self.contentView.drawsBackground = NO;
        self.contentView.postsBoundsChangedNotifications = YES;
        _document = CCAuto([CCFlippedView new]);
        self.documentView = _document;
        [NSLayoutConstraint activateConstraints:@[
            [_document.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_document.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_document.widthAnchor constraintEqualToAnchor:self.contentView.widthAnchor],
        ]];
    }
    return self;
}

@end

@implementation CCPageView

- (void)refresh {}
- (void)playEntrance { self.entrancePlayed = YES; }
- (CCCatalogNode *)hoveredNode { return nil; }
- (void)applyLanguage { [self refresh]; }

@end

// ═════════════════════════════ the catalog's states ═════════════════════════════

/// Stands in for a page while there is no catalog: loading, or failed with nothing cached.
@interface CCCatalogState : CCFlippedView
- (void)refresh;
@end

@implementation CCCatalogState {
    CCIconTile *_busy, *_failed;
    CCLabel *_title, *_detail;
    CCButton *_retry;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _busy = [CCIconTile tileWithSymbol:@"circle" size:56 radius:18 iconSize:1];
        _busy.icon.hidden = YES;
        _busy.fill = ^NSColor *{ return CCTheme.accentSoft; };
        CCSpinner *spinner = [[CCSpinner alloc] initWithDiameter:26 lineWidth:3 sweep:270 period:0.9];
        [_busy addSubview:spinner];
        [NSLayoutConstraint activateConstraints:@[
            [spinner.centerXAnchor constraintEqualToAnchor:_busy.centerXAnchor],
            [spinner.centerYAnchor constraintEqualToAnchor:_busy.centerYAnchor],
        ]];
        _failed = [CCIconTile tileWithSymbol:@"wifi.exclamationmark" size:56 radius:18 iconSize:24];
        _failed.fill = ^NSColor *{ return CCTheme.warningSoft; };
        _failed.icon.role = CCRoleWarning;
        _title = [CCLabel text:@"" size:18 weight:NSFontWeightSemibold role:CCRoleText];
        _detail = Muted(@"", 13);
        _detail.wraps = YES;
        _detail.alignment = NSTextAlignmentCenter;
        _detail.wrapLimit = 460;
        _retry = [CCButton buttonWithStyle:CCButtonPrimary title:nil symbol:@"arrow.clockwise"];
        _retry.locKey = @"catalog.retry";
        _retry.onClick = ^{ [M() refreshCatalog]; };
        NSStackView *stack = CCVStack(@[ _busy, _failed, _title, _detail, _retry ], 10);
        stack.alignment = NSLayoutAttributeCenterX;
        [stack setCustomSpacing:18 afterView:_busy];
        [stack setCustomSpacing:18 afterView:_failed];
        [stack setCustomSpacing:20 afterView:_detail];
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-30],
        ]];
    }
    return self;
}

- (void)refresh {
    CCModel *m = M();
    self.hidden = m.catalog != nil;
    BOOL failed = m.catalogError != nil;
    _busy.hidden = failed;
    _failed.hidden = !failed;
    _title.stringValue = L(failed ? @"catalog.failed" : @"catalog.loading");
    _detail.stringValue = failed ? LF(@"catalog.failed.desc", m.catalogError) : @"";
    _detail.hidden = !failed;
    _retry.hidden = !failed;
}

@end

// ═════════════════════════════ overview ═════════════════════════════

/// A card that says when it has been laid out (the hero decides there how its parts are arranged).
@interface CCLayoutCard : CCCard
@property (nonatomic, copy, nullable) void (^onLayout)(void);
@end

@implementation CCLayoutCard
- (void)layout {
    [super layout];
    if (self.onLayout) self.onLayout();
}
@end

/// One of the ten sections: one click ticks it all, the row itself opens its page.
@interface CCOverviewRow : CCCard
@property (nonatomic, copy) NSString *identifier_;
@property (nonatomic, strong) CCCheck *check;
@property (nonatomic, strong) CCLabel *name, *desc, *files;
@property (nonatomic, strong) CCCounter *bytes;
@end

@implementation CCOverviewRow

+ (instancetype)rowForSection:(NSString *)identifier index:(NSInteger)index {
    CCOverviewRow *row = [self card];
    row.identifier_ = identifier;
    row.radius = 16;
    row.hoverable = YES;
    row.check = [CCCheck new];
    __weak CCOverviewRow *weak = row;
    row.check.onChange = ^(BOOL on) {
        CCCatalogSection *section = [M().catalog section:weak.identifier_];
        if (section) [M() setSection:section selected:on];
    };
    CCIconTile *tile = [CCIconTile tileWithSymbol:CCPageSymbol(CCPageAlbums + index) size:38 radius:11 iconSize:16];
    tile.fill = SectionSoft(index);
    tile.icon.colorBlock = SectionColor(index);
    tile.bounces = YES;
    row.name = [CCLabel key:[@"nav." stringByAppendingString:identifier] size:14.5 weight:NSFontWeightSemibold role:CCRoleText];
    row.desc = Muted(@"", 12.5);
    row.desc.locKey = [NSString stringWithFormat:@"section.%@.desc", identifier];
    GiveWay(row.name);
    [row.desc setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *text = CCVStack(@[ row.name, row.desc ], 3);
    Stretch(text, row.desc);
    row.bytes = [CCCounter text:@"" size:16 weight:NSFontWeightSemibold role:CCRoleText];
    row.files = Caption(@"");
    NSStackView *size = CCVStack(@[ row.bytes, row.files ], 0);
    size.alignment = NSLayoutAttributeTrailing;
    [size.widthAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;
    CCIcon *chevron = [CCIcon symbol:@"chevron.right" size:11 weight:NSFontWeightSemibold role:CCRoleFaint];
    NSStackView *line = CCHStack(@[ row.check, tile, text, size, chevron ], 14);
    [line setCustomSpacing:16 afterView:row.check];
    [line setCustomSpacing:16 afterView:text];
    [text setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row addSubview:line];
    CCPin(line, row, NSEdgeInsetsMake(12, 18, 12, 18));
    row.onClick = ^{
        NSUInteger i = [CCCatalog.sectionIds indexOfObject:weak.identifier_];
        if (i != NSNotFound) M().page = (CCPage)(CCPageAlbums + (NSInteger)i);
    };
    return row;
}

- (void)refresh {
    CCCatalogSection *section = [M().catalog section:self.identifier_];
    self.bytes.bytes = section.size;
    NSInteger have = [M().disk filesInSection:self.identifier_];
    self.files.stringValue = have > 0 ? LF(@"overview.sectionHave", CCFormatCount(section.fileCount), CCFormatCount(have))
                                      : LF(@"library.folderLine", CCFormatCount(section.fileCount));
    ApplyCheck(self.check, section.selectedFiles, section.fileCount, self.window != nil);
}

@end

/// The Overview's search: every file and folder of the catalog that matches. Implemented below, with the rows it shares
/// with the section pages.
@interface CCCatalogSearch : CCFlippedView
@property (nonatomic, copy) NSString *query;
- (void)refresh;
- (nullable CCCatalogNode *)hoveredNode;
@end

@implementation CCOverviewPage {
    CCSearchField *_search;
    CCCatalogSearch *_results;
    CCScrollPage *_scroll;
    CCCatalogState *_state;
    NSStackView *_page;
    CCLayoutCard *_hero;
    CCRing *_ring;
    CCCounter *_number, *_unit, *_catalogBytes;
    CCLabel *_ringCaption, *_selectedLine, *_status, *_catalogLine, *_folderPath, *_updated;
    NSStackView *_heroRight, *_heroSummary;
    CCButton *_download;
    CCBox *_offline;
    CCSegmentBar *_segments;
    NSStackView *_sectionsHeader;
    NSMutableArray<CCOverviewRow *> *_rows;
    NSStackView *_list;
    CCCard *_unreleasedCard;
    CCCheck *_unreleasedCheck;
    CCLabel *_unreleasedSize;
    BOOL _hadCatalog;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) [self build];
    return self;
}

- (void)build {
    _search = [CCSearchField new];
    _search.placeholderKey = @"overview.search";
    __weak CCOverviewPage *searching = self;
    _search.onChange = ^(NSString *text) { [searching searchChanged:text]; };
    [self addSubview:_search];
    _scroll = [CCScrollPage new];
    [self addSubview:_scroll];
    _results = [CCCatalogSearch new];
    _results.translatesAutoresizingMaskIntoConstraints = NO;
    _results.hidden = YES;
    [self addSubview:_results];
    [NSLayoutConstraint activateConstraints:@[
        [_search.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [_search.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:32],
        [_search.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-32],
        [_scroll.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:12],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_results.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:12],
        [_results.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_results.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_results.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    _state = [CCCatalogState new];
    [self addSubview:_state];
    CCPin(_state, self, NSEdgeInsetsMake(0, 0, 0, 0));

    // ── hero ──
    _ring = [CCRing new];
    _number = [CCCounter text:@"" size:42 weight:NSFontWeightBold role:CCRoleText];
    _number.part = CCCounterNumber;
    _number.duration = 900;
    _unit = [CCCounter text:@"" size:15 weight:NSFontWeightSemibold role:CCRoleMuted];
    _unit.part = CCCounterUnit;
    _unit.duration = 900;
    NSStackView *value = CCHStack(@[ _number, _unit ], 6);
    value.alignment = NSLayoutAttributeLastBaseline;
    _ringCaption = Caption(L(@"overview.selected"));
    _selectedLine = Caption(@"");
    NSStackView *center = CCVStack(@[ value, _ringCaption, _selectedLine ], 0);
    center.alignment = NSLayoutAttributeCenterX;
    [_ring addSubview:center];
    [NSLayoutConstraint activateConstraints:@[
        [center.centerXAnchor constraintEqualToAnchor:_ring.centerXAnchor],
        [center.centerYAnchor constraintEqualToAnchor:_ring.centerYAnchor],
    ]];

    CCLabel *title = H1(@"overview.title");
    title.wraps = YES;
    _status = Muted(@"", 13);
    _status.wraps = YES;
    CCLabel *catalogTitle = Caption(L(@"overview.catalog"));
    catalogTitle.locKey = @"overview.catalog";
    _catalogBytes = [CCCounter text:@"" size:26 weight:NSFontWeightSemibold role:CCRoleText];
    _catalogLine = Muted(@"", 13);
    NSStackView *catalogValue = CCHStack(@[ _catalogBytes, _catalogLine ], 10);
    catalogValue.alignment = NSLayoutAttributeLastBaseline;
    NSStackView *catalog = CCVStack(@[ catalogTitle, catalogValue ], 2);

    // The folder row.
    CCIcon *folderIcon = [CCIcon symbol:@"folder" size:15 weight:NSFontWeightRegular role:CCRoleAccent];
    CCLabel *folderTitle = Caption(L(@"overview.folder"));
    folderTitle.locKey = @"overview.folder";
    _folderPath = [CCLabel text:@"" size:13 weight:NSFontWeightRegular role:CCRoleText];
    _folderPath.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_folderPath setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *folderText = CCVStack(@[ folderTitle, _folderPath ], 1);
    Stretch(folderText, _folderPath);
    CCButton *change = [CCButton buttonWithStyle:CCButtonSubtle title:nil symbol:nil];
    change.locKey = @"overview.change";
    __weak CCOverviewPage *weak = self;
    change.onClick = ^{ [M() chooseDownloadFolder:weak.window completion:nil]; };
    NSStackView *folderLine = CCHStack(@[ folderIcon, folderText, change ], 12);
    [folderText setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    CCBox *folderBox = [[CCBox alloc] initWithFrame:NSZeroRect];
    folderBox.radius = 12;
    folderBox.fill = ^NSColor *{ return CCTheme.inset; };
    [folderBox addSubview:folderLine];
    CCPin(folderLine, folderBox, NSEdgeInsetsMake(8, 14, 8, 8));

    NSStackView *summary = CCVStack(@[ title, _status, catalog, folderBox ], 0);
    [summary setCustomSpacing:6 afterView:title];
    [summary setCustomSpacing:18 afterView:_status];
    [summary setCustomSpacing:18 afterView:catalog];
    for (NSView *v in @[ title, _status, catalog, folderBox ]) Stretch(summary, v);

    _download = [CCButton buttonWithStyle:CCButtonPrimary title:@"" symbol:@"arrow.down.circle"];
    _download.onClick = ^{ [M() download]; };
    NSStackView *actions = CCVStack(@[ _download ], 14);
    actions.alignment = NSLayoutAttributeCenterX;
    Stretch(actions, _download);
    CCSize(actions, 220, 0);

    // The button sits beside the summary when there is room and drops under it in a narrow window (see -arrangeHero).
    _heroRight = CCHStack(@[ summary, actions ], 32);
    _heroRight.alignment = NSLayoutAttributeCenterY;
    _heroSummary = summary;
    [_heroRight setClippingResistancePriority:NSLayoutPriorityWindowSizeStayPut - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *heroRow = CCHStack(@[ _ring, _heroRight ], 36);
    [summary setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_heroRight setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    // Under each other, the summary still takes the whole width (beside the button this cannot hold, and gives way).
    NSLayoutConstraint *summaryFill = [summary.widthAnchor constraintEqualToAnchor:_heroRight.widthAnchor];
    summaryFill.priority = 480;
    summaryFill.active = YES;
    _hero = [CCLayoutCard card];
    [_hero addSubview:heroRow];
    CCPin(heroRow, _hero, NSEdgeInsetsMake(30, 32, 30, 32));
    _hero.onLayout = ^{ [weak arrangeHero]; };

    // ── the note when the API does not answer ──
    CCIcon *offlineIcon = [CCIcon symbol:@"wifi.exclamationmark" size:13 weight:NSFontWeightRegular role:CCRoleWarning];
    CCLabel *offlineText = [CCLabel key:@"catalog.offline" size:12.5 weight:NSFontWeightRegular role:CCRoleWarning];
    NSStackView *offlineLine = CCHStack(@[ offlineIcon, offlineText ], 8);
    _offline = [[CCBox alloc] initWithFrame:NSZeroRect];
    _offline.radius = 10;
    _offline.fill = ^NSColor *{ return CCTheme.warningSoft; };
    [_offline addSubview:offlineLine];
    CCPin(offlineLine, _offline, NSEdgeInsetsMake(7, 12, 7, 12));

    // ── sections ──
    CCLabel *sectionsTitle = H2(@"overview.sections");
    _sectionsHeader = CCHStack(@[ sectionsTitle, CCSpacer(), SelectButtons(^{ [M() selectEverything:YES]; }, ^{ [M() selectEverything:NO]; }) ], 4);
    _segments = [CCSegmentBar new];
    CCSize(_segments, 0, 12);
    _rows = [NSMutableArray array];
    NSArray *ids = CCCatalog.sectionIds;
    for (NSUInteger i = 0; i < ids.count; i++) [_rows addObject:[CCOverviewRow rowForSection:ids[i] index:(NSInteger)i]];
    _list = CCVStack(_rows, 10);
    for (NSView *row in _rows) Stretch(_list, row);
    _updated = Caption(@"");

    // One tick for every real song that never came out.
    _unreleasedCheck = [CCCheck new];
    _unreleasedCheck.onChange = ^(BOOL on) {
        for (NSString *identifier in CCCatalog.unreleasedSectionIds) {
            CCCatalogSection *section = [M().catalog section:identifier];
            if (section) [M() setSection:section selected:on];
        }
    };
    CCLabel *unreleasedName = [CCLabel key:@"overview.allUnreleased" size:14.5 weight:NSFontWeightSemibold role:CCRoleText];
    CCLabel *unreleasedDesc = Muted(@"", 12.5);
    unreleasedDesc.locKey = @"overview.allUnreleased.desc";
    unreleasedDesc.wraps = YES;
    NSStackView *unreleasedText = CCVStack(@[ unreleasedName, unreleasedDesc ], 3);
    Stretch(unreleasedText, unreleasedDesc);
    [unreleasedText setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _unreleasedSize = [CCLabel text:@"" size:16 weight:NSFontWeightSemibold role:CCRoleText];
    _unreleasedCard = Card(CCHStack(@[ _unreleasedCheck, unreleasedText, _unreleasedSize ], 16), NSEdgeInsetsMake(12, 18, 12, 18));

    _page = CCVStack(@[ _offline, _hero, _sectionsHeader, _segments, _unreleasedCard, _list, _updated ], 0);
    [_page setCustomSpacing:14 afterView:_offline];
    [_page setCustomSpacing:30 afterView:_hero];
    [_page setCustomSpacing:12 afterView:_sectionsHeader];
    [_page setCustomSpacing:14 afterView:_segments];
    [_page setCustomSpacing:10 afterView:_unreleasedCard];
    [_page setCustomSpacing:14 afterView:_list];
    for (NSView *v in @[ _hero, _segments, _unreleasedCard, _list ]) Stretch(_page, v);
    [_sectionsHeader.leadingAnchor constraintEqualToAnchor:_page.leadingAnchor constant:4].active = YES;
    [_sectionsHeader.trailingAnchor constraintEqualToAnchor:_page.trailingAnchor constant:-4].active = YES;
    [_updated.leadingAnchor constraintEqualToAnchor:_page.leadingAnchor constant:4].active = YES;

    NSView *doc = _scroll.document;
    [doc addSubview:_page];
    // Never wider than the window allows; as wide as it allows below the window's own size priority, so the page
    // follows the window instead of holding it (hidden pages keep their constraints too).
    [_page.widthAnchor constraintLessThanOrEqualToAnchor:doc.widthAnchor constant:-64].active = YES;
    NSLayoutConstraint *fill = [_page.widthAnchor constraintEqualToAnchor:doc.widthAnchor constant:-64];
    fill.priority = NSLayoutPriorityWindowSizeStayPut - 1;
    [NSLayoutConstraint activateConstraints:@[
        [_page.topAnchor constraintEqualToAnchor:doc.topAnchor constant:6],
        [doc.bottomAnchor constraintEqualToAnchor:_page.bottomAnchor constant:28],
        [_page.centerXAnchor constraintEqualToAnchor:doc.centerXAnchor],
        [_page.widthAnchor constraintLessThanOrEqualToConstant:1320],
        fill,
    ]];
}

- (void)searchChanged:(NSString *)text {
    BOOL searching = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    _results.query = text;
    _results.hidden = !searching;
    _scroll.hidden = searching || M().catalog == nil;
    [NSNotificationCenter.defaultCenter postNotificationName:CCHoverDirtyNotification object:self];
}

- (CCCatalogNode *)hoveredNode { return _results.hidden ? nil : _results.hoveredNode; }

// The ring (204), the summary and the button (220) need about 860 pt side by side; in a narrower window the summary
// would be squeezed until its title breaks mid-word, so the button goes under it.
- (void)arrangeHero {
    CGFloat width = NSWidth(_hero.bounds);
    if (width <= 0) return;
    BOOL fits = width - 64 - 204 - 36 >= 300 + 32 + 220;
    NSUserInterfaceLayoutOrientation orientation = fits ? NSUserInterfaceLayoutOrientationHorizontal : NSUserInterfaceLayoutOrientationVertical;
    if (_heroRight.orientation == orientation) return;
    _heroRight.orientation = orientation;
    _heroRight.alignment = fits ? NSLayoutAttributeCenterY : NSLayoutAttributeLeading;
    [_heroRight setCustomSpacing:fits ? 32 : 22 afterView:_heroSummary];
    _hero.needsLayout = YES;
}

- (void)refresh {
    CCModel *m = M();
    CCCatalog *catalog = m.catalog;
    [_state refresh];
    _search.hidden = catalog == nil;
    BOOL searching = !_results.hidden && catalog != nil;
    _scroll.hidden = catalog == nil || searching;
    if (!catalog) return;
    [_results refresh];
    long long selected = m.selectedBytes;
    int files = m.selectedFiles;
    // With nothing ticked the ring says what is already in the folder.
    long long shown = files > 0 ? selected : m.disk.bytes;
    NSInteger shownFiles = files > 0 ? files : m.disk.files;
    double share = catalog.totalBytes > 0 ? (double)shown / catalog.totalBytes : 0;
    // A sliver stays visible: a tenth of a percent of 400 GB is still a whole album.
    [_ring setAngle:shown > 0 ? MAX(5, share * 360) : 0 animated:YES];
    _number.bytes = shown;
    _unit.bytes = shown;
    _ringCaption.stringValue = L(files > 0 ? @"overview.selected" : @"overview.downloaded");
    _selectedLine.stringValue = LF(@"overview.selectedLine", CCFormatCount(shownFiles));
    _selectedLine.hidden = shownFiles == 0;
    _status.stringValue = L(@"overview.nothingSelected");
    _status.hidden = files > 0;
    _catalogBytes.bytes = catalog.totalBytes;
    _catalogLine.stringValue = LF(@"overview.selectedLine", CCFormatCount(catalog.totalFiles));
    _segments.hidden = files == 0;
    _folderPath.stringValue = m.settings.destination;
    _folderPath.toolTip = m.settings.destination;
    long long missing = files > 0 ? m.missingSelectedBytes : 0;
    _download.title = files == 0 ? L(@"download.none") : missing > 0 ? LF(@"download.buttonSize", CCFormatBytes(missing)) : L(@"download.alreadyThere");
    _download.enabled = missing > 0;
    _download.pulsing = missing > 0;
    _offline.hidden = !m.catalogOffline;

    NSMutableArray *weights = [NSMutableArray array], *colors = [NSMutableArray array];
    for (NSUInteger i = 0; i < catalog.sections.count; i++) {
        [weights addObject:@(catalog.sections[i].selectedBytes)];
        [colors addObject:[CCTheme categoryColor:(NSInteger)i]];
    }
    [_segments setWeights:weights colors:colors];
    for (CCOverviewRow *row in _rows) [row refresh];
    long long unreleasedBytes = 0;
    int unreleasedFiles = 0, unreleasedSelected = 0;
    for (NSString *identifier in CCCatalog.unreleasedSectionIds) {
        CCCatalogSection *section = [catalog section:identifier];
        unreleasedBytes += section.size;
        unreleasedFiles += section.fileCount;
        unreleasedSelected += section.selectedFiles;
    }
    _unreleasedSize.stringValue = CCFormatBytes(unreleasedBytes);
    ApplyCheck(_unreleasedCheck, unreleasedSelected, unreleasedFiles, self.window != nil);
    NSDate *updated = m.library.updatedAt;
    _updated.stringValue = updated ? LF(@"overview.updated", [m relativeDate:updated]) : @"";
    _updated.hidden = !updated;
    if (!_hadCatalog && self.entrancePlayed && !self.hidden) {
        _hadCatalog = YES;
        [self enter];
    }
}

- (void)enter {
    CCEntrance(_search, 0, 18);
    CCEntrance(_hero, 0, 18);
    CCEntrance(_sectionsHeader, 90, 18);
    CCEntrance(_segments, 90, 18);
    Stagger(_rows, 40, 60);
}

- (void)playEntrance {
    [super playEntrance];
    if (M().catalog) {
        _hadCatalog = YES;
        [self enter];
    }
}

@end

// ═════════════════════════════ a section ═════════════════════════════

static NSInteger gCellThemeStamp = 0;

/// The list's rows. Hover without the card's lift, which would be clipped by the row. Whether a row is hovered comes from
/// the window's own reckoning of the pointer (cc_syncHover), so it cannot outlive the pointer through a scroll.
@interface CCLibraryCard : CCCard
@property (nonatomic) BOOL flat;
@property (nonatomic, copy, nullable) void (^onHover)(BOOL hovered);
@property (nonatomic, copy, nullable) void (^onDoubleClick)(void);
@property (nonatomic, copy, nullable) NSMenu *_Nullable (^menuBlock)(void);
@property (nonatomic, readonly) BOOL looksHovered;
@end

@implementation CCLibraryCard
- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    _looksHovered = YES;
    if (self.flat) self.fill = ^NSColor *{ return CCTheme.hover; };
    if (self.onHover) self.onHover(YES);
}
- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    _looksHovered = NO;
    if (self.flat) self.fill = nil;
    if (self.onHover) self.onHover(NO);
}
- (void)mouseUp:(NSEvent *)event {
    [super mouseUp:event];
    if (event.clickCount == 2 && self.onDoubleClick) self.onDoubleClick();
}
- (NSMenu *)menuForEvent:(NSEvent *)event { return self.menuBlock ? self.menuBlock() : [super menuForEvent:event]; }
@end

/// The round play button of a row.
@interface CCRoundPlay : CCBox
@property (nonatomic, strong, readonly) CCIcon *icon;
@property (nonatomic, copy, nullable) void (^onClick)(void);
- (void)setPlaying:(BOOL)playing;
- (void)setPreview;
@end

@implementation CCRoundPlay

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CCSize(self, 28, 28);
        self.radius = 14;
        self.fill = ^NSColor *{ return CCTheme.accentSoft; };
        _icon = [CCIcon symbol:@"play.fill" size:11 weight:NSFontWeightBold role:CCRoleAccent];
        [self addSubview:_icon];
        [NSLayoutConstraint activateConstraints:@[
            [_icon.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityButtonRole;
    }
    return self;
}

- (void)setPlaying:(BOOL)playing {
    NSString *symbol = playing ? @"pause.fill" : @"play.fill";
    if (![_icon.symbol isEqualToString:symbol]) _icon.symbol = symbol;
    self.toolTip = L(playing ? @"player.pause" : @"player.playable");
    self.accessibilityLabel = self.toolTip;
}

- (void)setPreview {
    if (![_icon.symbol isEqualToString:@"eye.fill"]) _icon.symbol = @"eye.fill";
    self.toolTip = L(@"preview.open");
    self.accessibilityLabel = self.toolTip;
}

- (NSView *)hitTest:(NSPoint)point {
    NSPoint p = [self.superview convertPoint:point toView:self];
    return !self.hidden && NSPointInRect(p, self.bounds) ? self : nil;
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds) && self.onClick) self.onClick();
}
- (BOOL)accessibilityPerformPress {
    if (self.onClick) self.onClick();
    return YES;
}

@end

/// Lies over a row's note or photo icon: a click there plays, pauses or previews the file instead of ticking it.
@interface CCMarkHit : NSView
@property (nonatomic, copy, nullable) void (^onClick)(void);
@end

@implementation CCMarkHit
- (NSView *)hitTest:(NSPoint)point {
    NSPoint p = [self.superview convertPoint:point toView:self];
    return !self.hidden && NSPointInRect(p, self.bounds) ? self : nil;
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    // The second click of a double click would undo the first.
    if (event.clickCount == 1 && NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds) && self.onClick) self.onClick();
}
@end

NSMenu *CCRowMenu(CCCatalogNode *node, BOOL searching);

static NSString *SymbolForNode(CCCatalogNode *node) {
    static NSSet *audio, *video, *image, *archive;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        audio = [NSSet setWithArray:@[ @"mp3", @"m4a", @"flac", @"wav", @"aif", @"aiff", @"ogg", @"caf", @"aac", @"wma", @"opus" ]];
        video = [NSSet setWithArray:@[ @"mp4", @"mov", @"m4v", @"mkv", @"avi", @"webm", @"wmv", @"flv" ]];
        image = [NSSet setWithArray:@[ @"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"tif", @"tiff", @"bmp" ]];
        archive = [NSSet setWithArray:@[ @"zip", @"rar", @"7z", @"tar", @"gz" ]];
    });
    if (node.isDirectory) return @"folder";
    NSString *extension = node.name.pathExtension.lowercaseString;
    if ([audio containsObject:extension]) return @"music.note";
    if ([video containsObject:extension]) return @"film";
    if ([image containsObject:extension]) return @"photo";
    if ([archive containsObject:extension]) return @"doc.zipper";
    return @"doc";
}

@class CCLibraryCell;

@protocol CCLibraryCellOwner <NSObject>
- (void)cell:(CCLibraryCell *)cell checked:(BOOL)checked;
- (void)cellToggled:(CCLibraryCell *)cell;
- (nullable NSMenu *)menuForCell:(CCLibraryCell *)cell;
@end

/// One row of a list of the catalog. Top-level rows are cards like the old target cards; what is inside a folder is
/// lighter and flatter, indented 24 pt a level. Built once and reused: only text and state change as the list scrolls.
@interface CCLibraryCell : CCFlippedView
@property (nonatomic, weak) id<CCLibraryCellOwner> owner;
@property (nonatomic, strong, readonly, nullable) CCCatalogNode *node;
- (instancetype)initTop:(BOOL)top;
- (void)configure:(CCLibraryRow *)row color:(NSInteger)colorIndex place:(nullable NSString *)place;
/// A song of By Rules, and one of its takes.
- (void)configureGroup:(CCSongGroup *)group open:(BOOL)open;
- (void)configureVersion:(CCSongVersion *)version picked:(BOOL)picked;
- (void)updateSelection:(BOOL)animated;
- (void)updatePlayState;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)flash;
@property (nonatomic, readonly) BOOL looksHovered;
@end

@implementation CCLibraryCell {
    BOOL _top, _isRule;
    NSInteger _stamp, _colorIndex;
    CCLibraryCard *_card;
    CCCheck *_check;
    CCIconTile *_tile;
    CCIcon *_icon;
    CCLabel *_name, *_line, *_size;
    CCButton *_chevron;
    CCRoundPlay *_play, *_download;
    CCMarkHit *_markHit;
    CCPill *_chip;
    NSLayoutConstraint *_leading, *_markToCheck, *_markToCard;
    CALayer *_flashLayer;
}

- (instancetype)initTop:(BOOL)top {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _top = top;
        _stamp = gCellThemeStamp;
        _card = [CCLibraryCard card];
        _card.flat = !top;
        __weak CCLibraryCell *weak = self;
        _card.onClick = ^{ [weak clicked]; };
        _card.onHover = ^(BOOL hovered) { [weak updatePlayState]; };
        _card.onDoubleClick = ^{
            CCLibraryCell *s = weak;
            if (!s.node || s.node.isDirectory) return;
            if ([CCLibrary isPlayable:s.node.name]) [M() playNode:s.node];
            else if ([CCLibrary previewOf:s.node.name] != CCPreviewNone) [M() previewNode:s.node];
        };
        _card.menuBlock = ^NSMenu *{
            CCLibraryCell *s = weak;
            return [s.owner menuForCell:s];
        };
        if (top) {
            _card.radius = 16;
        } else {
            _card.radius = 10;
            _card.fill = nil;
            _card.stroke = nil;
        }
        [self addSubview:_card];
        _leading = [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:32];
        [NSLayoutConstraint activateConstraints:@[
            _leading,
            [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-26],
            [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:top ? -10 : -2],
        ]];

        _check = [CCCheck new];
        _check.onChange = ^(BOOL on) {
            CCLibraryCell *s = weak;
            [s.owner cell:s checked:on];
        };
        [_card addSubview:_check];

        NSView *mark;
        if (top) {
            _tile = [CCIconTile tileWithSymbol:@"folder" size:38 radius:11 iconSize:16];
            _tile.bounces = YES;
            mark = _tile;
        } else {
            _icon = [CCIcon symbol:@"folder" size:14 weight:NSFontWeightRegular role:CCRoleMuted];
            [_icon.widthAnchor constraintEqualToConstant:20].active = YES;
            mark = _icon;
        }
        [_card addSubview:mark];

        _name = [CCLabel text:@"" size:top ? 14.5 : 13 weight:top ? NSFontWeightSemibold : NSFontWeightRegular role:CCRoleText];
        _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _line = Caption(@"");
        _line.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_line setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *text = CCVStack(@[ _name, _line ], top ? 3 : 1);
        Stretch(text, _name);
        Stretch(text, _line);
        [_card addSubview:text];

        _size = [CCLabel text:@"" size:top ? 15 : 12.5 weight:NSFontWeightSemibold role:CCRoleText];
        _size.font = CCDigitsFont(top ? 15 : 12.5, NSFontWeightSemibold);
        _size.alignment = NSTextAlignmentRight;
        [_size setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

        _play = [CCRoundPlay new];
        _play.hidden = YES;
        _play.onClick = ^{ [weak playOrPreview]; };
        _download = [CCRoundPlay new];
        _download.hidden = YES;
        _download.icon.symbol = @"arrow.down";
        _download.onClick = ^{ [weak downloadFile]; };
        _markHit = [CCMarkHit new];
        _markHit.translatesAutoresizingMaskIntoConstraints = NO;
        _markHit.hidden = YES;
        _markHit.onClick = ^{ [weak playOrPreview]; };
        [_card addSubview:_markHit];
        [NSLayoutConstraint activateConstraints:@[
            [_markHit.leadingAnchor constraintEqualToAnchor:mark.leadingAnchor constant:-4],
            [_markHit.trailingAnchor constraintEqualToAnchor:mark.trailingAnchor constant:4],
            [_markHit.topAnchor constraintEqualToAnchor:_card.topAnchor],
            [_markHit.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],
        ]];
        _chip = [CCPill pillWithText:@"" symbol:nil color:^NSColor *{ return CCTheme.accent; } soft:^NSColor *{ return CCTheme.accentSoft; }];
        [_chip setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        _chip.hidden = YES;
        NSStackView *right = CCHStack(@[ _chip, _play, _download, _size ], 10);
        [_card addSubview:right];

        _chevron = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"chevron.down"];
        _chevron.iconView.wantsLayer = YES;
        _chevron.onClick = ^{
            CCLibraryCell *s = weak;
            [s.owner cellToggled:s];
        };
        [_card addSubview:_chevron];

        CGFloat edge = top ? 18 : 10;
        _markToCheck = [mark.leadingAnchor constraintEqualToAnchor:_check.trailingAnchor constant:top ? 16 : 10];
        _markToCard = [mark.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:edge];
        [NSLayoutConstraint activateConstraints:@[
            [_check.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:edge],
            [_check.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            _markToCheck,
            [mark.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [text.leadingAnchor constraintEqualToAnchor:mark.trailingAnchor constant:top ? 14 : 8],
            [text.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [text.trailingAnchor constraintEqualToAnchor:right.leadingAnchor constant:-16],
            [right.trailingAnchor constraintEqualToAnchor:_chevron.leadingAnchor constant:-8],
            [right.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [_chevron.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:top ? -12 : -4],
            [_chevron.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        ]];
    }
    return self;
}

- (BOOL)looksHovered { return _card.looksHovered; }

- (void)playOrPreview {
    CCCatalogNode *node = self.node;
    CCPlayer *player = M().player;
    if (!node) return;
    if (![CCLibrary isPlayable:node.name]) [M() previewNode:node];
    else if ([player isPlayingNode:node]) [player togglePlay];
    else [M() playNode:node];
}

- (void)downloadFile {
    if (!self.node) return;
    if (self.node.isDirectory) [M() downloadAlbum:self.node];
    else if (_isRule) [M() downloadRuleNode:self.node];
    else [M() downloadNode:self.node];
}

- (void)clicked {
    if (!self.node) return;
    if (_isRule) [self.owner cellToggled:self];
    else if (self.node.isDirectory) [self.owner cellToggled:self];
    else [self.owner cell:self checked:self.node.selectedFiles == 0];
}

/// What a recycled row must forget: nothing on it is hovered until the pointer says so.
- (void)prepareFor:(CCCatalogNode *)node {
    [self cc_syncHover:nil];
    _node = node;
    if (_stamp != gCellThemeStamp) {
        _stamp = gCellThemeStamp;
        [self cc_broadcastTheme];
    }
}

- (void)setMark:(NSString *)symbol color:(NSInteger)colorIndex {
    if (_top) {
        if (![_tile.icon.symbol isEqualToString:symbol]) _tile.icon.symbol = symbol;
        if (_colorIndex != colorIndex || !_tile.fill) {
            _colorIndex = colorIndex;
            _tile.fill = SectionSoft(colorIndex);
            _tile.icon.colorBlock = SectionColor(colorIndex);
        }
    } else if (![_icon.symbol isEqualToString:symbol]) {
        _icon.symbol = symbol;
    }
}

- (void)showCheck:(BOOL)show {
    _check.hidden = !show;
    _markToCheck.active = show;
    _markToCard.active = !show;
}

- (void)configure:(CCLibraryRow *)row color:(NSInteger)colorIndex place:(NSString *)place {
    CCCatalogNode *node = row.node;
    BOOL same = _node == node && !_isRule;
    [self prepareFor:node];
    _isRule = NO;
    [self showCheck:YES];
    _chip.hidden = YES;
    _leading.constant = 32 + 24 * row.depth;
    NSString *length = node.isDirectory ? nil : [M().library.lyrics lengthOf:node.path];
    _name.stringValue = length.length > 0 ? [NSString stringWithFormat:@"%@  ·  %@", node.displayName, length] : node.displayName;
    _name.toolTip = node.name;
    NSString *line = node.isDirectory ? LF(@"library.folderLine", CCFormatCount(node.fileCount)) : @"";
    if (place.length > 0) line = line.length > 0 ? [NSString stringWithFormat:@"%@ · %@", place, line] : place;
    _line.stringValue = line;
    _line.toolTip = line;
    _line.hidden = line.length == 0;
    _size.stringValue = CCFormatBytes(node.size);
    [self setMark:SymbolForNode(node) color:colorIndex];
    _chevron.hidden = !node.isDirectory;
    [self setExpanded:row.expanded animated:NO];
    [self updateSelection:same];
    [self updatePlayState];
}

- (void)configureGroup:(CCSongGroup *)group open:(BOOL)open {
    [self prepareFor:group.picked.file];
    _isRule = YES;
    [self showCheck:NO];
    _leading.constant = 32;
    _name.stringValue = group.title;
    _name.toolTip = group.picked.file.path;
    _line.stringValue = LF(@"rules.picked", group.picked.file.name);
    _line.toolTip = group.picked.why;
    _line.hidden = NO;
    _size.stringValue = CCFormatBytes(group.picked.file.size);
    [self setMark:@"music.note" color:1];
    BOOL several = group.versions.count > 1;
    _chip.hidden = !several;
    if (several) _chip.label.stringValue = LF(@"rules.versions", @(group.versions.count));
    _chevron.hidden = !several;
    [self setExpanded:open animated:NO];
    [self updatePlayState];
}

- (void)configureVersion:(CCSongVersion *)version picked:(BOOL)picked {
    [self prepareFor:version.file];
    _isRule = YES;
    [self showCheck:YES];
    _chip.hidden = YES;
    _leading.constant = 56;
    _check.toolTip = L(@"rules.useVersion");
    if (_check.checked != picked || _check.mixed) [_check setChecked:picked mixed:NO animated:NO];
    _check.enabled = YES;
    _name.stringValue = version.file.name;
    _name.toolTip = [CCCatalogRelations place:version.file];
    _line.stringValue = version.why;
    _line.hidden = version.why.length == 0;
    _size.stringValue = CCFormatBytes(version.file.size);
    [self setMark:SymbolForNode(version.file) color:1];
    _chevron.hidden = YES;
    [self updatePlayState];
}

- (void)updateSelection:(BOOL)animated {
    CCCatalogNode *node = self.node;
    if (node && !_isRule) ApplyCheck(_check, node.selectedFiles, node.fileCount, animated && self.window != nil);
}

- (void)updatePlayState {
    CCCatalogNode *node = self.node;
    CCPlayer *player = M().player;
    BOOL current = node && [player isPlayingNode:node];
    BOOL playable = node && !node.isDirectory && [CCLibrary isPlayable:node.name];
    BOOL previewable = node && !node.isDirectory && !playable && [CCLibrary previewOf:node.name] != CCPreviewNone;
    _play.hidden = !(playable || previewable) || !(current || _card.looksHovered);
    if (previewable) [_play setPreview];
    else [_play setPlaying:current && player.playing];
    _markHit.hidden = !(playable || previewable);
    _markHit.toolTip = _play.toolTip;
    BOOL have = node && !node.isDirectory && [M().disk has:node.path];
    if (node && !node.isDirectory) _size.stringValue = have ? [@"✓ " stringByAppendingString:CCFormatBytes(node.size)] : CCFormatBytes(node.size);
    _size.toolTip = have ? L(@"download.alreadyThere") : nil;
    _download.hidden = !node || have || !(current || _card.looksHovered);
    _download.toolTip = L(node.isDirectory ? @"menu.row.downloadAlbum" : @"library.downloadOne");
    _download.accessibilityLabel = _download.toolTip;
    _name.role = current ? CCRoleAccent : CCRoleText;
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    CCTransformView(_chevron.iconView, CCXformMake(1, 0, expanded ? 180 : 0), animated ? 300 : 0, CCEaseCubicOut);
}

- (void)flash {
    if (!_flashLayer) {
        _flashLayer = [CALayer layer];
        _flashLayer.opacity = 0;
        [_card.layer insertSublayer:_flashLayer atIndex:0];
    }
    CCWithoutAnimation(^{
        self->_flashLayer.frame = self->_card.layer.bounds;
        self->_flashLayer.cornerRadius = self->_card.layer.cornerRadius;
        self->_flashLayer.backgroundColor = CCTheme.accent.CGColor;
        self->_flashLayer.opacity = 0.45;
    });
    CCAnimateNumber(_flashLayer, @"opacity", 0, CCMotionEnabled() ? 1400 : 0, CCEaseIn, 0);
}

@end

/// A table that takes no first-responder ring and no selection.
@interface CCPlainTable : NSTableView
@end

@implementation CCPlainTable
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)validateProposedFirstResponder:(NSResponder *)responder forEvent:(NSEvent *)event { return YES; }
@end

static CCPlainTable *MakeTable(id<NSTableViewDataSource, NSTableViewDelegate> owner) {
    CCPlainTable *table = [[CCPlainTable alloc] initWithFrame:NSZeroRect];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"row"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [table addTableColumn:column];
    table.headerView = nil;
    table.style = NSTableViewStylePlain;
    table.backgroundColor = NSColor.clearColor;
    table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    table.intercellSpacing = NSZeroSize;
    table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    table.focusRingType = NSFocusRingTypeNone;
    table.allowsColumnResizing = NO;
    table.allowsColumnReordering = NO;
    table.usesAutomaticRowHeights = NO;
    table.dataSource = owner;
    table.delegate = owner;
    return table;
}

static NSScrollView *MakeTableScroll(NSTableView *table) {
    NSScrollView *scroll = [NSScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.borderType = NSNoBorder;
    scroll.contentView.drawsBackground = NO;
    scroll.automaticallyAdjustsContentInsets = NO;
    scroll.documentView = table;
    scroll.contentView.postsBoundsChangedNotifications = YES;
    return scroll;
}

@interface CCSectionPage () <CCLibraryCellOwner>
@end

@implementation CCSectionPage {
    NSString *_sectionId;
    NSInteger _index;
    NSView *_header;
    CCLabel *_subtitle, *_noResults;
    CCSearchField *_search;
    CCCatalogState *_state;
    CCPlainTable *_table;
    NSScrollView *_scroll;
    NSArray<CCLibraryRow *> *_rows;
    BOOL _built, _stale;
}

- (instancetype)initWithSection:(NSString *)identifier index:(NSInteger)index {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _sectionId = [identifier copy];
        _index = index;
        _rows = @[];
        [self build];
    }
    return self;
}

- (void)build {
    _subtitle = Muted(@"", 13);
    NSStackView *titles = CCVStack(@[ H1([@"nav." stringByAppendingString:_sectionId]), _subtitle ], 4);
    _search = [CCSearchField new];
    _search.placeholderKey = @"library.search";
    __weak CCSectionPage *weak = self;
    _search.onChange = ^(NSString *text) { [weak searchChanged:text]; };
    [_search.widthAnchor constraintEqualToConstant:320].active = YES;
    NSStackView *top = CCHStack(@[ titles, CCSpacer(), _search ], 12);

    CCLabel *desc = Muted(@"", 13);
    desc.locKey = [NSString stringWithFormat:@"section.%@.desc", _sectionId];
    [desc setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *select = SelectButtons(^{ [weak selectVisible:YES]; }, ^{ [weak selectVisible:NO]; });
    NSStackView *second = CCHStack(@[ desc, CCSpacer(), select ], 12);
    [second setClippingResistancePriority:NSLayoutPriorityWindowSizeStayPut - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *header = CCVStack(@[ top, second ], 14);
    Stretch(header, top);
    Stretch(header, second);
    _header = header;
    [self addSubview:header];

    _table = MakeTable(self);
    _scroll = MakeTableScroll(_table);
    _scroll.contentInsets = NSEdgeInsetsMake(2, 0, 28, 0);
    [self addSubview:_scroll];

    _noResults = Muted(L(@"library.noResults"), 13);
    _noResults.locKey = @"library.noResults";
    _noResults.hidden = YES;
    [self addSubview:_noResults];

    _state = [CCCatalogState new];
    [self addSubview:_state];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:32],
        [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-32],
        [_scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_noResults.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:24],
        [_noResults.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:36],
        [_state.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_state.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_state.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_state.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
}

- (CCLibraryRows *)rowsModel { return [M() rowsForSection:_sectionId]; }

- (void)rebuildRows {
    CCLibraryRows *model = self.rowsModel;
    if (!model) return;
    model.query = _search.text;
    _rows = model.rows;
    _built = YES;
    _stale = NO;
    [_table reloadData];
    _noResults.hidden = _rows.count > 0 || _search.text.length == 0;
}

- (void)reveal:(CCCatalogNode *)node {
    _search.text = @"";
    [self.rowsModel reveal:node];
    [self rebuildRows];
    for (NSUInteger i = 0; i < _rows.count; i++) {
        if (![_rows[i].node.path isEqualToString:node.path]) continue;
        [_table scrollRowToVisible:(NSInteger)i];
        [_table layoutSubtreeIfNeeded];
        CCLibraryCell *cell = [_table viewAtColumn:0 row:(NSInteger)i makeIfNecessary:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ [cell flash]; });
        return;
    }
}

- (void)searchFor:(NSString *)text {
    _search.text = text;
    [self rebuildRows];
}

- (CCCatalogNode *)hoveredNode {
    __block CCCatalogNode *node = nil;
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        CCLibraryCell *cell = [rowView viewAtColumn:0];
        if ([cell isKindOfClass:CCLibraryCell.class] && cell.looksHovered) node = cell.node;
    }];
    return node;
}

- (void)setNeedsRebuild { _stale = YES; }

- (void)rebuildIfNeeded {
    if (_stale) [self rebuildRows];
}

- (void)searchChanged:(NSString *)text { [self rebuildRows]; }

- (NSMenu *)menuForCell:(CCLibraryCell *)cell {
    return cell.node ? CCRowMenu(cell.node, _search.text.length > 0) : nil;
}

- (void)tableView:(NSTableView *)tableView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
    [NSNotificationCenter.defaultCenter postNotificationName:CCHoverDirtyNotification object:self];
}

- (void)selectVisible:(BOOL)selected {
    CCCatalogSection *section = [M().catalog section:_sectionId];
    if (!section) return;
    if (_search.text.length == 0) {
        [M() setSection:section selected:selected];
        return;
    }
    // With a search on, All and None mean what the search shows.
    NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:_rows.count];
    for (CCLibraryRow *row in _rows)
        if (row.depth == 0) [nodes addObject:row.node];
    [M() setNodes:nodes selected:selected];
}

- (void)applyTheme { gCellThemeStamp++; }

- (void)applyLanguage {
    [super applyLanguage];
    if (_built) [_table reloadData];
}

- (void)refresh {
    CCModel *m = M();
    CCCatalogSection *section = [m.catalog section:_sectionId];
    [_state refresh];
    _scroll.hidden = section == nil;
    if (!section) {
        _subtitle.stringValue = L(m.catalogLoading ? @"catalog.loading" : @"catalog.failed");
        return;
    }
    if (!_built) [self rebuildRows];
    NSString *subtitle = LF(@"library.subtitle", CCFormatCount(section.fileCount), CCFormatBytes(section.size), CCFormatBytes(section.selectedBytes));
    NSInteger have = [m.disk filesInSection:section.identifier];
    _subtitle.stringValue = have > 0 ? [NSString stringWithFormat:@"%@ · %@", subtitle, LF(@"library.have", CCFormatCount(have))] : subtitle;
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        CCLibraryCell *cell = [rowView viewAtColumn:0];
        if ([cell isKindOfClass:CCLibraryCell.class]) {
            [cell updateSelection:YES];
            [cell updatePlayState];
        }
    }];
}

- (void)playEntrance {
    [super playEntrance];
    CCEntrance(_header, 0, 18);
    NSMutableArray *cells = [NSMutableArray array];
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        NSView *cell = [rowView viewAtColumn:0];
        if (cell) [cells addObject:cell];
    }];
    Stagger(cells, 28, 0);
}

- (void)expandFirstForCapture {
    CCLibraryRow *first = _rows.firstObject;
    if (!first || !first.node.isDirectory || first.expanded) return;
    [self.rowsModel toggle:first.node];
    [self rebuildRows];
}

// ── table ──

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_rows.count; }

static BOOL IsTopRow(CCLibraryRow *row) { return row.depth == 0; }

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    CCLibraryRow *r = _rows[(NSUInteger)row];
    if (IsTopRow(r)) return r.node.isDirectory ? 76 : 66;
    return r.node.isDirectory ? 50 : 38;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row { return NO; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    CCLibraryRow *r = _rows[(NSUInteger)row];
    BOOL top = IsTopRow(r);
    NSString *identifier = top ? @"top" : @"nested";
    CCLibraryCell *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[CCLibraryCell alloc] initTop:top];
        cell.identifier = identifier;
        cell.owner = self;
    }
    NSString *place = _search.text.length > 0 && r.depth == 0 ? [CCCatalogRelations place:r.node] : nil;
    [cell configure:r color:_index place:place];
    return cell;
}

- (void)cell:(CCLibraryCell *)cell checked:(BOOL)checked {
    if (cell.node) [M() setNode:cell.node selected:checked];
}

- (void)cellToggled:(CCLibraryCell *)cell {
    NSInteger row = [_table rowForView:cell];
    CCLibraryRows *model = self.rowsModel;
    if (row < 0 || !cell.node || ![model toggle:cell.node]) return;
    NSArray<CCLibraryRow *> *fresh = model.rows;
    NSInteger delta = (NSInteger)fresh.count - (NSInteger)_rows.count;
    BOOL opening = delta > 0;
    _rows = fresh;
    if (ABS(delta) > 300 || !CCMotionEnabled()) {
        [_table reloadData];
        return;
    }
    if (delta != 0) {
        NSIndexSet *changed = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange((NSUInteger)row + 1, (NSUInteger)ABS(delta))];
        [_table beginUpdates];
        if (opening) [_table insertRowsAtIndexes:changed withAnimation:NSTableViewAnimationEffectFade | NSTableViewAnimationSlideDown];
        else [_table removeRowsAtIndexes:changed withAnimation:NSTableViewAnimationEffectFade | NSTableViewAnimationSlideUp];
        [_table endUpdates];
    }
    [cell setExpanded:fresh[(NSUInteger)row].expanded animated:YES];
}

@end

// ═════════════════════════════ the Overview's search ═════════════════════════════

@interface CCCatalogSearch () <NSTableViewDataSource, NSTableViewDelegate, CCLibraryCellOwner>
@end

@implementation CCCatalogSearch {
    CCCatalog *_catalog;
    CCLibraryRows *_model;
    NSArray<CCLibraryRow *> *_rows;
    CCLabel *_count, *_none;
    NSStackView *_header;
    CCPlainTable *_table;
    NSScrollView *_scroll;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _query = @"";
        _rows = @[];
        __weak CCCatalogSearch *weak = self;
        _count = Muted(@"", 13);
        _header = CCHStack(@[ _count, CCSpacer(), SelectButtons(^{ [weak selectResults:YES]; }, ^{ [weak selectResults:NO]; }) ], 12);
        [self addSubview:_header];
        _table = MakeTable(self);
        _scroll = MakeTableScroll(_table);
        _scroll.contentInsets = NSEdgeInsetsMake(2, 0, 28, 0);
        [self addSubview:_scroll];
        _none = Muted(L(@"library.noResults"), 13);
        _none.locKey = @"library.noResults";
        _none.hidden = YES;
        [self addSubview:_none];
        [NSLayoutConstraint activateConstraints:@[
            [_header.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:36],
            [_header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-36],
            [_scroll.topAnchor constraintEqualToAnchor:_header.bottomAnchor constant:10],
            [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_none.topAnchor constraintEqualToAnchor:_header.bottomAnchor constant:18],
            [_none.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:36],
        ]];
    }
    return self;
}

- (void)setQuery:(NSString *)query {
    _query = [query copy];
    [self rebuild];
    [_table scrollRowToVisible:0];
}

- (void)rebuild {
    CCCatalog *catalog = M().catalog;
    if (catalog != _catalog || !_model) {
        _catalog = catalog;
        _model = catalog ? [[CCLibraryRows alloc] initWithSection:catalog.everything] : nil;
    }
    _model.query = _query;
    _rows = _query.length > 0 && _model ? _model.rows : @[];
    [_table reloadData];
    NSInteger found = 0;
    for (CCLibraryRow *row in _rows) if (row.depth == 0) found++;
    _count.stringValue = LF(@"overview.search.results", CCFormatCount(found));
    _none.hidden = found > 0;
    _header.hidden = found == 0;
}

- (void)selectResults:(BOOL)selected {
    NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:_rows.count];
    for (CCLibraryRow *row in _rows)
        if (row.depth == 0) [nodes addObject:row.node];
    [M() setNodes:nodes selected:selected];
}

- (void)refresh {
    if (self.hidden) return;
    if (M().catalog != _catalog) {
        [self rebuild];
        return;
    }
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        CCLibraryCell *cell = [rowView viewAtColumn:0];
        if ([cell isKindOfClass:CCLibraryCell.class]) {
            [cell updateSelection:YES];
            [cell updatePlayState];
        }
    }];
}

- (CCCatalogNode *)hoveredNode {
    __block CCCatalogNode *node = nil;
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        CCLibraryCell *cell = [rowView viewAtColumn:0];
        if ([cell isKindOfClass:CCLibraryCell.class] && cell.looksHovered) node = cell.node;
    }];
    return node;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_rows.count; }

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    CCLibraryRow *r = _rows[(NSUInteger)row];
    if (IsTopRow(r)) return r.node.isDirectory ? 76 : 66;
    return r.node.isDirectory ? 50 : 38;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row { return NO; }

- (void)tableView:(NSTableView *)tableView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
    [NSNotificationCenter.defaultCenter postNotificationName:CCHoverDirtyNotification object:self];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    CCLibraryRow *r = _rows[(NSUInteger)row];
    BOOL top = IsTopRow(r);
    NSString *identifier = top ? @"top" : @"nested";
    CCLibraryCell *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[CCLibraryCell alloc] initTop:top];
        cell.identifier = identifier;
        cell.owner = self;
    }
    NSString *section = [M() sectionOf:r.node];
    NSUInteger index = section ? [CCCatalog.sectionIds indexOfObject:section] : 0;
    [cell configure:r color:index == NSNotFound ? 0 : (NSInteger)index place:top ? [CCCatalogRelations place:r.node] : nil];
    return cell;
}

- (void)cell:(CCLibraryCell *)cell checked:(BOOL)checked {
    if (cell.node) [M() setNode:cell.node selected:checked];
}

- (void)cellToggled:(CCLibraryCell *)cell {
    if (cell.node && [_model toggle:cell.node]) {
        _rows = _model.rows;
        [_table reloadData];
    }
}

- (NSMenu *)menuForCell:(CCLibraryCell *)cell {
    return cell.node ? CCRowMenu(cell.node, YES) : nil;
}

@end

// ═════════════════════════════ a row's menu ═════════════════════════════

/// A menu item that runs a block.
@interface CCBlockItem : NSMenuItem
@property (nonatomic, copy) void (^block)(void);
+ (instancetype)title:(NSString *)title block:(void (^)(void))block;
@end

@implementation CCBlockItem
+ (instancetype)title:(NSString *)title block:(void (^)(void))block {
    CCBlockItem *item = [[self alloc] initWithTitle:title action:@selector(run:) keyEquivalent:@""];
    item.target = item;
    item.block = block;
    return item;
}
- (void)run:(id)sender { self.block(); }
@end

static void CopyText(NSString *text) {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

/// The right-click menu of any row: the same on section pages and By Rules.
NSMenu *CCRowMenu(CCCatalogNode *node, BOOL searching) {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    CCModel *m = M();
    if (!node.isDirectory && [CCLibrary previewOf:node.name] != CCPreviewNone)
        [menu addItem:[CCBlockItem title:L(@"preview.open") block:^{ [M() previewNode:node]; }]];
    if (!node.isDirectory && [CCLibrary isPlayable:node.name])
        [menu addItem:[CCBlockItem title:L(@"menu.row.play") block:^{ [M() playNode:node]; }]];
    BOOL all = node.fileCount > 0 && node.selectedFiles >= node.fileCount;
    [menu addItem:[CCBlockItem title:L(all ? @"menu.row.deselect" : @"menu.row.select") block:^{ [M() setNode:node selected:!all]; }]];
    if (node.isDirectory && node.fileCount > 0)
        [menu addItem:[CCBlockItem title:L(@"menu.row.downloadAlbum") block:^{ [M() downloadAlbum:node]; }]];
    if (!node.isDirectory || searching)
        [menu addItem:[CCBlockItem title:L(@"menu.row.reveal") block:^{ [M() revealNode:node]; }]];
    if (!node.isDirectory) {
        NSMenuItem *also = [[NSMenuItem alloc] initWithTitle:L(@"menu.row.alsoIn") action:nil keyEquivalent:@""];
        NSMenu *sub = [NSMenu new];
        sub.autoenablesItems = NO;
        NSArray<CCCatalogNode *> *others = [m.relations of:node] ?: @[];
        NSUInteger count = 0;
        for (CCCatalogNode *other in others) {
            if (++count > 15) break;
            NSString *section = [m sectionOf:other];
            NSString *title = section ? [NSString stringWithFormat:@"%@ · %@", L([@"nav." stringByAppendingString:section]), [CCCatalogRelations place:other]] : [CCCatalogRelations place:other];
            [sub addItem:[CCBlockItem title:title block:^{ [M() revealNode:other]; }]];
        }
        if (sub.numberOfItems == 0) {
            NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:L(@"menu.row.alsoInNone") action:nil keyEquivalent:@""];
            none.enabled = NO;
            [sub addItem:none];
        }
        also.submenu = sub;
        [menu addItem:also];
        [menu addItem:[CCBlockItem title:L(@"menu.row.versions") block:^{ [M() findVersionsOf:node]; }]];
        [menu addItem:[CCBlockItem title:L(@"menu.row.lyrics") block:^{ [M() showLyricsOf:node]; }]];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[CCBlockItem title:L(@"menu.row.copyPath") block:^{ CopyText(node.path); }]];
    if (!node.isDirectory) {
        [menu addItem:[CCBlockItem title:L(@"menu.row.copyLink") block:^{ CopyText([CCApiClient downloadURL:node.path].absoluteString); }]];
        NSString *local = [CCLibrary localCopy:node under:m.settings.destination];
        if (local)
            [menu addItem:[CCBlockItem title:L(@"menu.row.showFile") block:^{
                [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:local] ]];
            }]];
    }
    return menu;
}

// ═════════════════════════════ a short list of lines ═════════════════════════════

/// What failed, what was not found: possibly thousands of lines, so a table and not a stack.
@interface CCLineList : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong, readonly) NSScrollView *view;
@property (nonatomic, copy) NSArray<NSString *> *lines;
@end

@implementation CCLineList {
    CCPlainTable *_table;
    NSLayoutConstraint *_height;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lines = @[];
        _table = MakeTable(self);
        _table.rowHeight = 24;
        _view = MakeTableScroll(_table);
        // Below required, so on a short window the list gives way before the card outgrows it.
        _height = [_view.heightAnchor constraintEqualToConstant:0];
        _height.priority = NSLayoutPriorityDefaultHigh - 1;
        _height.active = YES;
    }
    return self;
}

- (void)setLines:(NSArray<NSString *> *)lines {
    _lines = [lines copy];
    _height.constant = MIN(168, lines.count * 24.0);
    [_table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_lines.count; }
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row { return NO; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    CCLabel *label = [tableView makeViewWithIdentifier:@"line" owner:self];
    if (!label) {
        label = [CCLabel text:@"" size:12.5 weight:NSFontWeightRegular role:CCRoleMuted];
        label.identifier = @"line";
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    label.translatesAutoresizingMaskIntoConstraints = YES;
    [label applyTheme];
    label.stringValue = _lines[(NSUInteger)row];
    label.toolTip = _lines[(NSUInteger)row];
    return label;
}

@end

// ═════════════════════════════ lyrics ═════════════════════════════

@implementation CCLyricsPage {
    NSArray<NSView *> *_sections;
    CCToggle *_enable, *_embed, *_sidecar, *_timed;
    CCSettingRow *_status;
    CCButton *_update, *_mine, *_choose, *_stop;
    NSStackView *_running;
    CCLabel *_runningText, *_summary, *_missingTitle;
    CCSmoothBar *_folderBar;
    CCLineList *_missing;
    CCLyricsRunReport *_shownReport;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) [self build];
    return self;
}

- (void)build {
    CCScrollPage *scroll = [CCScrollPage new];
    [self addSubview:scroll];
    CCPin(scroll, self, NSEdgeInsetsMake(0, 0, 0, 0));
    __weak CCLyricsPage *weak = self;

    _enable = [CCToggle new];
    _enable.onChange = ^(BOOL on) { [M() setLyricsEnabled:on]; };
    _embed = [CCToggle new];
    _embed.onChange = ^(BOOL on) {
        M().settings.lyricsEmbed = on;
        [M() saveSettings];
    };
    _sidecar = [CCToggle new];
    _sidecar.onChange = ^(BOOL on) {
        M().settings.lyricsSidecar = on;
        [M() saveSettings];
    };
    _timed = [CCToggle new];
    _timed.onChange = ^(BOOL on) {
        M().settings.lyricsTimedInTag = on;
        [M() saveSettings];
    };
    _update = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:@"arrow.clockwise"];
    _update.locKey = @"lyrics.update";
    _update.padding = NSEdgeInsetsMake(8, 12, 8, 12);
    _update.fontSize = 12.5;
    _update.onClick = ^{ [M() updateLyrics]; };
    _status = [CCSettingRow rowWithSymbol:@"music.mic" titleKey:nil descKey:nil control:_update];
    // This row's text is short: it takes the room, or the button would.
    [_status.titleLabel setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_status.descLabel setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _status.showsDivider = NO;
    NSArray *rows = @[
        [CCSettingRow rowWithSymbol:@"text.quote" titleKey:@"lyrics.enable" descKey:@"lyrics.enable.desc" control:_enable],
        [CCSettingRow rowWithSymbol:@"tag" titleKey:@"lyrics.embed" descKey:@"lyrics.embed.desc" control:_embed],
        [CCSettingRow rowWithSymbol:@"doc.text" titleKey:@"lyrics.sidecar" descKey:@"lyrics.sidecar.desc" control:_sidecar],
        [CCSettingRow rowWithSymbol:@"timer" titleKey:@"lyrics.timed" descKey:@"lyrics.timed.desc" control:_timed],
        _status,
    ];
    NSStackView *rowStack = CCVStack(rows, 0);
    for (NSView *row in rows) Stretch(rowStack, row);
    CCCard *addOn = Card(rowStack, NSEdgeInsetsMake(10, 24, 10, 24));

    // ── a folder you already have ──
    CCLabel *folderTitle = H2(@"lyrics.folder");
    CCLabel *folderDesc = [CCLabel key:@"lyrics.folder.desc" size:12.5 weight:NSFontWeightRegular role:CCRoleMuted];
    folderDesc.wraps = YES;
    NSStackView *folderText = CCVStack(@[ folderTitle, folderDesc ], 4);
    Stretch(folderText, folderDesc);
    _choose = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:@"folder"];
    _choose.locKey = @"lyrics.folder.choose";
    _choose.onClick = ^{ [weak chooseFolder]; };
    _mine = [CCButton buttonWithStyle:CCButtonPrimary title:nil symbol:@"text.badge.plus"];
    _mine.locKey = @"lyrics.folder.mine";
    _mine.onClick = ^{ [M() addLyricsToFolder:M().settings.destination]; };
    NSStackView *folderHeader = CCHStack(@[ folderText, _mine, _choose ], 12);
    folderHeader.alignment = NSLayoutAttributeTop;
    [folderText setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    _runningText = Muted(@"", 12.5);
    _runningText.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_runningText setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _stop = [CCButton buttonWithStyle:CCButtonSubtle title:nil symbol:@"stop"];
    _stop.locKey = @"download.stop";
    _stop.onClick = ^{ [M() stopFolder]; };
    NSStackView *runningLine = CCHStack(@[ _runningText, _stop ], 12);
    [_runningText setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _folderBar = [CCSmoothBar new];
    _folderBar.duration = 200;
    _folderBar.fillGradient = ^NSArray<NSColor *> *{ return CCTheme.accentGradient; };
    CCSize(_folderBar, 0, 6);
    _running = CCVStack(@[ runningLine, _folderBar ], 8);
    Stretch(_running, runningLine);
    Stretch(_running, _folderBar);

    _summary = [CCLabel text:@"" size:13 weight:NSFontWeightSemibold role:CCRoleText];
    _summary.wraps = YES;
    _missingTitle = [CCLabel key:@"lyrics.folder.missing" size:11.5 weight:NSFontWeightSemibold role:CCRoleFaint];
    _missing = [CCLineList new];
    NSStackView *folderBody = CCVStack(@[ folderHeader, _running, _summary, _missingTitle, _missing.view ], 14);
    [folderBody setCustomSpacing:6 afterView:_missingTitle];
    for (NSView *v in @[ folderHeader, _running, _summary, _missing.view ]) Stretch(folderBody, v);
    CCCard *folderCard = Card(folderBody, NSEdgeInsetsMake(18, 24, 20, 24));

    CCLabel *subtitle = [CCLabel key:@"lyrics.subtitle" size:13 weight:NSFontWeightRegular role:CCRoleMuted];
    subtitle.wraps = YES;
    NSStackView *titles = CCVStack(@[ H1(@"lyrics.title"), subtitle ], 4);
    Stretch(titles, subtitle);
    _sections = @[ titles, addOn, folderCard ];
    NSStackView *page = CCVStack(_sections, 16);
    [page setCustomSpacing:20 afterView:titles];
    for (NSView *v in _sections) Stretch(page, v);
    NSView *doc = scroll.document;
    [doc addSubview:page];
    [page.trailingAnchor constraintLessThanOrEqualToAnchor:doc.trailingAnchor constant:-32].active = YES;
    NSLayoutConstraint *fill = [page.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor constant:-32];
    fill.priority = NSLayoutPriorityWindowSizeStayPut - 1;
    [NSLayoutConstraint activateConstraints:@[
        [page.topAnchor constraintEqualToAnchor:doc.topAnchor constant:6],
        [page.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor constant:32],
        [page.widthAnchor constraintLessThanOrEqualToConstant:960],
        [doc.bottomAnchor constraintEqualToAnchor:page.bottomAnchor constant:28],
        fill,
    ]];
}

- (void)chooseFolder {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) [M() addLyricsToFolder:panel.URL.path];
    }];
}

- (void)refresh {
    CCModel *m = M();
    CCSettings *s = m.settings;
    BOOL animated = self.window != nil;
    if (_enable.on != s.lyricsEnabled) [_enable setOn:s.lyricsEnabled animated:animated];
    if (_embed.on != s.lyricsEmbed) [_embed setOn:s.lyricsEmbed animated:animated];
    if (_sidecar.on != s.lyricsSidecar) [_sidecar setOn:s.lyricsSidecar animated:animated];
    if (_timed.on != s.lyricsTimedInTag) [_timed setOn:s.lyricsTimedInTag animated:animated];
    _embed.enabled = s.lyricsEnabled;
    _sidecar.enabled = s.lyricsEnabled;
    _timed.enabled = s.lyricsEnabled;

    CCLyricsIndex *index = m.library.lyrics;
    NSDate *updated = m.library.cache.songsTime;
    _status.titleLabel.stringValue = index ? LF(@"lyrics.stats", CCFormatCount(index.songCount), CCFormatCount(index.withLyrics)) : L(@"lyrics.notLoaded");
    if (m.lyricsLoading) _status.descLabel.stringValue = LF(@"lyrics.loading", CCFormatCount(m.lyricsDone), CCFormatCount(m.lyricsTotal));
    else if (m.lyricsError) _status.descLabel.stringValue = LF(@"lyrics.failed", m.lyricsError);
    else _status.descLabel.stringValue = updated ? LF(@"lyrics.updated", [m relativeDate:updated]) : @"";
    _status.descLabel.role = !m.lyricsLoading && m.lyricsError ? CCRoleWarning : CCRoleMuted;
    _status.descLabel.hidden = _status.descLabel.stringValue.length == 0;
    _update.enabled = !m.lyricsLoading;

    BOOL running = m.folderRunning;
    _choose.enabled = !running;
    _mine.enabled = !running;
    _running.hidden = !running;
    _runningText.stringValue = running && m.folderTotal == 0 && m.lyricsLoading
        ? LF(@"lyrics.loading", CCFormatCount(m.lyricsDone), CCFormatCount(m.lyricsTotal))
        : LF(@"lyrics.folder.running", CCFormatCount(m.folderDone), CCFormatCount(m.folderTotal), m.folderCurrent);
    _folderBar.value = m.folderTotal > 0 ? (double)m.folderDone / m.folderTotal : 0;
    CCLyricsRunReport *r = m.folderReport;
    _summary.hidden = !r;
    if (r) _summary.stringValue = LF(@"lyrics.folder.summary", CCFormatCount(r.written), CCFormatCount(r.alreadyThere), CCFormatCount(r.notFound), CCFormatCount(r.failed));
    BOOL anyMissing = r.missing.count > 0;
    _missingTitle.hidden = !anyMissing;
    _missing.view.hidden = !anyMissing;
    if (r != _shownReport) {
        _shownReport = r;
        _missing.lines = r.missing ?: @[];
    }
}

- (void)playEntrance {
    [super playEntrance];
    for (NSUInteger i = 0; i < _sections.count; i++) CCEntrance(_sections[i], 60.0 * i, 18);
}

@end

// ═════════════════════════════ by rules ═════════════════════════════

typedef NS_ENUM(NSInteger, CCRuleRowKind) { CCRuleRowConfig, CCRuleRowGroup, CCRuleRowVersion };

@interface CCRuleRow : NSObject
@property (nonatomic) CCRuleRowKind kind;
@property (nonatomic, strong) CCSongGroup *group;
@property (nonatomic, strong) CCSongVersion *version;
@end
@implementation CCRuleRow
@end

@interface CCRulesPage () <NSTableViewDataSource, NSTableViewDelegate, CCLibraryCellOwner>
@end

/// A scrolling list that opens under a view while the pointer is on it, and stays while the pointer moves into it.
@interface CCHoverList : NSObject
- (instancetype)initWithAnchor:(NSView *)anchor;
- (void)setTitle:(nullable NSString *)title text:(nullable NSString *)text;
- (void)close;
@end

@implementation CCHoverList {
    __weak NSView *_anchor;
    NSString *_title, *_text;
    NSPopover *_popover;
    NSTimer *_watch;
    NSInteger _away;
}

- (instancetype)initWithAnchor:(NSView *)anchor {
    if ((self = [super init])) {
        _anchor = anchor;
        [anchor addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
    }
    return self;
}

- (void)setTitle:(NSString *)title text:(NSString *)text {
    if ([_title isEqualToString:title] && [_text isEqualToString:text]) return;
    _title = [title copy];
    _text = [text copy];
    if (!_popover) return;
    [self close];
    [self open];
}

- (void)mouseEntered:(NSEvent *)event { [self open]; }
- (void)mouseExited:(NSEvent *)event {}

- (void)open {
    NSView *anchor = _anchor;
    if (_popover || _text.length == 0 || !anchor.window) return;

    const CGFloat width = 360, inset = 14, maxList = 340;
    NSTextField *title = [NSTextField labelWithString:_title ?: @""];
    title.font = CCFont(13, NSFontWeightSemibold);
    title.textColor = CCTheme.text;
    title.frame = NSMakeRect(inset, 0, width - inset * 2, 18);

    NSMutableParagraphStyle *lines = [NSMutableParagraphStyle new];
    lines.paragraphSpacing = 5;
    NSTextView *list = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, width - inset * 2, 10)];
    list.editable = NO;
    list.selectable = YES;
    list.drawsBackground = NO;
    list.textContainerInset = NSZeroSize;
    list.textContainer.lineFragmentPadding = 0;
    list.verticallyResizable = YES;
    list.textContainer.widthTracksTextView = YES;
    [list.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:_text attributes:@{
        NSFontAttributeName: CCFont(12.5, NSFontWeightRegular), NSForegroundColorAttributeName: CCTheme.textMuted, NSParagraphStyleAttributeName: lines }]];
    [list.layoutManager ensureLayoutForTextContainer:list.textContainer];
    CGFloat used = ceil([list.layoutManager usedRectForTextContainer:list.textContainer].size.height);
    CGFloat listHeight = MIN(used, maxList);
    list.frame = NSMakeRect(0, 0, width - inset * 2, used);

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(inset, inset, width - inset * 2, listHeight)];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.documentView = list;

    CGFloat height = inset + listHeight + 10 + 18 + inset;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    title.frame = NSMakeRect(inset, height - inset - 18, width - inset * 2, 18);
    [content addSubview:title];
    [content addSubview:scroll];
    NSViewController *controller = [NSViewController new];
    controller.view = content;

    _popover = [NSPopover new];
    _popover.behavior = NSPopoverBehaviorApplicationDefined;
    _popover.animates = NO;
    _popover.contentSize = content.frame.size;
    _popover.contentViewController = controller;
    [_popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:anchor.isFlipped ? NSRectEdgeMaxY : NSRectEdgeMinY];

    _away = 0;
    __weak CCHoverList *weak = self;
    _watch = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *timer) { [weak check]; }];
}

/// Off both the anchor and the list, and the gap between them, for a moment: the pointer has really left.
- (void)check {
    NSView *anchor = _anchor;
    NSWindow *window = anchor.window;
    if (!window || anchor.isHiddenOrHasHiddenAncestor) { [self close]; return; }
    NSRect area = [window convertRectToScreen:[anchor convertRect:anchor.bounds toView:nil]];
    NSWindow *own = _popover.contentViewController.view.window;
    if (own) area = NSUnionRect(area, own.frame);
    _away = NSPointInRect(NSEvent.mouseLocation, area) ? 0 : _away + 1;
    if (_away >= 2) [self close];
}

- (void)close {
    [_watch invalidate];
    _watch = nil;
    [_popover close];
    _popover = nil;
}

@end

@implementation CCRulesPage {
    CCHoverList *_downloadList;
    NSView *_header;
    CCButton *_download;
    CCPlainTable *_table;
    NSScrollView *_scroll;
    CCCard *_config;
    NSLayoutConstraint *_configWidth;
    NSArray<CCChip *> *_chips;
    NSArray<NSString *> *_ids;
    CCToggle *_oneVersion, *_skipReleased, *_skipUnfinished, *_withClips, *_oneFolder;
    CCSettingRow *_folderRow;
    CCLabel *_summary, *_skipped;
    NSView *_configHost;
    CCFlowView *_flow;
    NSArray<CCRuleRow *> *_rows;
    NSMutableSet *_open;
    CCRuleResult *_shown;
    CCCatalog *_computedFor;
    CGFloat _measuredWidth, _configHeight;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _open = [NSMutableSet set];
        _rows = @[];
        [self build];
    }
    return self;
}

- (CCToggle *)toggleWith:(void (^)(CCSettings *s, BOOL on))apply {
    CCToggle *toggle = [CCToggle new];
    __weak CCRulesPage *weak = self;
    toggle.onChange = ^(BOOL on) {
        apply(M().settings, on);
        [M() saveSettings];
        [weak changedRules];
    };
    return toggle;
}

- (void)changedRules {
    [M() recomputeRules];
}

- (void)build {
    __weak CCRulesPage *weak = self;
    CCLabel *subtitle = [CCLabel key:@"rules.subtitle" size:13 weight:NSFontWeightRegular role:CCRoleMuted];
    [subtitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *titles = CCVStack(@[ H1(@"rules.title"), subtitle ], 4);
    _download = [CCButton buttonWithStyle:CCButtonPrimary title:@"" symbol:@"arrow.down.circle"];
    _download.padding = NSEdgeInsetsMake(10, 18, 10, 18);
    _download.fontSize = 14;
    _download.onClick = ^{ [weak downloadAll]; };
    _downloadList = [[CCHoverList alloc] initWithAnchor:_download];
    NSStackView *header = CCHStack(@[ titles, CCSpacer(), _download ], 12);
    _header = header;
    [self addSubview:header];

    // ── the preset, which scrolls away with the list ──
    CCLabel *presetTitle = H2(@"rules.preset");
    presetTitle.wraps = YES;
    CCLabel *presetDesc = [CCLabel key:@"rules.preset.desc" size:12.5 weight:NSFontWeightRegular role:CCRoleMuted];
    presetDesc.wraps = YES;
    CCLabel *from = [CCLabel key:@"rules.from" size:11.5 weight:NSFontWeightSemibold role:CCRoleFaint];
    _ids = CCCatalog.ruleSectionIds;
    NSMutableArray *chips = [NSMutableArray array];
    for (NSString *identifier in _ids) {
        CCChip *chip = [CCChip chipWithTitle:@""];
        chip.locKey = [@"nav." stringByAppendingString:identifier];
        chip.onClick = ^{
            CCSettings *s = M().settings;
            NSMutableArray *sections = [s.rulesSections mutableCopy];
            if ([sections containsObject:identifier]) [sections removeObject:identifier];
            else [sections addObject:identifier];
            s.rulesSections = sections;
            [M() saveSettings];
            [weak changedRules];
        };
        [chips addObject:chip];
    }
    _chips = chips;
    void (^quick)(NSArray<NSString *> *) = ^(NSArray<NSString *> *sections) {
        M().settings.rulesSections = sections;
        [M() saveSettings];
        [weak changedRules];
    };
    NSMutableArray *quickButtons = [NSMutableArray array];
    for (NSArray *entry in @[ @[ @"rules.quick.unreleased", CCCatalog.unreleasedSectionIds ], @[ @"rules.quick.released", @[ @"albums" ] ] ]) {
        CCButton *button = [CCButton buttonWithStyle:CCButtonSubtle title:nil symbol:nil];
        button.locKey = entry[0];
        NSArray *sections = entry[1];
        button.onClick = ^{ quick(sections); };
        [quickButtons addObject:button];
    }
    NSStackView *quickRow = CCHStack(quickButtons, 6);
    _flow = [CCFlowView new];
    _flow.hSpacing = 8;
    _flow.vSpacing = 8;
    [_flow setItems:chips];

    _oneVersion = [self toggleWith:^(CCSettings *s, BOOL on) { s.rulesOneVersion = on; }];
    _skipReleased = [self toggleWith:^(CCSettings *s, BOOL on) { s.rulesSkipReleased = on; }];
    _skipUnfinished = [self toggleWith:^(CCSettings *s, BOOL on) { s.rulesSkipUnfinished = on; }];
    _withClips = [self toggleWith:^(CCSettings *s, BOOL on) { s.rulesWithClips = on; }];
    _oneFolder = [self toggleWith:^(CCSettings *s, BOOL on) { s.rulesOneFolder = on; }];
    _folderRow = [CCSettingRow rowWithSymbol:@"folder" titleKey:@"rules.oneFolder" descKey:nil control:_oneFolder];
    _folderRow.showsDivider = NO;
    NSArray *rows = @[
        [CCSettingRow rowWithSymbol:@"square.stack" titleKey:@"rules.oneVersion" descKey:@"rules.oneVersion.desc" control:_oneVersion],
        [CCSettingRow rowWithSymbol:@"checkmark.seal" titleKey:@"rules.skipReleased" descKey:@"rules.skipReleased.desc" control:_skipReleased],
        [CCSettingRow rowWithSymbol:@"hourglass" titleKey:@"rules.skipUnfinished" descKey:@"rules.skipUnfinished.desc" control:_skipUnfinished],
        [CCSettingRow rowWithSymbol:@"dot.radiowaves.left.and.right" titleKey:@"rules.withClips" descKey:@"rules.withClips.desc" control:_withClips],
        _folderRow,
    ];
    NSStackView *rowStack = CCVStack(rows, 0);
    for (NSView *row in rows) Stretch(rowStack, row);
    NSStackView *body = CCVStack(@[ presetTitle, presetDesc, quickRow, from, _flow, rowStack ], 4);
    [body setCustomSpacing:14 afterView:presetDesc];
    [body setCustomSpacing:8 afterView:from];
    [body setCustomSpacing:8 afterView:_flow];
    for (NSView *v in @[ presetTitle, presetDesc, _flow, rowStack ]) Stretch(body, v);
    _config = Card(body, NSEdgeInsetsMake(18, 24, 10, 24));
    _summary = [CCLabel text:@"" size:14 weight:NSFontWeightSemibold role:CCRoleText];
    _skipped = Caption(@"");
    NSStackView *counts = CCVStack(@[ _summary, _skipped ], 3);
    _configHost = CCAuto([CCFlippedView new]);
    _configHost.translatesAutoresizingMaskIntoConstraints = YES;
    [_configHost addSubview:_config];
    [_configHost addSubview:counts];
    _configWidth = [_config.widthAnchor constraintEqualToConstant:600];
    [NSLayoutConstraint activateConstraints:@[
        _configWidth,
        [_config.topAnchor constraintEqualToAnchor:_configHost.topAnchor],
        [_config.leadingAnchor constraintEqualToAnchor:_configHost.leadingAnchor constant:32],
        [counts.topAnchor constraintEqualToAnchor:_config.bottomAnchor constant:18],
        [counts.leadingAnchor constraintEqualToAnchor:_configHost.leadingAnchor constant:36],
        [counts.trailingAnchor constraintLessThanOrEqualToAnchor:_configHost.trailingAnchor constant:-32],
    ]];

    _table = MakeTable(self);
    _scroll = MakeTableScroll(_table);
    _scroll.contentInsets = NSEdgeInsetsMake(2, 0, 28, 0);
    [self addSubview:_scroll];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:32],
        [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-32],
        [_scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(tableResized:) name:NSViewFrameDidChangeNotification object:_table];
    _table.postsFrameChangedNotifications = YES;
    [self rebuildRows];
}

- (void)tableResized:(NSNotification *)n {
    // Not while the table is at work: it does not take being asked about its rows from inside its own layout.
    dispatch_async(dispatch_get_main_queue(), ^{ [self measureConfig]; });
}

- (void)measureConfig {
    CGFloat width = MAX(300, NSWidth(_scroll.bounds) - 58);
    if (width == _measuredWidth) return;
    _measuredWidth = width;
    _configWidth.constant = width;
    [_configHost layoutSubtreeIfNeeded];
    _configHeight = _config.fittingSize.height + 18 + 40 + 16;
    [_table noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndex:0]];
}

- (void)rebuildRows {
    CCRuleRow *config = [CCRuleRow new];
    config.kind = CCRuleRowConfig;
    NSMutableArray *rows = [NSMutableArray arrayWithObject:config];
    for (CCSongGroup *group in M().rulesResult.kept) {
        CCRuleRow *row = [CCRuleRow new];
        row.kind = CCRuleRowGroup;
        row.group = group;
        [rows addObject:row];
        if (![_open containsObject:group.title] || group.versions.count < 2) continue;
        for (CCSongVersion *v in group.versions) {
            CCRuleRow *line = [CCRuleRow new];
            line.kind = CCRuleRowVersion;
            line.group = group;
            line.version = v;
            [rows addObject:line];
        }
    }
    _rows = rows;
    [_table reloadData];
}

- (CCCatalogNode *)hoveredNode {
    __block CCCatalogNode *node = nil;
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        CCLibraryCell *cell = [rowView viewAtColumn:0];
        if ([cell isKindOfClass:CCLibraryCell.class] && cell.looksHovered) node = cell.node;
    }];
    return node;
}

- (void)downloadAll {
    [_downloadList close];
    CCRuleResult *result = M().rulesResult;
    if (result.kept.count > 0) [M() downloadRuleGroups:result.kept];
}

- (void)applyTheme { gCellThemeStamp++; }

- (void)refresh {
    CCModel *m = M();
    CCSettings *s = m.settings;
    [self measureConfig];
    if (m.catalog && _computedFor != m.catalog) {
        _computedFor = m.catalog;
        [m recomputeRules];
    }
    for (NSUInteger i = 0; i < _ids.count; i++) _chips[i].checked = [s.rulesSections containsObject:_ids[i]];
    BOOL animated = self.window != nil;
    if (_oneVersion.on != s.rulesOneVersion) [_oneVersion setOn:s.rulesOneVersion animated:animated];
    if (_skipReleased.on != s.rulesSkipReleased) [_skipReleased setOn:s.rulesSkipReleased animated:animated];
    if (_skipUnfinished.on != s.rulesSkipUnfinished) [_skipUnfinished setOn:s.rulesSkipUnfinished animated:animated];
    if (_withClips.on != s.rulesWithClips) [_withClips setOn:s.rulesWithClips animated:animated];
    if (_oneFolder.on != s.rulesOneFolder) [_oneFolder setOn:s.rulesOneFolder animated:animated];
    _folderRow.descLabel.stringValue = LF(@"rules.oneFolder.desc", L(@"rules.folderName"));

    CCRuleResult *r = m.rulesResult;
    if (r != _shown) {
        _shown = r;
        [self rebuildRows];
    }
    NSMutableArray<CCDownloadFile *> *missingFiles = [NSMutableArray array];
    long long missingBytes = 0;
    NSInteger have = 0;
    for (CCDownloadFile *f in r ? [CCSongRules files:r.kept options:m.ruleOptions] : @[]) {
        if ([m.disk has:f.apiPath]) { have++; continue; }
        [missingFiles addObject:f];
        missingBytes += f.size;
    }
    if (m.rulesLoading) {
        _summary.stringValue = L(@"rules.loading");
        _skipped.stringValue = @"";
    } else if (m.rulesError) {
        _summary.stringValue = LF(@"lyrics.failed", m.rulesError);
        _skipped.stringValue = @"";
    } else if (r) {
        NSString *summary = LF(@"rules.summary", CCFormatCount((long long)r.kept.count), CCFormatBytes(r.bytes), CCFormatCount(r.filesConsidered));
        if (have > 0) summary = [NSString stringWithFormat:@"%@ · %@", summary, LF(@"rules.onDisk", CCFormatCount(have), CCFormatCount((long long)missingFiles.count), CCFormatBytes(missingBytes))];
        _summary.stringValue = summary;
        NSString *skipped = LF(@"rules.skipped", CCFormatCount(r.skippedVersions), CCFormatCount(r.skippedReleased), CCFormatCount(r.skippedUnfinished));
        if (r.skippedCopies > 0) skipped = [NSString stringWithFormat:@"%@ · %@", skipped, LF(@"rules.copies", CCFormatCount(r.skippedCopies))];
        _skipped.stringValue = skipped;
    }
    BOOL allThere = have > 0 && missingFiles.count == 0;
    _download.title = allThere ? L(@"rules.allThere") : LF(@"rules.download", CCFormatCount((long long)missingFiles.count));
    _download.enabled = !m.rulesLoading && missingFiles.count > 0;
    [_downloadList setTitle:LF(@"rules.downloadList", CCFormatCount((long long)missingFiles.count), CCFormatBytes(missingBytes)) text:m.rulesLoading ? nil : [CCSongRules listOf:missingFiles]];
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        CCLibraryCell *cell = [rowView viewAtColumn:0];
        if ([cell isKindOfClass:CCLibraryCell.class]) [cell updatePlayState];
    }];
}

- (void)playEntrance {
    [super playEntrance];
    CCEntrance(_header, 0, 18);
    CCEntrance(_scroll, 60, 18);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_rows.count; }
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row { return NO; }
- (void)tableView:(NSTableView *)tableView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
    [NSNotificationCenter.defaultCenter postNotificationName:CCHoverDirtyNotification object:self];
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    switch (_rows[(NSUInteger)row].kind) {
        case CCRuleRowConfig: return MAX(_configHeight, 400);
        case CCRuleRowGroup: return 76;
        case CCRuleRowVersion: return 50;
    }
    return 50;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    CCRuleRow *r = _rows[(NSUInteger)row];
    if (r.kind == CCRuleRowConfig) return _configHost;
    BOOL top = r.kind == CCRuleRowGroup;
    NSString *identifier = top ? @"top" : @"nested";
    CCLibraryCell *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[CCLibraryCell alloc] initTop:top];
        cell.identifier = identifier;
        cell.owner = self;
    }
    if (top) [cell configureGroup:r.group open:[_open containsObject:r.group.title]];
    else [cell configureVersion:r.version picked:r.group.picked == r.version];
    return cell;
}

- (CCRuleRow *)rowOf:(CCLibraryCell *)cell {
    NSInteger row = [_table rowForView:cell];
    return row >= 0 && row < (NSInteger)_rows.count ? _rows[(NSUInteger)row] : nil;
}

/// The radio of a version: that take is what gets downloaded.
- (void)cell:(CCLibraryCell *)cell checked:(BOOL)checked {
    CCRuleRow *r = [self rowOf:cell];
    if (r.kind != CCRuleRowVersion) return;
    r.group.picked = r.version;
    [self rebuildRowsKeepingScroll];
    [NSNotificationCenter.defaultCenter postNotificationName:CCModelDidChangeNotification object:M()];
}

- (void)rebuildRowsKeepingScroll {
    NSPoint origin = _scroll.contentView.bounds.origin;
    [self rebuildRows];
    [_scroll.contentView scrollToPoint:origin];
}

- (void)cellToggled:(CCLibraryCell *)cell {
    CCRuleRow *r = [self rowOf:cell];
    if (r.kind == CCRuleRowVersion) {
        [self cell:cell checked:YES];
        return;
    }
    if (r.group.versions.count < 2) return;
    if ([_open containsObject:r.group.title]) [_open removeObject:r.group.title];
    else [_open addObject:r.group.title];
    [self rebuildRowsKeepingScroll];
}

- (NSMenu *)menuForCell:(CCLibraryCell *)cell {
    return cell.node ? CCRowMenu(cell.node, NO) : nil;
}

@end

// ═════════════════════════════ missing lyrics ═════════════════════════════

@interface CCGapCell : CCFlippedView
- (void)configure:(CCGapRow *)row;
@end

@implementation CCGapCell {
    CCLabel *_name, *_folder, *_status;
    CCPill *_chip;
    CCLyricsGapKind _kind;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _name = [CCLabel text:@"" size:13 weight:NSFontWeightSemibold role:CCRoleText];
        _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _folder = Caption(@"");
        _folder.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _status = Muted(@"", 12);
        _status.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _status.alignment = NSTextAlignmentRight;
        for (CCLabel *l in @[ _name, _folder, _status ]) [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *text = CCVStack(@[ _name, _folder ], 1);
        Stretch(text, _name);
        Stretch(text, _folder);
        __weak CCGapCell *weak = self;
        _chip = [CCPill pillWithText:@"" symbol:nil color:^NSColor *{ return [weak chipColor]; } soft:^NSColor *{ return [[weak chipColor] colorWithAlphaComponent:0.16]; }];
        [_chip setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        CCBox *box = [[CCBox alloc] initWithFrame:NSZeroRect];
        box.radius = 12;
        box.fill = ^NSColor *{ return CCTheme.inset; };
        [self addSubview:box];
        CCPin(box, self, NSEdgeInsetsMake(0, 32, 4, 26));
        for (NSView *v in @[ text, _chip, _status ]) [box addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:14],
            [text.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
            [text.widthAnchor constraintGreaterThanOrEqualToConstant:180],
            [_chip.leadingAnchor constraintEqualToAnchor:text.trailingAnchor constant:12],
            [_chip.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
            [_status.leadingAnchor constraintEqualToAnchor:_chip.trailingAnchor constant:12],
            [_status.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-14],
            [_status.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
            [_status.widthAnchor constraintLessThanOrEqualToAnchor:box.widthAnchor multiplier:0.34],
        ]];
    }
    return self;
}

- (NSColor *)chipColor { return _kind == CCLyricsGapNoWords ? CCTheme.warning : CCTheme.accent; }

- (void)configure:(CCGapRow *)row {
    CCLyricsGap *gap = row.gap;
    _kind = gap.kind;
    _name.stringValue = gap.relative.lastPathComponent;
    _name.toolTip = gap.relative;
    NSString *folder = gap.relative.stringByDeletingLastPathComponent;
    _folder.stringValue = folder;
    _folder.hidden = folder.length == 0;
    NSString *kind = L(gap.kind == CCLyricsGapNoWords ? @"gaps.kind.none" : @"gaps.kind.other");
    _chip.label.stringValue = gap.hasWordsOf.length > 0 ? [NSString stringWithFormat:@"%@ · %@", kind, gap.hasWordsOf] : kind;
    [_chip applyTheme];
    [_chip cc_broadcastTheme];
    _status.stringValue = row.status ?: @"";
    _status.toolTip = row.status;
    _status.role = row.state == CCGapFound || row.state == CCGapFoundOther ? CCRoleSuccess : row.state == CCGapFailed ? CCRoleWarning : CCRoleMuted;
    [self cc_broadcastTheme];
}

@end

@interface CCGapsPage () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation CCGapsPage {
    NSView *_header;
    CCLabel *_folderPath, *_scanLine, *_summary, *_searchDesc, *_result, *_empty, *_notEnabled;
    CCButton *_scan, *_search, *_stop;
    NSStackView *_searchRow;
    CCPlainTable *_table;
    NSScrollView *_scroll;
    NSArray<CCGapRow *> *_shownRows;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) [self build];
    return self;
}

- (void)build {
    __weak CCGapsPage *weak = self;
    CCLabel *subtitle = [CCLabel key:@"gaps.subtitle" size:13 weight:NSFontWeightRegular role:CCRoleMuted];
    subtitle.wraps = YES;

    CCIcon *icon = [CCIcon symbol:@"folder" size:15 weight:NSFontWeightRegular role:CCRoleAccent];
    CCLabel *folderTitle = Caption(L(@"gaps.folder"));
    folderTitle.locKey = @"gaps.folder";
    _folderPath = [CCLabel text:@"" size:13 weight:NSFontWeightRegular role:CCRoleText];
    _folderPath.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_folderPath setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *folderText = CCVStack(@[ folderTitle, _folderPath ], 1);
    Stretch(folderText, _folderPath);
    CCButton *change = [CCButton buttonWithStyle:CCButtonSubtle title:nil symbol:nil];
    change.locKey = @"overview.change";
    change.onClick = ^{ [weak chooseFolder]; };
    _scan = [CCButton buttonWithStyle:CCButtonPrimary title:nil symbol:nil];
    _scan.locKey = @"gaps.scan";
    _scan.padding = NSEdgeInsetsMake(9, 16, 9, 16);
    _scan.fontSize = 13.5;
    _scan.onClick = ^{ [M() scanGaps]; };
    NSStackView *folderLine = CCHStack(@[ icon, folderText, change, _scan ], 12);
    [folderText setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    CCCard *folderCard = Card(folderLine, NSEdgeInsetsMake(10, 16, 10, 12));

    _scanLine = Muted(@"", 13);
    _scanLine.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _summary = [CCLabel text:@"" size:14 weight:NSFontWeightSemibold role:CCRoleText];
    _empty = [CCLabel key:@"gaps.empty" size:13 weight:NSFontWeightRegular role:CCRoleSuccess];
    _notEnabled = [CCLabel key:@"gaps.notEnabled" size:11.5 weight:NSFontWeightRegular role:CCRoleFaint];

    _search = [CCButton buttonWithStyle:CCButtonPrimary title:nil symbol:@"magnifyingglass"];
    _search.padding = NSEdgeInsetsMake(9, 16, 9, 16);
    _search.fontSize = 13.5;
    _search.symbolSize = 13;
    _search.onClick = ^{ [M() searchGaps]; };
    _stop = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:@"stop"];
    _stop.locKey = @"gaps.stop";
    _stop.padding = NSEdgeInsetsMake(9, 14, 9, 14);
    _stop.fontSize = 13;
    _stop.onClick = ^{ [M() stopGaps]; };
    _searchDesc = [CCLabel key:@"gaps.search.desc" size:12 weight:NSFontWeightRegular role:CCRoleMuted];
    _searchDesc.wraps = YES;
    _result = [CCLabel text:@"" size:13 weight:NSFontWeightSemibold role:CCRoleSuccess];
    NSStackView *descStack = CCVStack(@[ _result, _searchDesc ], 3);
    Stretch(descStack, _searchDesc);
    _searchRow = CCHStack(@[ _search, _stop, descStack ], 12);
    [descStack setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *header = CCVStack(@[ H1(@"gaps.title"), subtitle, folderCard, _scanLine, _summary, _empty, _searchRow, _notEnabled ], 8);
    [header setCustomSpacing:4 afterView:header.arrangedSubviews.firstObject];
    [header setCustomSpacing:14 afterView:subtitle];
    for (NSView *v in @[ subtitle, folderCard, _scanLine, _searchRow ]) Stretch(header, v);
    _header = header;
    [self addSubview:header];

    _table = MakeTable(self);
    _table.rowHeight = 54;
    _scroll = MakeTableScroll(_table);
    _scroll.contentInsets = NSEdgeInsetsMake(2, 0, 28, 0);
    [self addSubview:_scroll];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:32],
        [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-32],
        [_scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
}

- (void)chooseFolder {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        M().gapsFolder = panel.URL.path;
        [self refresh];
    }];
}

- (void)refresh {
    CCModel *m = M();
    BOOL busy = m.gapsScanning || m.gapsSearching;
    _folderPath.stringValue = m.gapsFolder;
    _folderPath.toolTip = m.gapsFolder;
    _scan.enabled = !busy;
    _scanLine.hidden = !m.gapsScanning && !m.gapsError;
    _scanLine.role = m.gapsError ? CCRoleWarning : CCRoleMuted;
    _scanLine.stringValue = m.gapsError ? LF(@"lyrics.failed", m.gapsError) : LF(@"gaps.scanning", CCFormatCount(m.gapsDone), CCFormatCount(m.gapsTotal));

    CCLyricsGapScan *scan = m.gapScan;
    NSInteger none = 0, other = 0;
    for (CCGapRow *row in m.gapRows) {
        if (row.gap.kind == CCLyricsGapNoWords) none++;
        else other++;
    }
    _summary.hidden = !scan;
    if (scan) _summary.stringValue = LF(@"gaps.summary", CCFormatCount(scan.files), CCFormatCount(scan.fine), CCFormatCount(none), CCFormatCount(other));
    _empty.hidden = !scan || scan.gaps.count > 0;
    _searchRow.hidden = !scan || scan.gaps.count == 0;
    _notEnabled.hidden = m.settings.lyricsEnabled;
    _search.title = m.gapsSearching ? LF(@"gaps.searching", CCFormatCount(m.gapsDone), CCFormatCount(m.gapsTotal)) : L(@"gaps.search");
    _search.enabled = !busy;
    _stop.hidden = !m.gapsSearching;
    _result.hidden = !m.gapsSearched;
    _result.stringValue = LF(@"gaps.result", CCFormatCount(m.gapsFound), CCFormatCount(m.gapsNotFound));

    if (_shownRows != m.gapRows) {
        _shownRows = m.gapRows;
        [_table reloadData];
    } else {
        [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
            CCGapCell *cell = [rowView viewAtColumn:0];
            if ([cell isKindOfClass:CCGapCell.class] && row < (NSInteger)self->_shownRows.count) [cell configure:self->_shownRows[(NSUInteger)row]];
        }];
    }
}

- (void)playEntrance {
    [super playEntrance];
    CCEntrance(_header, 0, 18);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_shownRows.count; }
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row { return NO; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    CCGapCell *cell = [tableView makeViewWithIdentifier:@"gap" owner:self];
    if (!cell) {
        cell = [CCGapCell new];
        cell.identifier = @"gap";
    }
    [cell configure:_shownRows[(NSUInteger)row]];
    return cell;
}

@end

// ═════════════════════════════ the player bar ═════════════════════════════

static NSString *Clock(double seconds) {
    long long s = isfinite(seconds) ? llround(MAX(0, seconds)) : 0;
    if (s >= 3600) return [NSString stringWithFormat:@"%lld:%02lld:%02lld", s / 3600, (s % 3600) / 60, s % 60];
    return [NSString stringWithFormat:@"%lld:%02lld", s / 60, s % 60];
}

/// One line of the queue: a click plays it, or pauses the one that is playing.
@interface CCQueueCell : CCFlippedView
@property (nonatomic, strong, nullable) CCCatalogNode *node;
- (void)update;
@end

@implementation CCQueueCell {
    CCLibraryCard *_card;
    CCIcon *_mark;
    CCLabel *_name, *_size;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        __weak CCQueueCell *weak = self;
        _card = [CCLibraryCard card];
        _card.flat = YES;
        _card.radius = 10;
        _card.fill = nil;
        _card.stroke = nil;
        _card.onClick = ^{
            CCCatalogNode *node = weak.node;
            if (!node) return;
            if ([M().player isPlayingNode:node]) [M().player togglePlay];
            else [M() playNode:node];
        };
        _card.menuBlock = ^NSMenu *{
            CCCatalogNode *node = weak.node;
            return node ? CCRowMenu(node, NO) : nil;
        };
        [self addSubview:_card];
        CCPin(_card, self, NSEdgeInsetsMake(1, 8, 1, 8));
        _mark = [CCIcon symbol:@"music.note" size:13 weight:NSFontWeightRegular role:CCRoleMuted];
        [_mark.widthAnchor constraintEqualToConstant:18].active = YES;
        _name = [CCLabel text:@"" size:13 weight:NSFontWeightRegular role:CCRoleText];
        _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        _size = Caption(@"");
        [_size setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *line = CCHStack(@[ _mark, _name, _size ], 10);
        [_name setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_card addSubview:line];
        CCPin(line, _card, NSEdgeInsetsMake(0, 10, 0, 12));
    }
    return self;
}

- (void)setNode:(CCCatalogNode *)node {
    _node = node;
    [self cc_syncHover:nil];
    _name.stringValue = node.displayName ?: @"";
    _name.toolTip = node.name;
    _size.stringValue = node ? CCFormatBytes(node.size) : @"";
    [self update];
}

- (void)update {
    CCPlayer *player = M().player;
    BOOL current = _node && [player isPlayingNode:_node];
    NSString *symbol = !current ? @"music.note" : player.playing ? @"speaker.wave.2.fill" : @"pause.fill";
    if (![_mark.symbol isEqualToString:symbol]) _mark.symbol = symbol;
    _mark.role = current ? CCRoleAccent : CCRoleMuted;
    _name.role = current ? CCRoleAccent : CCRoleText;
}

@end

/// Lies under the queue and over the pages: a click anywhere else only closes the queue, and ticks nothing by accident.
@interface CCQueueBackdrop : NSView
@property (nonatomic, copy, nullable) void (^onClick)(void);
@end

@implementation CCQueueBackdrop
- (NSView *)hitTest:(NSPoint)point {
    NSPoint p = [self.superview convertPoint:point toView:self];
    return !self.hidden && NSPointInRect(p, self.bounds) ? self : nil;
}
- (void)mouseDown:(NSEvent *)event {
    if (self.onClick) self.onClick();
}
- (void)rightMouseDown:(NSEvent *)event {
    if (self.onClick) self.onClick();
}
@end

/// What plays next: the playable files of the folder. Stays open while the bar is used, and goes on a click elsewhere or Esc.
@interface CCPlayerQueue : CCBox <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak) NSView *backdrop;
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, readonly) BOOL isOpen;
- (void)toggle;
- (void)close;
- (void)refresh;
@end

static const CGFloat kQueueRow = 38;

@implementation CCPlayerQueue {
    CCLabel *_title, *_line;
    CCPlainTable *_table;
    NSLayoutConstraint *_height;
    NSArray<CCCatalogNode *> *_nodes;
    NSString *_shownPath;
    id _monitor;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.radius = 16;
        self.fill = ^NSColor *{ return CCTheme.cardSolid; };
        self.stroke = ^NSColor *{ return CCTheme.cardBorder; };
        self.layer.shadowColor = NSColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 18;
        self.hidden = YES;
        _nodes = @[];
        [self.widthAnchor constraintEqualToConstant:460].active = YES;
        _height = [self.heightAnchor constraintEqualToConstant:200];
        _height.active = YES;

        _title = [CCLabel key:@"player.queue" size:15 weight:NSFontWeightSemibold role:CCRoleText];
        _line = Caption(@"");
        _line.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_line setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *head = CCVStack(@[ _title, _line ], 2);
        Stretch(head, _line);
        [self addSubview:head];

        _table = MakeTable(self);
        NSScrollView *scroll = MakeTableScroll(_table);
        [self addSubview:scroll];
        [NSLayoutConstraint activateConstraints:@[
            [head.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [head.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [head.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [scroll.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:8],
            [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
        ]];
    }
    return self;
}

- (BOOL)isOpen { return !self.hidden; }

- (void)toggle {
    if (self.isOpen) {
        [self close];
        return;
    }
    self.hidden = NO;
    self.backdrop.hidden = NO;
    _shownPath = nil;
    [self refresh];
    CCEntrance(self, 0, 12);
    __weak CCPlayerQueue *weak = self;
    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        return [weak sawEvent:event];
    }];
}

- (NSEvent *)sawEvent:(NSEvent *)event {
    if (event.window != self.window || event.keyCode != 53) return event;
    [self close];
    return nil;
    return event;
}

- (void)close {
    if (_monitor) [NSEvent removeMonitor:_monitor];
    _monitor = nil;
    if (self.hidden) return;
    self.hidden = YES;
    self.backdrop.hidden = YES;
    if (self.onClose) self.onClose();
}

- (void)refresh {
    if (!self.isOpen) return;
    CCPlayer *player = M().player;
    if (!player.node) {
        [self close];
        return;
    }
    NSArray<CCCatalogNode *> *nodes = player.queue;
    NSUInteger at = 0;
    for (NSUInteger i = 0; i < nodes.count; i++)
        if ([player isPlayingNode:nodes[i]]) at = i;
    _line.stringValue = LF(@"player.queue.line", CCFormatCount((long long)at + 1), CCFormatCount((long long)nodes.count), player.node.parent.displayName ?: @"");
    if (nodes != _nodes) {
        _nodes = nodes;
        _height.constant = 58 + MIN(9.0, (CGFloat)nodes.count) * kQueueRow + 8;
        [_table reloadData];
    }
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        CCQueueCell *cell = [rowView viewAtColumn:0];
        if ([cell isKindOfClass:CCQueueCell.class]) [cell update];
    }];
    if (![_shownPath isEqualToString:player.node.path]) {
        _shownPath = player.node.path;
        [self.window layoutIfNeeded];
        [_table scrollRowToVisible:(NSInteger)at];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:CCHoverDirtyNotification object:self];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_nodes.count; }
- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row { return kQueueRow; }
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row { return NO; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    CCQueueCell *cell = [tableView makeViewWithIdentifier:@"queue" owner:self];
    if (!cell) {
        cell = [CCQueueCell new];
        cell.identifier = @"queue";
    }
    cell.node = _nodes[(NSUInteger)row];
    return cell;
}

- (void)tableView:(NSTableView *)tableView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
    [NSNotificationCenter.defaultCenter postNotificationName:CCHoverDirtyNotification object:self];
}

@end

@implementation CCPlayerBar {
    CCButton *_previous, *_play, *_next, *_close, *_lyrics, *_download, *_speaker;
    CCLabel *_title, *_folder, *_elapsed, *_total;
    CCSlider *_seek, *_volume;
    CCLibraryCard *_titleArea;
    CCIcon *_chevron;
    CCPlayerQueue *_queue;
    CCQueueBackdrop *_backdrop;
}

- (NSView *)queuePanel { return _queue; }
- (NSView *)queueBackdrop { return _backdrop; }

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.radius = 18;
        self.fill = ^NSColor *{ return CCTheme.cardSolid; };
        self.stroke = ^NSColor *{ return CCTheme.cardBorder; };
        self.layer.shadowColor = NSColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.25;
        self.layer.shadowRadius = 14;
        self.hidden = YES;
        CCSize(self, 0, 68);
        CCPlayer *player = M().player;
        __weak CCPlayerBar *weak = self;
        _previous = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"backward.fill"];
        _previous.onClick = ^{ [player previous]; };
        _play = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"play.fill"];
        _play.symbolSize = 18;
        _play.onClick = ^{ [player togglePlay]; };
        _next = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"forward.fill"];
        _next.onClick = ^{ [player next]; };
        NSStackView *transport = CCHStack(@[ _previous, _play, _next ], 2);

        _title = [CCLabel text:@"" size:13.5 weight:NSFontWeightSemibold role:CCRoleText];
        _folder = Caption(@"");
        for (CCLabel *l in @[ _title, _folder ]) {
            l.lineBreakMode = NSLineBreakByTruncatingMiddle;
            [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        }
        NSStackView *titles = CCVStack(@[ _title, _folder ], 1);
        Stretch(titles, _title);
        Stretch(titles, _folder);
        [titles setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        _chevron = [CCIcon symbol:@"chevron.up" size:11 weight:NSFontWeightSemibold role:CCRoleFaint];
        NSStackView *titleLine = CCHStack(@[ titles, _chevron ], 8);

        // The whole name is one button: it opens what plays next.
        _titleArea = [CCLibraryCard card];
        _titleArea.flat = YES;
        _titleArea.radius = 10;
        _titleArea.fill = nil;
        _titleArea.stroke = nil;
        _titleArea.onClick = ^{ [weak toggleQueue]; };
        [_titleArea addSubview:titleLine];
        CCPin(titleLine, _titleArea, NSEdgeInsetsMake(5, 10, 5, 10));

        _queue = [CCPlayerQueue new];
        _queue.onClose = ^{ [weak queueMoved]; };
        _backdrop = [CCQueueBackdrop new];
        _backdrop.hidden = YES;
        _backdrop.onClick = ^{
            CCPlayerBar *bar = weak;
            if (bar) [bar->_queue close];
        };
        _queue.backdrop = _backdrop;

        _elapsed = Caption(@"0:00");
        _elapsed.font = CCDigitsFont(11.5, NSFontWeightRegular);
        _elapsed.alignment = NSTextAlignmentRight;
        _total = Caption(@"0:00");
        _total.font = CCDigitsFont(11.5, NSFontWeightRegular);
        _seek = [CCSlider new];
        _seek.onChange = ^(double value, BOOL finished) {
            // The clock follows the finger; the sound moves when it lets go.
            CCPlayerBar *bar = weak;
            if (player.duration > 0 && bar) bar->_elapsed.stringValue = Clock(value * player.duration);
            if (finished) [player seekToFraction:value];
        };
        NSStackView *seekRow = CCHStack(@[ _elapsed, _seek, _total ], 8);
        [_elapsed.widthAnchor constraintEqualToConstant:40].active = YES;
        [_total.widthAnchor constraintEqualToConstant:40].active = YES;

        _lyrics = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"quote.bubble"];
        _lyrics.symbolSize = 14;
        _lyrics.onClick = ^{
            if (player.node) [M() showLyricsOf:player.node];
        };
        _download = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"arrow.down.circle"];
        _download.symbolSize = 15;
        _download.onClick = ^{
            CCCatalogNode *node = player.node;
            if (!node) return;
            NSString *local = [CCLibrary localCopy:node under:M().settings.destination];
            if (local) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:local] ]];
            else [M() downloadNode:node];
        };
        NSStackView *tools = CCHStack(@[ _lyrics, _download ], 2);

        _speaker = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"speaker.wave.2"];
        _speaker.symbolSize = 13;
        _speaker.onClick = ^{ player.muted = !player.muted; };
        _volume = [CCSlider new];
        [_volume.widthAnchor constraintEqualToConstant:84].active = YES;
        _volume.value = player.volume;
        _volume.onChange = ^(double value, BOOL finished) {
            player.volume = value;
            if (player.muted) player.muted = NO;
            if (finished) [player saveVolume];
        };
        NSStackView *volumeRow = CCHStack(@[ _speaker, _volume ], 2);
        _close = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"xmark"];
        _close.symbolSize = 12;
        _close.onClick = ^{ [player close]; };

        NSStackView *line = CCHStack(@[ transport, _titleArea, seekRow, tools, volumeRow, _close ], 12);
        [_titleArea.widthAnchor constraintEqualToAnchor:seekRow.widthAnchor multiplier:0.75].active = YES;
        [_titleArea setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [seekRow setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:line];
        CCPin(line, self, NSEdgeInsetsMake(8, 12, 8, 8));
        [_titleArea.heightAnchor constraintEqualToConstant:50].active = YES;
        [self applyLanguage];
    }
    return self;
}

- (void)toggleQueue {
    [_queue toggle];
    [self queueMoved];
}

- (void)queueMoved {
    _chevron.symbol = _queue.isOpen ? @"chevron.down" : @"chevron.up";
    _titleArea.toolTip = L(_queue.isOpen ? @"player.queue.hide" : @"player.queue.show");
}

- (void)applyLanguage {
    _previous.toolTip = L(@"player.previous");
    _next.toolTip = L(@"player.next");
    _close.toolTip = L(@"player.close");
    _volume.toolTip = L(@"player.volume");
    _lyrics.toolTip = L(@"menu.row.lyrics");
    [self queueMoved];
    [self refresh];
}

- (void)refresh {
    CCPlayer *player = M().player;
    CCCatalogNode *node = player.node;
    if (!node) {
        [_queue close];
        return;
    }
    _title.stringValue = node.displayName;
    _folder.stringValue = player.loading ? L(@"player.loading") : [CCCatalogRelations place:node];
    _title.toolTip = node.path;
    _folder.toolTip = [CCCatalogRelations place:node];
    _play.symbol = player.playing ? @"pause.fill" : @"play.fill";
    _play.toolTip = L(player.playing ? @"player.pause" : @"player.play");
    _next.enabled = player.hasNext;
    _speaker.symbol = player.muted || player.volume <= 0 ? @"speaker.slash" : @"speaker.wave.2";
    _speaker.toolTip = L(player.muted ? @"player.unmute" : @"player.mute");
    BOOL here = [CCLibrary localCopy:node under:M().settings.destination] != nil;
    _download.symbol = here ? @"checkmark.circle" : @"arrow.down.circle";
    _download.toolTip = L(here ? @"menu.row.showFile" : @"player.download");
    [_queue refresh];
    [self tick];
}

- (void)tick {
    CCPlayer *player = M().player;
    if (!_seek.dragging) {
        _elapsed.stringValue = Clock(player.currentTime);
        _seek.value = player.duration > 0 ? player.currentTime / player.duration : 0;
    }
    _total.stringValue = Clock(player.duration);
    if (!_volume.dragging) _volume.value = player.volume;
    _previous.enabled = player.hasPrevious || player.currentTime > 3;
}

@end

// ═════════════════════════════ the preview sheet ═════════════════════════════

/// Look at a file before downloading it: an image, the video with its controls, or the start of a text.
@implementation CCPreviewSheet {
    CCBox *_card;
    CCLabel *_name, *_place, *_count, *_message, *_selectLabel;
    CCButton *_previous, *_next, *_close;
    CCCheck *_select;
    NSImageView *_image;
    AVPlayerView *_video;
    NSTextView *_text;
    NSScrollView *_textScroll;
    CCSpinner *_spinner;
    NSArray<CCCatalogNode *> *_siblings;
    NSUInteger _index;
    NSInteger _generation;
    AVPlayerItem *_item;
    NSURLSessionDataTask *_task;
    BOOL _open;
}

static void *kPreviewStatus = &kPreviewStatus;

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.hidden = YES;
        __weak CCPreviewSheet *weak = self;
        _card = [[CCBox alloc] initWithFrame:NSZeroRect];
        _card.radius = 22;
        _card.fill = ^NSColor *{ return CCTheme.cardSolid; };
        _card.stroke = ^NSColor *{ return CCTheme.cardBorder; };
        _card.layer.shadowColor = NSColor.blackColor.CGColor;
        _card.layer.shadowOpacity = 0.5;
        _card.layer.shadowRadius = 28;

        _name = [CCLabel text:@"" size:16 weight:NSFontWeightSemibold role:CCRoleText];
        _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _place = Caption(@"");
        _place.lineBreakMode = NSLineBreakByTruncatingMiddle;
        for (CCLabel *l in @[ _name, _place ]) [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *titles = CCVStack(@[ _name, _place ], 2);
        Stretch(titles, _name);
        Stretch(titles, _place);
        _count = Caption(@"");
        _previous = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"chevron.left"];
        _previous.onClick = ^{ [weak step:-1]; };
        _next = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"chevron.right"];
        _next.onClick = ^{ [weak step:1]; };
        _close = [CCButton buttonWithStyle:CCButtonIcon title:nil symbol:@"xmark"];
        _close.onClick = ^{ [weak hide]; };
        NSStackView *top = CCHStack(@[ titles, _count, _previous, _next, _close ], 6);
        [titles setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [top setCustomSpacing:14 afterView:titles];

        NSView *stage = CCAuto([CCFlippedView new]);
        _image = CCAuto([NSImageView new]);
        _image.imageScaling = NSImageScaleProportionallyDown;
        [_image setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_image setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
        _video = CCAuto([AVPlayerView new]);
        _video.controlsStyle = AVPlayerViewControlsStyleInline;
        _textScroll = [NSTextView scrollableTextView];
        _textScroll.translatesAutoresizingMaskIntoConstraints = NO;
        _textScroll.drawsBackground = NO;
        _textScroll.scrollerStyle = NSScrollerStyleOverlay;
        _text = _textScroll.documentView;
        _text.editable = NO;
        _text.drawsBackground = NO;
        _text.font = [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightRegular];
        for (NSView *v in @[ _image, _video, _textScroll ]) {
            [stage addSubview:v];
            CCPin(v, stage, NSEdgeInsetsMake(0, 0, 0, 0));
        }
        _spinner = [[CCSpinner alloc] initWithDiameter:26 lineWidth:3 sweep:270 period:0.9];
        _message = Muted(@"", 13);
        _message.wraps = YES;
        _message.alignment = NSTextAlignmentCenter;
        _message.wrapLimit = 520;
        for (NSView *v in @[ _spinner, _message ]) {
            [stage addSubview:v];
            [v.centerXAnchor constraintEqualToAnchor:stage.centerXAnchor].active = YES;
        }
        [_spinner.centerYAnchor constraintEqualToAnchor:stage.centerYAnchor constant:-16].active = YES;
        [_message.topAnchor constraintEqualToAnchor:_spinner.bottomAnchor constant:12].active = YES;

        _select = [CCCheck new];
        _select.onChange = ^(BOOL on) { [weak selectionChanged:on]; };
        _selectLabel = [CCLabel key:@"preview.select" size:13 weight:NSFontWeightRegular role:CCRoleText];
        NSStackView *bottom = CCHStack(@[ _select, _selectLabel, CCSpacer() ], 10);

        // The picture takes all the room between the two lines.
        [bottom.heightAnchor constraintEqualToConstant:26].active = YES;
        [top.heightAnchor constraintEqualToConstant:44].active = YES;
        for (NSView *v in @[ top, stage, bottom ]) [_card addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [top.topAnchor constraintEqualToAnchor:_card.topAnchor constant:18],
            [top.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:22],
            [top.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-22],
            [stage.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:12],
            [stage.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:22],
            [stage.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-22],
            [bottom.topAnchor constraintEqualToAnchor:stage.bottomAnchor constant:12],
            [bottom.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:22],
            [bottom.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-22],
            [bottom.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-16],
        ]];
        [self addSubview:_card];
        CCPin(_card, self, NSEdgeInsetsMake(50, 40, 30, 40));
        [self applyTheme];
    }
    return self;
}

- (BOOL)isOpen { return _open; }
- (CCCatalogNode *)current { return _index < _siblings.count ? _siblings[_index] : nil; }

- (void)applyTheme {
    self.layer.backgroundColor = CCTheme.overlay.CGColor;
    _text.textColor = CCTheme.text;
}

- (void)applyLanguage { if (_open) [self refreshHeader]; }

- (NSView *)hitTest:(NSPoint)point {
    if (self.hidden) return nil;
    return [super hitTest:point] ?: self;
}

- (void)mouseDown:(NSEvent *)event {
    if (!NSPointInRect([_card convertPoint:event.locationInWindow fromView:nil], _card.bounds)) [self hide];
}

- (void)selectionChanged:(BOOL)on {
    CCCatalogNode *node = self.current;
    if (node) [M() setNode:node selected:on];
}

- (void)refreshHeader {
    CCCatalogNode *node = self.current;
    _name.stringValue = node.displayName;
    _place.stringValue = [CCCatalogRelations place:node];
    _count.stringValue = LF(@"preview.count", CCFormatCount((long long)_index + 1), CCFormatCount((long long)_siblings.count));
    _previous.enabled = _index > 0;
    _next.enabled = _index + 1 < _siblings.count;
    _previous.toolTip = L(@"preview.previous");
    _next.toolTip = L(@"preview.next");
    _close.toolTip = L(@"preview.close");
    _select.checked = node.selectedFiles > 0;
    _selectLabel.stringValue = L(node.selectedFiles > 0 ? @"preview.selected" : @"preview.select");
}

- (void)refresh {
    if (_open) [self refreshHeader];
}

- (void)show:(CCCatalogNode *)node {
    NSMutableArray *siblings = [NSMutableArray array];
    for (CCCatalogNode *n in node.parent.children)
        if (!n.isDirectory && [CCLibrary previewOf:n.name] != CCPreviewNone) [siblings addObject:n];
    if (siblings.count == 0) [siblings addObject:node];
    _siblings = siblings;
    _index = [siblings indexOfObject:node];
    if (_index == NSNotFound) _index = 0;
    BOOL wasOpen = _open;
    _open = YES;
    self.hidden = NO;
    [self applyTheme];
    if (!wasOpen && CCMotionEnabled()) {
        CCWithoutAnimation(^{ self.layer.opacity = 0; });
        CCAnimateNumber(self.layer, @"opacity", 1, 200, CCEaseOut, 0);
        CCTransformView(_card, CCXformMake(0.97, 12, 0), 0, nil);
        CCTransformView(_card, CCXformIdentity(), 420, CCEaseSpring);
    }
    [self load];
}

- (void)step:(NSInteger)delta {
    NSInteger to = (NSInteger)_index + delta;
    if (!_open || to < 0 || to >= (NSInteger)_siblings.count) return;
    _index = (NSUInteger)to;
    [self load];
}

- (void)stopLoading {
    _generation++;
    [_task cancel];
    _task = nil;
    [_video.player pause];
    _video.player = nil;
    if (_item) {
        [_item removeObserver:self forKeyPath:@"status" context:kPreviewStatus];
        _item = nil;
    }
    // The last picture goes before the next one comes: at most one is ever held.
    _image.image = nil;
    _text.string = @"";
}

- (void)hide {
    if (!_open) return;
    [self stopLoading];
    _open = NO;
    self.hidden = YES;
    CCWithoutAnimation(^{ self.layer.opacity = 1; });
}

- (void)showBusy:(BOOL)busy message:(NSString *)message {
    _spinner.hidden = !busy;
    _message.hidden = message.length == 0;
    _message.stringValue = message ?: @"";
}

- (void)fail:(NSString *)reason {
    [self showBusy:NO message:LF(@"preview.failed", reason ?: @"")];
    _image.hidden = YES;
    _video.hidden = YES;
    _textScroll.hidden = YES;
}

- (void)load {
    [self stopLoading];
    [self refreshHeader];
    _image.hidden = YES;
    _video.hidden = YES;
    _textScroll.hidden = YES;
    CCCatalogNode *node = self.current;
    if (!node) return;
    if (node.size > 200LL * 1024 * 1024 && [CCLibrary localCopy:node under:M().settings.destination] == nil && M().confirm) {
        [self showBusy:NO message:@""];
        NSInteger generation = _generation;
        M().confirm(L(@"preview.title"), LF(@"preview.tooBig", CCFormatBytes(node.size)), L(@"preview.open"), NO, ^(BOOL ok) {
            if (generation != self->_generation) return;
            if (ok) [self fetch:node];
            else [self hide];
        });
        return;
    }
    [self fetch:node];
}

- (void)fetch:(CCCatalogNode *)node {
    [self showBusy:YES message:L(@"preview.loading")];
    NSString *local = [CCLibrary localCopy:node under:M().settings.destination];
    NSURL *url = local ? [NSURL fileURLWithPath:local] : [CCApiClient downloadURL:node.path];
    switch ([CCLibrary previewOf:node.name]) {
        case CCPreviewVideo: [self playVideo:url streaming:local == nil]; break;
        case CCPreviewText: [self loadText:url]; break;
        case CCPreviewImage: [self loadImage:url]; break;
        case CCPreviewNone: [self fail:@""]; break;
    }
}

- (void)playVideo:(NSURL *)url streaming:(BOOL)streaming {
    [M().player pause];
    NSDictionary *options = streaming ? @{ @"AVURLAssetHTTPHeaderFieldsKey": @{ @"User-Agent": CCApiClient.userAgent } } : @{};
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
    _item = [AVPlayerItem playerItemWithAsset:asset];
    [_item addObserver:self forKeyPath:@"status" options:0 context:kPreviewStatus];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:_item];
    _video.player = player;
    _video.hidden = NO;
    [player play];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kPreviewStatus) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object != self->_item) return;
        if (self->_item.status == AVPlayerItemStatusFailed) [self fail:self->_item.error.localizedDescription];
        else if (self->_item.status == AVPlayerItemStatusReadyToPlay) [self showBusy:NO message:@""];
    });
}

/// Bytes off the main thread; nil data with a reason when they did not come.
- (void)bytes:(NSURL *)url range:(NSString *)range done:(void (^)(NSData *data, NSString *reason))done {
    NSInteger generation = _generation;
    if (url.isFileURL) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSFileHandle *h = [NSFileHandle fileHandleForReadingFromURL:url error:&error];
            NSData *data = range ? [h readDataUpToLength:1 << 20 error:&error] : [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&error];
            [h closeFile];
            done(data, error.localizedDescription);
        });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:CCApiClient.userAgent forHTTPHeaderField:@"User-Agent"];
    if (range) [request setValue:range forHTTPHeaderField:@"Range"];
    _task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error.code == NSURLErrorCancelled || generation != self->_generation) return;
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (!error && (status < 200 || status >= 300)) done(nil, [NSString stringWithFormat:@"HTTP %ld", (long)status]);
        else done(error ? nil : data, error.localizedDescription);
    }];
    [_task resume];
}

- (void)loadImage:(NSURL *)url {
    NSInteger generation = _generation;
    // Decoded to at most what the sheet can show, so a 40-megapixel scan costs what the screen does.
    CGFloat scale = self.window.backingScaleFactor ?: 2;
    CGFloat side = MAX(NSWidth(self.bounds), NSHeight(self.bounds)) * scale;
    [self bytes:url range:nil done:^(NSData *data, NSString *reason) {
        NSImage *image = nil;
        if (data) {
            CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            if (source) {
                NSDictionary *options = @{ (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                           (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                           (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @(side) };
                CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
                if (cg) {
                    image = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(CGImageGetWidth(cg) / scale, CGImageGetHeight(cg) / scale)];
                    CGImageRelease(cg);
                }
                CFRelease(source);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            if (!image) {
                [self fail:reason ?: @"not an image"];
                return;
            }
            [self showBusy:NO message:@""];
            self->_image.image = image;
            self->_image.hidden = NO;
        });
    }];
}

- (void)loadText:(NSURL *)url {
    NSInteger generation = _generation;
    [self bytes:url range:@"bytes=0-1048575" done:^(NSData *data, NSString *reason) {
        NSData *cut = data.length > (1 << 20) ? [data subdataWithRange:NSMakeRange(0, 1 << 20)] : data;
        NSString *text = cut ? ([[NSString alloc] initWithData:cut encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:cut encoding:NSWindowsCP1252StringEncoding]) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            if (!text) {
                [self fail:reason ?: @""];
                return;
            }
            [self showBusy:NO message:@""];
            self->_text.string = text;
            self->_textScroll.hidden = NO;
            [self->_text scrollRangeToVisible:NSMakeRange(0, 0)];
        });
    }];
}

@end

// ═════════════════════════════ the lyrics sheet ═════════════════════════════

@implementation CCLyricsSheet {
    CCBox *_card;
    CCLabel *_title, *_note;
    NSTextView *_text;
    NSScrollView *_scroll;
    BOOL _open;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.hidden = YES;
        _card = [[CCBox alloc] initWithFrame:NSZeroRect];
        _card.radius = 22;
        _card.fill = ^NSColor *{ return CCTheme.cardSolid; };
        _card.stroke = ^NSColor *{ return CCTheme.cardBorder; };
        _card.layer.shadowColor = NSColor.blackColor.CGColor;
        _card.layer.shadowOpacity = 0.5;
        _card.layer.shadowRadius = 28;
        _title = [CCLabel text:@"" size:20 weight:NSFontWeightSemibold role:CCRoleText];
        _note = Muted(@"", 12.5);
        _note.wraps = YES;
        _scroll = [NSTextView scrollableTextView];
        _scroll.translatesAutoresizingMaskIntoConstraints = NO;
        _scroll.drawsBackground = NO;
        _scroll.scrollerStyle = NSScrollerStyleOverlay;
        _scroll.borderType = NSNoBorder;
        _text = _scroll.documentView;
        _text.editable = NO;
        _text.drawsBackground = NO;
        _text.font = CCFont(13.5, NSFontWeightRegular);
        _text.textContainerInset = NSMakeSize(0, 4);
        CCButton *close = [CCButton buttonWithStyle:CCButtonPrimary title:nil symbol:nil];
        close.locKey = @"download.close";
        close.padding = NSEdgeInsetsMake(9, 20, 9, 20);
        close.fontSize = 13.5;
        __weak CCLyricsSheet *weak = self;
        close.onClick = ^{ [weak hide]; };
        NSStackView *buttons = CCHStack(@[ CCSpacer(), close ], 0);
        NSStackView *stack = CCVStack(@[ _title, _note, _scroll, buttons ], 12);
        for (NSView *v in @[ _title, _note, _scroll, buttons ]) Stretch(stack, v);
        [_card addSubview:stack];
        CCPin(stack, _card, NSEdgeInsetsMake(26, 28, 22, 28));
        [self addSubview:_card];
        [NSLayoutConstraint activateConstraints:@[
            [_card.widthAnchor constraintEqualToConstant:560],
            [_card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_card.topAnchor constraintEqualToAnchor:self.topAnchor constant:60],
            [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-40],
        ]];
        [self applyTheme];
    }
    return self;
}

- (BOOL)isOpen { return _open; }

- (void)applyTheme {
    self.layer.backgroundColor = CCTheme.overlay.CGColor;
    _text.textColor = CCTheme.text;
}

- (NSView *)hitTest:(NSPoint)point {
    if (self.hidden) return nil;
    return [super hitTest:point] ?: self;
}

- (void)mouseDown:(NSEvent *)event {
    if (!NSPointInRect([_card convertPoint:event.locationInWindow fromView:nil], _card.bounds)) [self hide];
}

- (void)showProgress:(NSString *)note {
    if (_open) _note.stringValue = note;
}

- (void)showTitle:(NSString *)title note:(NSString *)note words:(NSString *)words {
    BOOL wasOpen = _open;
    _open = YES;
    _title.stringValue = title;
    _note.stringValue = note ?: @"";
    _note.hidden = note.length == 0;
    _text.string = words ?: @"";
    [_text scrollRangeToVisible:NSMakeRange(0, 0)];
    [self applyTheme];
    self.hidden = NO;
    if (wasOpen || !CCMotionEnabled()) return;   // words arriving on an open sheet are not a new sheet
    CCWithoutAnimation(^{ self.layer.opacity = 0; });
    CCAnimateNumber(self.layer, @"opacity", 1, 200, CCEaseOut, 0);
    CCTransformView(_card, CCXformMake(0.96, 14, 0), 0, nil);
    CCTransformView(_card, CCXformIdentity(), 420, CCEaseSpring);
}

- (void)hide {
    [M() lyricsSheetClosed];
    _open = NO;
    self.hidden = YES;
    CCWithoutAnimation(^{ self.layer.opacity = 1; });
}

@end

// ═════════════════════════════ settings ═════════════════════════════

@implementation CCSettingsPage {
    NSMutableArray<NSView *> *_cards;
    CCLabel *_title, *_folderPath;
    CCPopupField *_language, *_parallel;
    NSArray<CCChip *> *_themeChips;
    CCToggle *_animations, *_backdrop, *_confirm, *_refreshOnLaunch;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) [self build];
    return self;
}

- (void)save { [M() saveSettings]; }

- (void)build {
    CCScrollPage *scroll = [CCScrollPage new];
    [self addSubview:scroll];
    CCPin(scroll, self, NSEdgeInsetsMake(0, 0, 0, 0));
    __weak CCSettingsPage *weak = self;

    // ── downloads ──
    _folderPath = [CCLabel text:@"" size:13 weight:NSFontWeightRegular role:CCRoleText];
    _folderPath.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _folderPath.alignment = NSTextAlignmentRight;
    [_folderPath.widthAnchor constraintLessThanOrEqualToConstant:260].active = YES;
    [_folderPath setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    CCButton *change = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:nil];
    change.locKey = @"overview.change";
    change.padding = NSEdgeInsetsMake(8, 12, 8, 12);
    change.fontSize = 12.5;
    change.onClick = ^{ [M() chooseDownloadFolder:weak.window completion:nil]; };
    NSStackView *folderControl = CCHStack(@[ _folderPath, change ], 12);
    _parallel = [CCPopupField new];
    _parallel.items = @[ @"1", @"2", @"4", @"8", @"16", @"32" ];
    _parallel.onSelect = ^(NSInteger index) {
        M().settings.parallel = (NSInteger)1 << index;
        [weak save];
    };
    _confirm = [CCToggle new];
    _confirm.onChange = ^(BOOL on) {
        M().settings.confirmDownloads = on;
        [weak save];
    };
    _refreshOnLaunch = [CCToggle new];
    _refreshOnLaunch.onChange = ^(BOOL on) {
        M().settings.refreshOnLaunch = on;
        [weak save];
    };
    CCSettingRow *refreshRow = [CCSettingRow rowWithSymbol:@"arrow.clockwise" titleKey:@"settings.refreshOnLaunch" descKey:@"settings.refreshOnLaunch.desc" control:_refreshOnLaunch];
    refreshRow.showsDivider = NO;
    NSArray *downloads = @[
        [CCSettingRow rowWithSymbol:@"folder" titleKey:@"settings.folder" descKey:@"settings.folder.desc" control:folderControl],
        [CCSettingRow rowWithSymbol:@"arrow.down.circle" titleKey:@"settings.parallel" descKey:@"settings.parallel.desc" control:_parallel],
        [CCSettingRow rowWithSymbol:@"checkmark.circle" titleKey:@"settings.confirm" descKey:@"settings.confirm.desc" control:_confirm],
        refreshRow,
    ];
    CCCard *downloadsCard = [self sectionCard:@"settings.downloads" rows:downloads padding:NSEdgeInsetsMake(18, 24, 10, 24)];

    // ── general ──
    _language = [CCPopupField new];
    _language.onSelect = ^(NSInteger index) {
        NSString *code = index == 0 ? @"auto" : CCLocalization.languages[(NSUInteger)index - 1].code;
        M().settings.language = code;
        [weak save];
        [CCLocalization.shared setLanguage:code];
    };
    NSMutableArray *themeChips = [NSMutableArray array];
    for (NSString *mode in @[ @"dark", @"light", @"system" ]) {
        CCChip *chip = [CCChip chipWithTitle:@""];
        chip.locKey = [@"settings.theme." stringByAppendingString:mode];
        chip.onClick = ^{
            M().settings.theme = mode;
            [weak save];
            [CCTheme applyMode:mode];
            [weak refresh];
        };
        [themeChips addObject:chip];
    }
    _themeChips = themeChips;
    _animations = [CCToggle new];
    _animations.onChange = ^(BOOL on) {
        M().settings.animations = on;
        CCSetMotionEnabled(on);
        [weak save];
    };
    _backdrop = [CCToggle new];
    _backdrop.onChange = ^(BOOL on) {
        M().settings.backdrop = on;
        [weak save];
        if (weak.applyAppearance) weak.applyAppearance();
    };
    CCButton *reset = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:nil];
    reset.locKey = @"settings.reset.button";
    reset.onClick = ^{ [weak reset]; };
    CCSettingRow *resetRow = [CCSettingRow rowWithSymbol:@"arrow.counterclockwise" titleKey:@"settings.reset" descKey:@"settings.reset.desc" control:reset];
    resetRow.showsDivider = NO;
    NSArray *general = @[
        [CCSettingRow rowWithSymbol:@"paintpalette" titleKey:@"settings.theme" descKey:@"settings.theme.desc" control:CCHStack(themeChips, 8)],
        [CCSettingRow rowWithSymbol:@"globe" titleKey:@"settings.language" descKey:@"settings.language.desc" control:_language],
        [CCSettingRow rowWithSymbol:@"bolt" titleKey:@"settings.animations" descKey:@"settings.animations.desc" control:_animations],
        [CCSettingRow rowWithSymbol:@"square.on.square" titleKey:@"settings.backdrop" descKey:@"settings.backdrop.desc" control:_backdrop],
        resetRow,
    ];
    CCCard *generalCard = [self sectionCard:@"settings.general" rows:general padding:NSEdgeInsetsMake(18, 24, 10, 24)];

    _title = H1(@"settings.title");
    _cards = [@[ downloadsCard, generalCard ] mutableCopy];
    NSStackView *page = CCVStack(@[ _title, downloadsCard, generalCard ], 16);
    [page setCustomSpacing:20 afterView:_title];
    for (NSView *card in _cards) Stretch(page, card);
    NSView *doc = scroll.document;
    [doc addSubview:page];
    // See the overview: bounded by the window, filling it below the window's own size priority.
    [page.trailingAnchor constraintLessThanOrEqualToAnchor:doc.trailingAnchor constant:-32].active = YES;
    NSLayoutConstraint *fill = [page.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor constant:-32];
    fill.priority = NSLayoutPriorityWindowSizeStayPut - 1;
    [NSLayoutConstraint activateConstraints:@[
        [page.topAnchor constraintEqualToAnchor:doc.topAnchor constant:6],
        [page.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor constant:32],
        [page.widthAnchor constraintLessThanOrEqualToConstant:960],
        [doc.bottomAnchor constraintEqualToAnchor:page.bottomAnchor constant:28],
        fill,
    ]];
}

- (CCCard *)sectionCard:(NSString *)titleKey rows:(NSArray<NSView *> *)rows padding:(NSEdgeInsets)padding {
    CCLabel *title = H2(titleKey);
    NSStackView *stack = CCVStack([@[ title ] arrayByAddingObjectsFromArray:rows], 0);
    [stack setCustomSpacing:4 afterView:title];
    for (NSView *row in rows) Stretch(stack, row);
    return Card(stack, padding);
}

- (void)reset {
    [M() resetSettings];
    CCSettings *s = M().settings;
    [CCTheme applyMode:s.theme];
    CCSetMotionEnabled(s.animations);
    [CCLocalization.shared setLanguage:s.language];
    if (self.applyAppearance) self.applyAppearance();
    [self refresh];
}

- (void)refresh {
    CCSettings *s = M().settings;
    NSMutableArray *items = [NSMutableArray array];
    NSString *systemCode = [CCLocalization systemLanguageCode];
    NSString *systemName = systemCode;
    for (CCLanguage *l in CCLocalization.languages)
        if ([l.code isEqualToString:systemCode]) systemName = l.nativeName;
    [items addObject:LF(@"settings.language.auto", systemName)];
    NSInteger selected = 0;
    for (NSUInteger i = 0; i < CCLocalization.languages.count; i++) {
        CCLanguage *l = CCLocalization.languages[i];
        [items addObject:l.nativeName];
        if ([s.language isEqualToString:l.code]) selected = (NSInteger)i + 1;
    }
    _language.items = items;
    _language.selectedIndex = selected;
    // A value the list does not hold (from an older file) becomes the next choice up, so the list says what really happens.
    NSInteger parallelIndex = 0;
    while (parallelIndex < 5 && ((NSInteger)1 << parallelIndex) < s.parallel) parallelIndex++;
    s.parallel = (NSInteger)1 << parallelIndex;
    _parallel.selectedIndex = parallelIndex;
    _folderPath.stringValue = s.destination;
    _folderPath.toolTip = s.destination;

    NSArray *modes = @[ @"dark", @"light", @"system" ];
    for (NSUInteger i = 0; i < 3; i++) _themeChips[i].checked = [s.theme isEqualToString:modes[i]];
    BOOL animated = self.window != nil;
    if (_animations.on != s.animations) [_animations setOn:s.animations animated:animated];
    if (_backdrop.on != s.backdrop) [_backdrop setOn:s.backdrop animated:animated];
    if (_confirm.on != s.confirmDownloads) [_confirm setOn:s.confirmDownloads animated:animated];
    if (_refreshOnLaunch.on != s.refreshOnLaunch) [_refreshOnLaunch setOn:s.refreshOnLaunch animated:animated];
}

- (void)playEntrance {
    [super playEntrance];
    CCEntrance(_title, 0, 18);
    for (NSUInteger i = 0; i < _cards.count; i++) CCEntrance(_cards[i], 60 * (i + 1), 18);
}

@end

// ═════════════════════════════ about ═════════════════════════════

@implementation CCAboutPage {
    NSArray<NSView *> *_sections;
    CCLabel *_version;
    CCSettingRow *_filesRow, *_lyricsRow, *_downloadsRow, *_dataRow;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) [self build];
    return self;
}

static CCButton *AboutButton(NSString *key, void (^action)(void)) {
    CCButton *button = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:nil];
    button.locKey = key;
    button.padding = NSEdgeInsetsMake(8, 14, 8, 14);
    button.fontSize = 12.5;
    button.onClick = action;
    return button;
}

static void AboutOpenFolder(NSString *folder) {
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:folder]];
}

static CCCard *AboutCard(NSString *titleKey, NSArray<CCSettingRow *> *rows) {
    CCLabel *title = H2(titleKey);
    rows.lastObject.showsDivider = NO;
    NSStackView *stack = CCVStack([@[ title ] arrayByAddingObjectsFromArray:rows], 0);
    [stack setCustomSpacing:4 afterView:title];
    for (NSView *row in rows) Stretch(stack, row);
    return Card(stack, NSEdgeInsetsMake(18, 24, 10, 24));
}

- (void)build {
    CCScrollPage *scroll = [CCScrollPage new];
    [self addSubview:scroll];
    CCPin(scroll, self, NSEdgeInsetsMake(0, 0, 0, 0));

    NSView *logoHost = CCAuto([CCFlippedView new]);
    logoHost.wantsLayer = YES;
    logoHost.layerUsesCoreImageFilters = YES;
    CCSize(logoHost, 84, 84);
    CCBox *glow = [[CCBox alloc] initWithFrame:NSZeroRect];
    glow.radius = 24;
    glow.gradient = ^NSArray<NSColor *> *{ return CCTheme.accentGradient; };
    glow.alphaValue = 0.55;
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:@14 forKey:kCIInputRadiusKey];
    glow.contentFilters = @[ blur ];
    CCLogoView *logo = CCAuto([CCLogoView new]);
    [logoHost addSubview:glow];
    [logoHost addSubview:logo];
    CCPin(glow, logoHost, NSEdgeInsetsMake(10, 4, -2, 4));
    CCPin(logo, logoHost, NSEdgeInsetsMake(0, 0, 0, 0));

    CCLabel *name = [CCLabel key:@"app.name" size:28 weight:NSFontWeightBold role:CCRoleText];
    _version = [CCLabel text:@"" size:12 weight:NSFontWeightSemibold role:CCRoleAccent];
    CCBox *versionPill = [[CCBox alloc] initWithFrame:NSZeroRect];
    versionPill.radius = 999;
    versionPill.fill = ^NSColor *{ return CCTheme.accentSoft; };
    [versionPill addSubview:_version];
    CCPin(_version, versionPill, NSEdgeInsetsMake(4, 12, 4, 12));
    NSStackView *nameRow = CCHStack(@[ name, versionPill, CCSpacer() ], 12);
    CCLabel *tagline = [CCLabel key:@"app.tagline" size:14 weight:NSFontWeightMedium role:CCRoleText];
    CCLabel *description = [CCLabel key:@"about.description" size:13 weight:NSFontWeightRegular role:CCRoleMuted];
    description.wraps = YES;
    description.lineHeight = 21;

    CCButton *github = [CCButton buttonWithStyle:CCButtonPrimary title:nil symbol:@"chevron.left.forwardslash.chevron.right"];
    github.locKey = @"about.github";
    github.symbolSize = 14;
    github.onClick = ^{ [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/Kreal-exe/JuiceDownloader"]]; };
    CCButton *issues = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:nil];
    issues.locKey = @"about.issues";
    issues.padding = NSEdgeInsetsMake(12, 18, 12, 18);
    issues.onClick = ^{ [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/Kreal-exe/JuiceDownloader/issues"]]; };
    NSStackView *buttons = CCHStack(@[ github, issues, CCSpacer() ], 12);

    NSStackView *heroText = CCVStack(@[ nameRow, tagline, description, buttons ], 8);
    [heroText setCustomSpacing:16 afterView:description];
    for (NSView *v in @[ nameRow, description, buttons ]) Stretch(heroText, v);
    NSStackView *heroRow = CCHStack(@[ logoHost, heroText ], 26);
    heroRow.alignment = NSLayoutAttributeTop;
    CCCard *heroCard = Card(heroRow, NSEdgeInsetsMake(28, 30, 28, 30));

    _filesRow = [CCSettingRow rowWithSymbol:@"music.note.list" titleKey:@"about.catalog.files" descKey:nil control:nil];
    _lyricsRow = [CCSettingRow rowWithSymbol:@"text.quote" titleKey:@"lyrics.title" descKey:nil control:nil];
    CCCard *catalogCard = AboutCard(@"about.catalog", @[ _filesRow, _lyricsRow ]);

    _downloadsRow = [CCSettingRow rowWithSymbol:@"folder" titleKey:@"settings.folder" descKey:nil control:AboutButton(@"about.open", ^{ AboutOpenFolder(M().settings.destination); })];
    _dataRow = [CCSettingRow rowWithSymbol:@"gearshape" titleKey:@"about.files.data" descKey:nil control:AboutButton(@"about.open", ^{ AboutOpenFolder([CCSettings filePath].stringByDeletingLastPathComponent); })];
    CCCard *filesCard = AboutCard(@"about.files", @[ _downloadsRow, _dataRow ]);

    CCSettingRow *source = [CCSettingRow rowWithSymbol:@"music.note.house" titleKey:@"about.source" descKey:@"about.source.desc" control:AboutButton(@"about.source.open", ^{
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://juicewrldapi.com"]];
    })];
    CCSettingRow *web = [CCSettingRow rowWithSymbol:@"globe" titleKey:@"about.web" descKey:@"about.web.desc" control:nil];
    CCCard *sourcesCard = AboutCard(@"about.sources", @[ source, web ]);

    CCLabel *footer = [CCLabel key:@"about.footer" size:11.5 weight:NSFontWeightRegular role:CCRoleFaint];
    footer.wraps = YES;
    footer.alignment = NSTextAlignmentCenter;
    footer.lineHeight = 18;

    NSArray *cards = @[ heroCard, catalogCard, filesCard, sourcesCard ];
    NSStackView *page = CCVStack([cards arrayByAddingObject:footer], 12);
    page.alignment = NSLayoutAttributeCenterX;
    [page setCustomSpacing:18 afterView:sourcesCard];
    for (NSView *v in cards) Stretch(page, v);
    Stretch(page, footer);
    _sections = @[ heroCard, catalogCard, filesCard, sourcesCard, footer ];
    NSView *doc = scroll.document;
    [doc addSubview:page];
    // Never wider than the window allows; as wide as it allows below the window's own size priority, so the page
    // follows the window instead of holding it (hidden pages keep their constraints too).
    [page.widthAnchor constraintLessThanOrEqualToAnchor:doc.widthAnchor constant:-64].active = YES;
    NSLayoutConstraint *fill = [page.widthAnchor constraintEqualToAnchor:doc.widthAnchor constant:-64];
    fill.priority = NSLayoutPriorityWindowSizeStayPut - 1;
    [NSLayoutConstraint activateConstraints:@[
        [page.topAnchor constraintEqualToAnchor:doc.topAnchor constant:6],
        [doc.bottomAnchor constraintEqualToAnchor:page.bottomAnchor constant:28],
        [page.centerXAnchor constraintEqualToAnchor:doc.centerXAnchor],
        [page.widthAnchor constraintLessThanOrEqualToConstant:820],
        fill,
    ]];
}

- (void)refresh {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0.0";
    _version.stringValue = LF(@"about.version", version);
    CCCatalog *catalog = M().catalog;
    _filesRow.descLabel.stringValue = catalog ? LF(@"overview.catalogLine", CCFormatCount(catalog.totalFiles), CCFormatBytes(catalog.totalBytes)) : L(@"catalog.loading");
    CCLyricsIndex *lyrics = M().library.lyrics;
    _lyricsRow.descLabel.stringValue = lyrics ? LF(@"lyrics.stats", CCFormatCount(lyrics.songCount), CCFormatCount(lyrics.withLyrics)) : L(@"lyrics.notLoaded");
    _downloadsRow.descLabel.stringValue = M().settings.destination;
    _dataRow.descLabel.stringValue = [CCSettings filePath].stringByDeletingLastPathComponent;
}

- (void)playEntrance {
    [super playEntrance];
    NSArray *delays = @[ @0, @80, @140, @200, @260 ];
    for (NSUInteger i = 0; i < _sections.count; i++) CCEntrance(_sections[i], [delays[i] doubleValue], 18);
}

@end

// ═════════════════════════════ overlays ═════════════════════════════

@implementation CCDownloadOverlay {
    CCBox *_card;
    CALayer *_confetti;
    CCIconTile *_doneTile;
    NSView *_busyTile;
    CCLabel *_title, *_percent, *_percentUnit, *_bytesLine, *_filesLine, *_speedLine, *_remainingLine, *_activeLine, *_summary, *_failuresTitle;
    CCRing *_ring;
    NSStackView *_details;
    CCLineList *_failures;
    CCButton *_close, *_stop, *_showFolder, *_retry;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.hidden = YES;
        [self build];
    }
    return self;
}

- (void)build {
    _confetti = [CALayer layer];
    [self.layer addSublayer:_confetti];

    _card = [[CCBox alloc] initWithFrame:NSZeroRect];
    _card.radius = 24;
    _card.fill = ^NSColor *{ return CCTheme.cardSolid; };
    _card.stroke = ^NSColor *{ return CCTheme.cardBorder; };
    _card.layer.shadowColor = NSColor.blackColor.CGColor;
    _card.layer.shadowOpacity = 0.5;
    _card.layer.shadowRadius = 28;

    _busyTile = [CCIconTile tileWithSymbol:@"circle" size:44 radius:14 iconSize:1];
    ((CCIconTile *)_busyTile).icon.hidden = YES;
    ((CCIconTile *)_busyTile).fill = ^NSColor *{ return CCTheme.accentSoft; };
    CCSpinner *spinner = [[CCSpinner alloc] initWithDiameter:22 lineWidth:3 sweep:270 period:0.9];
    [_busyTile addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:_busyTile.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:_busyTile.centerYAnchor],
    ]];
    _doneTile = [CCIconTile tileWithSymbol:@"checkmark" size:44 radius:14 iconSize:18];
    _doneTile.icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightBold];
    _doneTile.fill = ^NSColor *{ return CCTheme.successSoft; };
    _doneTile.icon.role = CCRoleSuccess;

    _title = [CCLabel text:@"" size:22 weight:NSFontWeightSemibold role:CCRoleText];
    NSStackView *header = CCHStack(@[ _busyTile, _doneTile, _title ], 16);

    _ring = [CCRing new];
    _percent = [CCLabel text:@"0" size:42 weight:NSFontWeightBold role:CCRoleText];
    _percent.font = CCDigitsFont(42, NSFontWeightBold);
    _percentUnit = [CCLabel text:@"%" size:15 weight:NSFontWeightSemibold role:CCRoleMuted];
    NSStackView *percent = CCHStack(@[ _percent, _percentUnit ], 3);
    percent.alignment = NSLayoutAttributeLastBaseline;
    [_ring addSubview:percent];
    [NSLayoutConstraint activateConstraints:@[
        [percent.centerXAnchor constraintEqualToAnchor:_ring.centerXAnchor],
        [percent.centerYAnchor constraintEqualToAnchor:_ring.centerYAnchor],
    ]];

    _bytesLine = [CCLabel text:@"" size:17 weight:NSFontWeightSemibold role:CCRoleText];
    _bytesLine.font = CCDigitsFont(17, NSFontWeightSemibold);
    _filesLine = Muted(@"", 13);
    _speedLine = Muted(@"", 13);
    _remainingLine = Muted(@"", 13);
    _activeLine = Caption(@"");
    _activeLine.wraps = YES;
    _activeLine.maximumNumberOfLines = 4;
    _activeLine.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _details = CCVStack(@[ _bytesLine, _filesLine, _speedLine, _remainingLine, _activeLine ], 4);
    [_details setCustomSpacing:12 afterView:_remainingLine];
    Stretch(_details, _activeLine);
    NSStackView *body = CCHStack(@[ _ring, _details ], 24);
    [_details setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    _summary = Muted(@"", 13);
    _summary.wraps = YES;
    _failuresTitle = [CCLabel key:@"download.failures" size:11.5 weight:NSFontWeightSemibold role:CCRoleFaint];
    _failures = [CCLineList new];

    _close = [CCButton buttonWithStyle:CCButtonPrimary title:nil symbol:nil];
    _close.locKey = @"download.close";
    [_close.widthAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
    _close.onClick = ^{ [M() closeOverlay]; };
    _retry = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:@"arrow.clockwise"];
    _retry.locKey = @"download.retry";
    _retry.padding = NSEdgeInsetsMake(11, 14, 11, 14);
    _retry.fontSize = 13;
    _retry.onClick = ^{ [M() retryFailed]; };
    _showFolder = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:@"folder"];
    _showFolder.locKey = @"download.showFolder";
    _showFolder.padding = NSEdgeInsetsMake(11, 14, 11, 14);
    _showFolder.fontSize = 13;
    _showFolder.onClick = ^{ [M() showDownloadFolder]; };
    _stop = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:@"stop"];
    _stop.padding = NSEdgeInsetsMake(11, 18, 11, 18);
    [_stop.widthAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
    _stop.onClick = ^{ [M() stopDownload]; };
    NSStackView *buttons = CCHStack(@[ CCSpacer(), _stop, _showFolder, _retry, _close ], 10);

    NSStackView *stack = CCVStack(@[ header, body, _summary, _failuresTitle, _failures.view, buttons ], 0);
    [stack setCustomSpacing:22 afterView:header];
    [stack setCustomSpacing:18 afterView:body];
    [stack setCustomSpacing:14 afterView:_summary];
    [stack setCustomSpacing:6 afterView:_failuresTitle];
    [stack setCustomSpacing:20 afterView:_failures.view];
    for (NSView *v in @[ body, _summary, _failures.view ]) Stretch(stack, v);
    [buttons.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor].active = YES;
    [_card addSubview:stack];
    CCPin(stack, _card, NSEdgeInsetsMake(32, 36, 32, 36));
    [self addSubview:_card];
    [NSLayoutConstraint activateConstraints:@[
        [_card.widthAnchor constraintEqualToConstant:600],
        [_card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_card.heightAnchor constraintLessThanOrEqualToAnchor:self.heightAnchor constant:-32],
    ]];
    [self applyTheme];
}

- (void)applyTheme { self.layer.backgroundColor = CCTheme.overlay.CGColor; }
- (void)applyLanguage { [self refresh]; }

- (NSView *)hitTest:(NSPoint)point {
    if (self.hidden) return nil;
    NSView *hit = [super hitTest:point];
    return hit ?: self;
}

- (void)mouseDown:(NSEvent *)event {}

- (void)layout {
    [super layout];
    CCWithoutAnimation(^{ self->_confetti.frame = self.layer.bounds; });
}

- (void)refresh {
    CCModel *m = M();
    CCDownloadReport *report = m.report;
    CCDownloadProgress *p = m.progress;
    BOOL over = report != nil;
    BOOL lyrics = m.gettingLyrics;
    _busyTile.hidden = over;
    _doneTile.hidden = !over;
    _title.stringValue = over ? L(report.stopped ? @"download.stoppedTitle" : @"download.doneTitle")
                              : L(lyrics ? @"download.gettingLyrics" : @"download.title");
    double fraction = p.fraction;
    if (lyrics) fraction = 0;
    [_ring setAngle:fraction * 360 animated:!over || !report.stopped];
    _ring.spinning = lyrics;
    _percent.stringValue = [NSString stringWithFormat:@"%.0f", floor(fraction * 100)];
    _bytesLine.stringValue = LF(@"download.progress", CCFormatBytes(p.doneBytes), CCFormatBytes(p.totalBytes));
    _filesLine.stringValue = LF(@"download.files", CCFormatCount(p.finished), CCFormatCount(p.totalFiles));
    BOOL moving = !over && p.bytesPerSecond > 1;
    _speedLine.stringValue = moving ? LF(@"download.speed", CCFormatBytes(p.bytesPerSecond)) : @"";
    _speedLine.hidden = !moving;
    long long left = p.totalBytes - p.doneBytes;
    _remainingLine.stringValue = moving && left > 0 ? LF(@"download.remaining", CCFormatDuration(left / p.bytesPerSecond)) : @"";
    _remainingLine.hidden = !moving || left <= 0;
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *path in p.active) [names addObject:path.lastPathComponent];
    _activeLine.stringValue = [names componentsJoinedByString:@"\n"];
    _activeLine.hidden = over || names.count == 0;

    NSMutableArray *summary = [NSMutableArray array];
    if (report) {
        if (report.stopped) [summary addObject:L(@"download.stoppedBody")];
        [summary addObject:LF(@"download.summary", CCFormatCount(report.downloaded), CCFormatCount(report.alreadyThere), CCFormatCount(report.failures.count))];
    }
    _summary.stringValue = [summary componentsJoinedByString:@" "];
    if (m.lastRunHadLyrics) {
        CCLibrary *library = m.library;
        _summary.stringValue = [NSString stringWithFormat:@"%@\n%@", _summary.stringValue,
                                LF(@"download.lyricsSummary", CCFormatCount(library.lastLyricsSame), CCFormatCount(library.lastLyricsOther), CCFormatCount(library.lastLyricsNone))];
    }
    _summary.hidden = !over;

    BOOL failed = report.failures.count > 0;
    _failuresTitle.hidden = !failed;
    _failures.view.hidden = !failed;
    NSMutableArray *lines = [NSMutableArray array];
    for (CCDownloadFailure *f in report.failures) [lines addObject:[NSString stringWithFormat:@"%@ · %@", f.apiPath.lastPathComponent, f.reason]];
    if (![_failures.lines isEqualToArray:lines]) _failures.lines = lines;

    _close.hidden = !over;
    _showFolder.hidden = !over;
    _retry.hidden = !failed;
    _stop.hidden = over;
    _stop.enabled = !m.stopping;
    NSString *stopKey = m.stopping ? @"download.stopping" : @"download.stop";
    if (![_stop.locKey isEqualToString:stopKey]) _stop.locKey = stopKey;
}

- (void)show {
    self.hidden = NO;
    for (CALayer *l in [_confetti.sublayers copy]) [l removeFromSuperlayer];
    [self refresh];
    if (!CCMotionEnabled()) return;
    CCWithoutAnimation(^{ self.layer.opacity = 0; });
    CCAnimateNumber(self.layer, @"opacity", 1, 220, CCEaseOut, 0);
    CCTransformView(_card, CCXformMake(0.92, 24, 0), 0, nil);
    CCTransformView(_card, CCXformIdentity(), 480, CCEaseSpring);
}

- (void)hide {
    if (!CCMotionEnabled()) {
        self.hidden = YES;
        return;
    }
    CCAnimateNumber(self.layer, @"opacity", 0, 180, CCEaseIn, 0);
    CCTransformView(_card, CCXformMake(0.96, 0, 0), 180, CCEaseIn);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.19 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (M().overlayVisible) return;
        self.hidden = YES;
        CCWithoutAnimation(^{ self.layer.opacity = 1; });
        CCTransformView(self->_card, CCXformIdentity(), 0, nil);
        for (CALayer *l in [self->_confetti.sublayers copy]) [l removeFromSuperlayer];
    });
}

/// A confetti burst from above the card (CleanOverlay.xaml.cs).
- (void)celebrate {
    if (!CCMotionEnabled() || self.hidden) return;
    CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    if (w <= 0 || h <= 0) return;
    BOOL down = CCLayerYDown(self.layer);
    CGFloat (^Y)(CGFloat) = ^CGFloat(CGFloat y) { return down ? y : h - y; };
    NSArray *palette = @[ CCHex(0x7C6CFF, 1), CCHex(0x22D3EE, 1), CCHex(0xF472B6, 1), CCHex(0x34D399, 1), CCHex(0xFBBF24, 1), CCHex(0x60A5FA, 1) ];
    CGFloat originX = w / 2, originY = h / 2 - 160;
    double now = CACurrentMediaTime();

    for (int i = 0; i < 90; i++) {
        NSColor *color = palette[arc4random_uniform((uint32_t)palette.count)];
        CGFloat size = 6 + drand48() * 6;
        CALayer *piece = [CALayer layer];
        BOOL round = arc4random_uniform(3) == 0;
        piece.bounds = CGRectMake(0, 0, size, round ? size : size * 1.6);
        piece.cornerRadius = round ? size / 2 : 2;
        piece.backgroundColor = color.CGColor;
        piece.position = CGPointMake(originX, Y(h + 60));
        [_confetti addSublayer:piece];

        double spread = (drand48() - 0.5) * 2;
        double dx = spread * (260 + drand48() * 260);
        double peak = originY - (120 + drand48() * 260);
        double seconds = (1500 + arc4random_uniform(900)) / 1000.0;
        double startAngle = drand48() * 2 * M_PI;
        double spin = (drand48() - 0.5) * 6 * M_PI;

        NSUInteger n = (NSUInteger)(seconds * 60);
        NSMutableArray *positions = [NSMutableArray array], *angles = [NSMutableArray array], *alphas = [NSMutableArray array];
        for (NSUInteger k = 0; k <= n; k++) {
            double t = (double)k / n;
            double x = originX + dx * CCEaseCubicOut(t);
            double y = t < 0.32 ? originY + (peak - originY) * CCEaseCubicOut(t / 0.32)
                                : peak + (h + 40 - peak) * pow((t - 0.32) / 0.68, 2);
            [positions addObject:[NSValue valueWithPoint:NSMakePoint(x, Y(y))]];
            [angles addObject:@(startAngle + spin * t)];
            [alphas addObject:@(t < 0.65 ? 1 : 1 - (t - 0.65) / 0.35)];
        }
        CAKeyframeAnimation *move = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        move.values = positions;
        CAKeyframeAnimation *rotate = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        rotate.values = angles;
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = alphas;
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = @[ move, rotate, fade ];
        group.duration = seconds;
        group.beginTime = now;
        group.fillMode = kCAFillModeBoth;
        group.removedOnCompletion = NO;
        [piece addAnimation:group forKey:@"fly"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((seconds + 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [piece removeFromSuperlayer];
        });
    }
}

@end

@implementation CCConfirmDialog {
    CCBox *_card;
    CCIconTile *_tile;
    CCLabel *_title, *_body;
    CCButton *_cancel, *_okPrimary, *_okDanger;
    void (^_answer)(BOOL);
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.hidden = YES;
        _card = [[CCBox alloc] initWithFrame:NSZeroRect];
        _card.radius = 22;
        _card.fill = ^NSColor *{ return CCTheme.cardSolid; };
        _card.stroke = ^NSColor *{ return CCTheme.cardBorder; };
        _card.layer.shadowColor = NSColor.blackColor.CGColor;
        _card.layer.shadowOpacity = 0.5;
        _card.layer.shadowRadius = 28;
        _tile = [CCIconTile tileWithSymbol:@"arrow.down" size:48 radius:15 iconSize:20];
        _title = [CCLabel text:@"" size:22 weight:NSFontWeightSemibold role:CCRoleText];
        _title.wraps = YES;
        _body = Muted(@"", 13);
        _body.wraps = YES;
        _body.lineHeight = 21;
        _cancel = [CCButton buttonWithStyle:CCButtonGhost title:nil symbol:nil];
        _cancel.locKey = @"common.cancel";
        _cancel.padding = NSEdgeInsetsMake(11, 18, 11, 18);
        [_cancel.widthAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
        _okPrimary = [CCButton buttonWithStyle:CCButtonPrimary title:@"" symbol:nil];
        _okDanger = [CCButton buttonWithStyle:CCButtonDanger title:@"" symbol:nil];
        for (CCButton *b in @[ _okPrimary, _okDanger ]) [b.widthAnchor constraintGreaterThanOrEqualToConstant:130].active = YES;
        __weak CCConfirmDialog *weak = self;
        _cancel.onClick = ^{ [weak closeWith:NO]; };
        _okPrimary.onClick = ^{ [weak closeWith:YES]; };
        _okDanger.onClick = ^{ [weak closeWith:YES]; };
        NSStackView *buttons = CCHStack(@[ CCSpacer(), _cancel, _okPrimary, _okDanger ], 12);
        NSStackView *stack = CCVStack(@[ _tile, _title, _body, buttons ], 0);
        [stack setCustomSpacing:18 afterView:_tile];
        [stack setCustomSpacing:10 afterView:_title];
        [stack setCustomSpacing:28 afterView:_body];
        Stretch(stack, _title);
        Stretch(stack, _body);
        [buttons.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor].active = YES;
        [_card addSubview:stack];
        CCPin(stack, _card, NSEdgeInsetsMake(30, 32, 30, 32));
        [self addSubview:_card];
        [NSLayoutConstraint activateConstraints:@[
            [_card.widthAnchor constraintEqualToConstant:500],
            [_card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
        [self applyTheme];
    }
    return self;
}

- (BOOL)isOpen { return _answer != nil; }

- (void)applyTheme { self.layer.backgroundColor = CCTheme.overlay.CGColor; }

- (NSView *)hitTest:(NSPoint)point {
    if (self.hidden) return nil;
    return [super hitTest:point] ?: self;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [_card convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(p, _card.bounds)) [self closeWith:NO];
}

- (void)showTitle:(NSString *)title body:(NSString *)body ok:(NSString *)okText danger:(BOOL)danger answer:(void (^)(BOOL))answer {
    if (_answer) _answer(NO);
    _answer = [answer copy];
    _title.stringValue = title;
    _body.stringValue = body;
    _okPrimary.title = okText;
    _okDanger.title = okText;
    _okPrimary.hidden = danger;
    _okDanger.hidden = !danger;
    _cancel.hidden = [okText isEqualToString:L(@"common.ok")];
    _tile.fill = ^NSColor *{ return danger ? CCTheme.dangerSoft : CCTheme.accentSoft; };
    _tile.icon.role = danger ? CCRoleDanger : CCRoleAccent;
    _tile.icon.symbol = danger ? @"exclamationmark.triangle" : [okText isEqualToString:L(@"common.ok")] ? @"info.circle" : @"arrow.down";
    self.hidden = NO;
    [self.window makeFirstResponder:self];
    if (!CCMotionEnabled()) return;
    CCWithoutAnimation(^{ self.layer.opacity = 0; });
    CCAnimateNumber(self.layer, @"opacity", 1, 200, CCEaseOut, 0);
    CCTransformView(_card, CCXformMake(0.94, 18, 0), 0, nil);
    CCTransformView(_card, CCXformIdentity(), 420, CCEaseSpring);
}

- (void)closeWith:(BOOL)result {
    void (^answer)(BOOL) = _answer;
    _answer = nil;
    if (!CCMotionEnabled()) {
        self.hidden = YES;
    } else {
        CCAnimateNumber(self.layer, @"opacity", 0, 160, CCEaseIn, 0);
        CCTransformView(_card, CCXformMake(0.96, 0, 0), 160, CCEaseIn);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.17 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_answer) return;
            self.hidden = YES;
            CCWithoutAnimation(^{ self.layer.opacity = 1; });
        });
    }
    if (answer) answer(result);
}

- (BOOL)acceptsFirstResponder { return !self.hidden; }

- (void)keyDown:(NSEvent *)event {
    if (!_answer) return [super keyDown:event];
    if (event.keyCode == 53) [self closeWith:NO];                              // Esc
    else if (event.keyCode == 36 || event.keyCode == 76) [self closeWith:YES]; // Return, Enter
    else [super keyDown:event];
}

@end

@implementation CCToast {
    CCIconTile *_tile;
    CCLabel *_text;
    NSTimer *_timer;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.radius = 14;
        self.fill = ^NSColor *{ return CCTheme.popup; };
        self.stroke = ^NSColor *{ return CCTheme.cardBorder; };
        self.layer.shadowColor = NSColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 14;
        self.hidden = YES;
        _tile = [CCIconTile tileWithSymbol:@"checkmark" size:30 radius:9 iconSize:13];
        _tile.fill = ^NSColor *{ return CCTheme.successSoft; };
        _tile.icon.role = CCRoleSuccess;
        _text = [CCLabel text:@"" size:13.5 weight:NSFontWeightSemibold role:CCRoleText];
        _text.wraps = YES;
        _text.wrapLimit = 420;
        NSStackView *row = CCHStack(@[ _tile, _text ], 12);
        [self addSubview:row];
        CCPin(row, self, NSEdgeInsetsMake(12, 16, 12, 20));
    }
    return self;
}

- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)showSymbol:(NSString *)symbol text:(NSString *)text {
    _tile.icon.symbol = symbol;
    _text.stringValue = text;
    self.hidden = NO;
    if (CCMotionEnabled()) {
        CCWithoutAnimation(^{ self.layer.opacity = 0; });
        CCAnimateNumber(self.layer, @"opacity", 1, 220, CCEaseOut, 0);
        CCTransformView(self, CCXformMake(1, -16, 0), 0, nil);
        CCTransformView(self, CCXformIdentity(), 480, CCEaseSpring);
    }
    [_timer invalidate];
    __weak CCToast *weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:3.2 repeats:NO block:^(NSTimer *t) { [weak dismiss]; }];
}

- (void)dismiss {
    if (!CCMotionEnabled()) {
        self.hidden = YES;
        return;
    }
    CCAnimateNumber(self.layer, @"opacity", 0, 240, CCEaseIn, 0);
    CCTransformView(self, CCXformMake(1, -10, 0), 240, CCEaseIn);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.layer.opacity < 0.01) self.hidden = YES;
    });
}

@end
