#import "CCCatalog.h"

static NSString *const kFallbackSection = @"media";

@implementation CCApiItem

+ (instancetype)path:(NSString *)path type:(NSString *)type size:(long long)size {
    CCApiItem *item = [CCApiItem new];
    item.path = path;
    item.type = type;
    item.size = size;
    return item;
}

+ (instancetype)fromJSON:(id)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    id path = json[@"path"], type = json[@"type"], size = json[@"size"];
    return [self path:[path isKindOfClass:NSString.class] ? path : nil
                 type:[type isKindOfClass:NSString.class] ? type : nil
                 size:[size isKindOfClass:NSNumber.class] ? [size longLongValue] : 0];
}

- (BOOL)isDirectory { return [self.type isEqualToString:@"directory"]; }

- (NSDictionary *)JSON {
    return @{ @"path": self.path ?: NSNull.null, @"type": self.type ?: NSNull.null, @"size": @(self.size) };
}

@end

// ───────────── nodes ─────────────

@interface CCCatalogNode () {
    NSMutableArray<CCCatalogNode *> *_kids;
    NSString *_display;
}
@property (nonatomic, weak) CCCatalogNode *parent;
@end

@implementation CCCatalogNode

- (instancetype)initWithName:(NSString *)name path:(NSString *)path directory:(BOOL)directory parent:(CCCatalogNode *)parent {
    if ((self = [super init])) {
        _name = [name copy];
        _path = [path copy];
        _isDirectory = directory;
        _parent = parent;
        if (directory) _kids = [NSMutableArray array];
    }
    return self;
}

- (long long)size { return _size; }
- (int)fileCount { return _fileCount; }
- (long long)selectedBytes { return _selectedBytes; }
- (int)selectedFiles { return _selectedFiles; }
- (NSArray<CCCatalogNode *> *)children { return _kids ?: @[]; }

- (NSString *)displayName {
    if (!_display) _display = [CCCatalog displayName:_name];
    return _display;
}

- (void)forEachFile:(void (^)(CCCatalogNode *))block {
    if (!_isDirectory) {
        block(self);
        return;
    }
    for (CCCatalogNode *child in _kids) [child forEachFile:block];
}

- (void)addChild:(CCCatalogNode *)child { [_kids addObject:child]; }

- (void)sortChildren {
    [_kids sortUsingComparator:^NSComparisonResult(CCCatalogNode *a, CCCatalogNode *b) {
        if (a->_isDirectory != b->_isDirectory) return a->_isDirectory ? NSOrderedAscending : NSOrderedDescending;
        NSInteger c = [CCCatalog naturalCompare:a->_name with:b->_name];
        return c < 0 ? NSOrderedAscending : c > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
}

@end

// ───────────── sections ─────────────

@interface CCCatalogSection () {
    NSMutableArray<CCCatalogNode *> *_rowList;
}
@end

@implementation CCCatalogSection

- (instancetype)initWithId:(NSString *)identifier roots:(NSArray<NSString *> *)roots {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _roots = [roots copy];
        _rowList = [NSMutableArray array];
    }
    return self;
}

- (NSArray<CCCatalogNode *> *)rows { return _rowList; }
- (void)addRow:(CCCatalogNode *)node { [_rowList addObject:node]; }
- (void)addRows:(NSArray<CCCatalogNode *> *)nodes { [_rowList addObjectsFromArray:nodes]; }

- (long long)size {
    long long sum = 0;
    for (CCCatalogNode *n in _rowList) sum += n->_size;
    return sum;
}
- (int)fileCount {
    int sum = 0;
    for (CCCatalogNode *n in _rowList) sum += n->_fileCount;
    return sum;
}
- (long long)selectedBytes {
    long long sum = 0;
    for (CCCatalogNode *n in _rowList) sum += n->_selectedBytes;
    return sum;
}
- (int)selectedFiles {
    int sum = 0;
    for (CCCatalogNode *n in _rowList) sum += n->_selectedFiles;
    return sum;
}

@end

// ───────────── catalog ─────────────

static NSString *const kReleasedRoot = @"Compilation/1. Released Discography";

static NSString *const kMiscRoot = @"Compilation/3. Misc. Discography";

/// The API files everything he ever put out under "released". What came out and is on the streaming services under his
/// name is Released: the albums with their editions, the label's EPs and singles, and the one compilation folder Apple
/// Music lists too. The EPs and singles he uploaded himself never came out.
static void SortReleases(CCCatalogNode *released, CCCatalogNode *misc, CCCatalogSection *albums, CCCatalogSection *compilations, CCCatalogSection *unofficial) {
    NSArray *names = @[ @"Goodbye & Good Riddance", @"Death Race For Love", @"Legends Never Die", @"Fighting Demons", @"The Party Never Ends", @"Too Soon", @"The Pre-Party", @"Up Next Session" ];
    BOOL (^starts)(NSString *) = ^BOOL(NSString *name) {
        for (NSString *start in names)
            if ([name rangeOfString:start options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) return YES;
        return NO;
    };
    for (CCCatalogNode *child in released.children) {
        NSString *name = [CCCatalog displayName:child.name];
        if (child.isDirectory && [name rangeOfString:@"Singles & Features" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            for (CCCatalogNode *kind in child.children)
                [[CCCatalog displayName:kind.name] hasPrefix:@"Mainstream"] ? [albums addRow:kind] : [unofficial addRow:kind];
        } else if (starts(name) || [name rangeOfString:@"WRLD ON DRUGS" options:NSCaseInsensitiveSearch].location != NSNotFound) [albums addRow:child];
        else [unofficial addRow:child];
    }
    for (CCCatalogNode *child in misc.children)
        [[CCCatalog displayName:child.name] hasPrefix:@"All Girls Are The Same 2"] ? [albums addRow:child] : [compilations addRow:child];
}

@implementation CCCatalog

- (CCCatalogSection *)everything {
    CCCatalogSection *all = [[CCCatalogSection alloc] initWithId:@"everything" roots:@[]];
    for (CCCatalogSection *section in self.sections) [all addRows:section.rows];
    return all;
}

+ (NSArray<NSArray *> *)sectionTable {
    static NSArray *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            @[ @"albums", @[ kReleasedRoot ] ],
            @[ @"unofficial", @[] ],
            @[ @"unreleased", @[ @"Compilation/2. Unreleased Discography" ] ],
            @[ @"compilations", @[ kMiscRoot ] ],
            @[ @"sessionEdits", @[ @"Session Edits" ] ],
            @[ @"originals", @[ @"Original Files" ] ],
            @[ @"studio", @[ @"Studio Sessions" ] ],
            @[ @"instrumentals", @[ @"Instrumentals" ] ],
            @[ @"remixes", @[ @"Remixes & Edits" ] ],
            @[ @"snippets", @[ @"Snippets" ] ],
            @[ kFallbackSection, @[ @"Cover Arts", @"Compilation/4. Cover Art", @"Footage", @"Others" ] ],
        ];
    });
    return table;
}

+ (NSArray<NSString *> *)unreleasedSectionIds {
    return @[ @"unofficial", @"unreleased", @"sessionEdits", @"compilations", @"remixes" ];
}

+ (NSArray<NSString *> *)ruleSectionIds {
    NSMutableArray *ids = [self.sectionIds mutableCopy];
    [ids removeObjectsInArray:@[ @"snippets", kFallbackSection ]];
    return ids;
}

+ (NSArray<NSString *> *)sectionIds {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSArray *entry in self.sectionTable) [ids addObject:entry[0]];
    return ids;
}

+ (NSString *)displayName:(NSString *)name {
    static NSRegularExpression *prefix;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ prefix = [NSRegularExpression regularExpressionWithPattern:@"^\\d+\\.\\s+" options:0 error:nil]; });
    NSTextCheckingResult *m = [prefix firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
    if (!m || m.range.length >= name.length) return name;
    return [name substringFromIndex:NSMaxRange(m.range)];
}

static CCCatalogNode *Folder(NSString *path, NSMutableDictionary<NSString *, CCCatalogNode *> *folders, CCCatalogNode *root) {
    CCCatalogNode *existing = folders[path];
    if (existing) return existing;
    NSRange cut = [path rangeOfString:@"/" options:NSBackwardsSearch];
    CCCatalogNode *parent = cut.location == NSNotFound ? root : Folder([path substringToIndex:cut.location], folders, root);
    NSString *name = cut.location == NSNotFound ? path : [path substringFromIndex:cut.location + 1];
    CCCatalogNode *node = [[CCCatalogNode alloc] initWithName:name path:path directory:YES parent:parent];
    [parent addChild:node];
    folders[path] = node;
    return node;
}

static void Tally(CCCatalogNode *node) {
    [node sortChildren];
    for (CCCatalogNode *child in node.children) {
        if (child.isDirectory) Tally(child);
        node->_size += child->_size;
        node->_fileCount += child->_fileCount;
    }
}

/// Whatever no page claims, such as the compilation's READ ME or a new top-level folder.
static void Unclaimed(CCCatalogNode *folder, NSSet<CCCatalogNode *> *placed, CCCatalogSection *fallback) {
    for (CCCatalogNode *child in folder.children) {
        if ([placed containsObject:child]) continue;
        BOOL holdsPlaced = NO;
        if (child.isDirectory) {
            NSString *prefix = [child.path stringByAppendingString:@"/"];
            for (CCCatalogNode *p in placed)
                if ([p.path hasPrefix:prefix]) { holdsPlaced = YES; break; }
        }
        if (holdsPlaced) Unclaimed(child, placed, fallback);
        else [fallback addRow:child];
    }
}

+ (CCCatalog *)build:(NSArray<CCApiItem *> *)items {
    CCCatalogNode *root = [[CCCatalogNode alloc] initWithName:@"" path:@"" directory:YES parent:nil];
    NSMutableDictionary *folders = [NSMutableDictionary dictionaryWithObject:root forKey:@""];
    NSCharacterSet *slash = [NSCharacterSet characterSetWithCharactersInString:@"/"];
    NSMutableSet *seen = [NSMutableSet setWithCapacity:items.count];

    for (CCApiItem *item in items) {
        NSString *path = [item.path stringByTrimmingCharactersInSet:slash] ?: @"";
        if (path.length == 0) continue;
        if (item.isDirectory) continue;   // a folder exists through its files: the API also lists empty ones
        if ([seen containsObject:path]) continue;
        [seen addObject:path];
        NSRange cut = [path rangeOfString:@"/" options:NSBackwardsSearch];
        CCCatalogNode *parent = cut.location == NSNotFound ? root : Folder([path substringToIndex:cut.location], folders, root);
        NSString *name = cut.location == NSNotFound ? path : [path substringFromIndex:cut.location + 1];
        CCCatalogNode *file = [[CCCatalogNode alloc] initWithName:name path:path directory:NO parent:parent];
        file->_size = MAX(0, item.size);
        file->_fileCount = 1;
        [parent addChild:file];
    }
    Tally(root);

    NSMutableArray *sections = [NSMutableArray array];
    CCCatalogSection *fallback = nil;
    NSMutableSet *placed = [NSMutableSet set];
    for (NSArray *entry in self.sectionTable) {
        CCCatalogSection *section = [[CCCatalogSection alloc] initWithId:entry[0] roots:entry[1]];
        [sections addObject:section];
        BOOL isFallback = [section.identifier isEqualToString:kFallbackSection];
        if (isFallback) fallback = section;
        for (NSString *path in section.roots) {
            CCCatalogNode *node = folders[path];
            if (!node) continue;
            [placed addObject:node];
            // The one-root pages list what is inside; the media page keeps its roots as rows, they are what tells them apart.
            if (isFallback) [section addRow:node];
            else if (![path isEqualToString:kReleasedRoot] && ![path isEqualToString:kMiscRoot]) [section addRows:node.children];
        }
    }
    {
        CCCatalogSection *(^named)(NSString *) = ^CCCatalogSection *(NSString *identifier) {
            for (CCCatalogSection *s in sections) if ([s.identifier isEqualToString:identifier]) return s;
            return nil;
        };
        SortReleases(folders[kReleasedRoot], folders[kMiscRoot], named(@"albums"), named(@"compilations"), named(@"unofficial"));
    }
    Unclaimed(root, placed, fallback);

    CCCatalog *catalog = [CCCatalog new];
    catalog->_root = root;
    catalog->_sections = sections;
    return catalog;
}

- (long long)totalBytes { return _root->_size; }
- (int)totalFiles { return _root->_fileCount; }
- (long long)selectedBytes { return _root->_selectedBytes; }
- (int)selectedFiles { return _root->_selectedFiles; }

- (CCCatalogSection *)section:(NSString *)identifier {
    for (CCCatalogSection *s in _sections)
        if ([s.identifier isEqualToString:identifier]) return s;
    return nil;
}

static inline BOOL IsAsciiDigit(unichar c) { return c >= '0' && c <= '9'; }

static inline unichar UpperInvariant(unichar c) {
    if (c < 128) return c >= 'a' && c <= 'z' ? (unichar)(c - 32) : c;
    NSString *upper = [NSString stringWithCharacters:&c length:1].uppercaseString;
    return upper.length == 1 ? [upper characterAtIndex:0] : c;
}

+ (NSInteger)naturalCompare:(NSString *)a with:(NSString *)b {
    NSUInteger i = 0, j = 0, la = a.length, lb = b.length;
    while (i < la && j < lb) {
        unichar ca = [a characterAtIndex:i], cb = [b characterAtIndex:j];
        if (IsAsciiDigit(ca) && IsAsciiDigit(cb)) {
            NSUInteger si = i, sj = j;
            while (i < la && IsAsciiDigit([a characterAtIndex:i])) i++;
            while (j < lb && IsAsciiDigit([b characterAtIndex:j])) j++;
            while (si < i && [a characterAtIndex:si] == '0') si++;
            while (sj < j && [b characterAtIndex:sj] == '0') sj++;
            if (i - si != j - sj) return (NSInteger)(i - si) - (NSInteger)(j - sj);
            for (NSUInteger k = 0; k < i - si; k++) {
                NSInteger c = (NSInteger)[a characterAtIndex:si + k] - (NSInteger)[b characterAtIndex:sj + k];
                if (c != 0) return c;
            }
            continue;
        }
        unichar ua = UpperInvariant(ca), ub = UpperInvariant(cb);
        if (ua != ub) return (NSInteger)ua - (NSInteger)ub;
        i++;
        j++;
    }
    return (NSInteger)(la - i) - (NSInteger)(lb - j);
}

/// A folder of 10,000 files takes one walk of its subtree and one of its ancestors, not one per file.
static void Apply(CCCatalogNode *node, BOOL selected, long long *bytes, int *files) {
    if (!node.isDirectory) {
        BOOL was = node->_selectedFiles == 1;
        if (was == selected) return;
        long long b = selected ? node->_size : -node->_size;
        int f = selected ? 1 : -1;
        node->_selectedBytes += b;
        node->_selectedFiles += f;
        *bytes += b;
        *files += f;
        return;
    }
    long long b = 0;
    int f = 0;
    for (CCCatalogNode *child in node.children) Apply(child, selected, &b, &f);
    node->_selectedBytes += b;
    node->_selectedFiles += f;
    *bytes += b;
    *files += f;
}

+ (void)select:(CCCatalogNode *)node selected:(BOOL)selected {
    long long bytes = 0;
    int files = 0;
    Apply(node, selected, &bytes, &files);
    if (bytes == 0 && files == 0) return;
    for (CCCatalogNode *p = node.parent; p; p = p.parent) {
        p->_selectedBytes += bytes;
        p->_selectedFiles += files;
    }
}

static void CollectSelected(CCCatalogNode *node, NSMutableArray *into) {
    if (node->_selectedFiles == 0) return;
    if (!node.isDirectory) {
        [into addObject:node];
        return;
    }
    for (CCCatalogNode *child in node.children) CollectSelected(child, into);
}

- (NSArray<CCCatalogNode *> *)selectedFilesList {
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:(NSUInteger)_root->_selectedFiles];
    CollectSelected(_root, list);
    return list;
}

- (void)clearSelection { [CCCatalog select:_root selected:NO]; }

@end

// ───────────── rows ─────────────

@implementation CCLibraryRow
- (instancetype)initWithNode:(CCCatalogNode *)node depth:(NSInteger)depth expanded:(BOOL)expanded {
    if ((self = [super init])) {
        _node = node;
        _depth = depth;
        _expanded = expanded;
    }
    return self;
}
@end

@implementation CCLibraryRows {
    NSMutableSet<NSString *> *_expanded;
}

- (instancetype)initWithSection:(CCCatalogSection *)section {
    if ((self = [super init])) {
        _section = section;
        _query = @"";
        _expanded = [NSMutableSet set];
    }
    return self;
}

- (BOOL)toggle:(CCCatalogNode *)folder {
    if (!folder.isDirectory) return NO;
    if ([_expanded containsObject:folder.path]) [_expanded removeObject:folder.path];
    else [_expanded addObject:folder.path];
    return YES;
}

- (void)reveal:(CCCatalogNode *)node {
    self.query = @"";
    for (CCCatalogNode *n = node.parent; n; n = n.parent) [_expanded addObject:n.path];
}

- (void)add:(CCCatalogNode *)node depth:(NSInteger)depth into:(NSMutableArray *)rows {
    BOOL open = node.isDirectory && [_expanded containsObject:node.path];
    [rows addObject:[[CCLibraryRow alloc] initWithNode:node depth:depth expanded:open]];
    if (!open) return;
    for (CCCatalogNode *child in node.children) [self add:child depth:depth + 1 into:rows];
}

- (void)search:(CCCatalogNode *)node query:(NSString *)query into:(NSMutableArray *)rows {
    if ([node.name rangeOfString:query options:NSCaseInsensitiveSearch | NSLiteralSearch].location != NSNotFound) {
        // A folder that matches stands for everything inside it.
        [self add:node depth:0 into:rows];
        return;
    }
    for (CCCatalogNode *child in node.children) [self search:child query:query into:rows];
}

- (NSArray<CCLibraryRow *> *)rows {
    NSMutableArray *rows = [NSMutableArray array];
    NSString *query = [_query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (CCCatalogNode *top in _section.rows) {
        if (query.length > 0) [self search:top query:query into:rows];
        else [self add:top depth:0 into:rows];
    }
    return rows;
}

@end

// ───────────── local paths ─────────────

@implementation CCLocalPath

static const NSUInteger kMaxComponentBytes = 240; // leaves room for ".part" and ".lrc" under the 255 of most file systems

static NSUInteger Utf8Length(NSString *s) { return [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]; }

static NSString *AbsolutePath(NSString *path) {
    if (![path hasPrefix:@"/"]) path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (part.length == 0 || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."]) [parts removeLastObject];
        else [parts addObject:part];
    }
    return [@"/" stringByAppendingString:[parts componentsJoinedByString:@"/"]];
}

+ (NSString *)resolve:(NSString *)apiPath under:(NSString *)destination {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *raw in [[apiPath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] componentsSeparatedByString:@"/"]) {
        if (raw.length == 0) continue;
        if ([raw isEqualToString:@"."] || [raw isEqualToString:@".."]) return nil;
        [parts addObject:[self clean:raw]];
    }
    if (parts.count == 0) return nil;
    NSString *root = AbsolutePath(destination);
    NSString *prefix = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
    NSString *full = AbsolutePath([prefix stringByAppendingString:[parts componentsJoinedByString:@"/"]]);
    return [full hasPrefix:prefix] ? full : nil;
}

+ (NSString *)clean:(NSString *)component {
    static NSCharacterSet *trailing, *leading;
    static NSSet *reserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        trailing = [NSCharacterSet characterSetWithCharactersInString:@" ."];
        leading = [NSCharacterSet characterSetWithCharactersInString:@" "];
        reserved = [NSSet setWithArray:@[ @"CON", @"PRN", @"AUX", @"NUL", @"COM1", @"COM2", @"COM3", @"COM4", @"COM5", @"COM6", @"COM7", @"COM8", @"COM9",
                                          @"LPT1", @"LPT2", @"LPT3", @"LPT4", @"LPT5", @"LPT6", @"LPT7", @"LPT8", @"LPT9" ]];
    });
    NSMutableString *text = [component mutableCopy];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < 32 || c == '<' || c == '>' || c == ':' || c == '"' || c == '/' || c == '\\' || c == '|' || c == '?' || c == '*')
            [text replaceCharactersInRange:NSMakeRange(i, 1) withString:@"_"];
    }
    // TrimEnd(' ', '.') then TrimStart(' ').
    NSUInteger end = text.length;
    while (end > 0 && [trailing characterIsMember:[text characterAtIndex:end - 1]]) end--;
    NSUInteger start = 0;
    while (start < end && [leading characterIsMember:[text characterAtIndex:start]]) start++;
    NSString *name = [text substringWithRange:NSMakeRange(start, end - start)];
    if (name.length == 0) name = @"_";

    NSString *stem = [name componentsSeparatedByString:@"."].firstObject;
    if ([reserved containsObject:stem.uppercaseString]) name = [@"_" stringByAppendingString:name];

    if (Utf8Length(name) <= kMaxComponentBytes) return name;
    NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
    NSString *extension = dot.location == NSNotFound ? @"" : [name substringFromIndex:dot.location];
    if (Utf8Length(extension) > 16) extension = @"";
    NSMutableString *keep = [[name substringToIndex:name.length - extension.length] mutableCopy];
    NSUInteger extensionBytes = Utf8Length(extension);
    while (keep.length > 0 && Utf8Length(keep) + extensionBytes > kMaxComponentBytes) {
        BOOL surrogate = CFStringIsSurrogateLowCharacter([keep characterAtIndex:keep.length - 1]) && keep.length >= 2;
        [keep deleteCharactersInRange:NSMakeRange(keep.length - (surrogate ? 2 : 1), surrogate ? 2 : 1)];
    }
    end = keep.length;
    while (end > 0 && [trailing characterIsMember:[keep characterAtIndex:end - 1]]) end--;
    return [[keep substringToIndex:end] stringByAppendingString:extension];
}

@end
