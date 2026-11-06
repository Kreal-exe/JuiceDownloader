#import "CCSettings.h"
#import "CCCore.h"

@implementation CCSettings

- (instancetype)init {
    if ((self = [super init])) [self resetToDefaults];
    return self;
}

- (void)resetToDefaults {
    _language = @"auto";
    _theme = @"dark";
    _animations = YES;
    _backdrop = YES;
    _destination = [NSHomeDirectory() stringByAppendingPathComponent:@"Music/Juice WRLD"];
    _parallel = 8;
    _confirmDownloads = YES;
    _refreshOnLaunch = YES;
    _lyricsEnabled = NO;
    _lyricsEmbed = YES;
    _lyricsSidecar = YES;
    _lyricsTimedInTag = NO;
    _playerVolume = 0.8;
    _rulesOneVersion = _rulesOneFolder = YES;
    _rulesSkipReleased = YES;
    _rulesSkipUnfinished = NO;
    _rulesSections = @[ @"unreleased", @"sessionEdits" ];
    _rulesNeverOffer = @[];
    _rulesClipPaths = @[];
}

+ (NSString *)filePath {
    const char *custom = getenv("JUICEDOWNLOADER_SETTINGS");
    if (custom && *custom) return [NSString stringWithUTF8String:custom].stringByStandardizingPath;
    NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    return [[support stringByAppendingPathComponent:@"JuiceDownloader"] stringByAppendingPathComponent:@"settings.json"];
}

+ (NSString *)cacheDirectory {
    return [[self filePath].stringByDeletingLastPathComponent stringByAppendingPathComponent:@"cache"];
}

static id Get(NSDictionary *d, NSString *key, Class type) {
    id value = d[key];
    return [value isKindOfClass:type] ? value : nil;
}

+ (instancetype)load {
    CCSettings *s = [CCSettings new];
    NSData *data = [NSData dataWithContentsOfFile:[self filePath]];
    NSDictionary *d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![d isKindOfClass:NSDictionary.class]) return s;

    s.language = Get(d, @"language", NSString.class) ?: s.language;
    s.theme = Get(d, @"theme", NSString.class) ?: s.theme;
    NSString *destination = Get(d, @"destination", NSString.class);
    if (destination.length > 0) s.destination = destination;
    NSNumber *n;
    if ((n = Get(d, @"animations", NSNumber.class))) s.animations = n.boolValue;
    if ((n = Get(d, @"backdrop", NSNumber.class))) s.backdrop = n.boolValue;
    if ((n = Get(d, @"parallel", NSNumber.class))) s.parallel = MAX(1, MIN(32, n.integerValue));
    if ((n = Get(d, @"confirmDownloads", NSNumber.class))) s.confirmDownloads = n.boolValue;
    if ((n = Get(d, @"refreshOnLaunch", NSNumber.class))) s.refreshOnLaunch = n.boolValue;
    if ((n = Get(d, @"lyricsEnabled", NSNumber.class))) s.lyricsEnabled = n.boolValue;
    if ((n = Get(d, @"lyricsEmbed", NSNumber.class))) s.lyricsEmbed = n.boolValue;
    if ((n = Get(d, @"lyricsSidecar", NSNumber.class))) s.lyricsSidecar = n.boolValue;
    if ((n = Get(d, @"lyricsTimedInTag", NSNumber.class))) s.lyricsTimedInTag = n.boolValue;
    if ((n = Get(d, @"rulesOneVersion", NSNumber.class))) s.rulesOneVersion = n.boolValue;
    if ((n = Get(d, @"rulesSkipReleased", NSNumber.class))) s.rulesSkipReleased = n.boolValue;
    if ((n = Get(d, @"rulesSkipUnfinished", NSNumber.class))) s.rulesSkipUnfinished = n.boolValue;
    if ((n = Get(d, @"rulesOneFolder", NSNumber.class))) s.rulesOneFolder = n.boolValue;
    if ((n = Get(d, @"rulesWithClips", NSNumber.class))) s.rulesWithClips = n.boolValue;
    NSArray *sections = Get(d, @"rulesSections", NSArray.class);
    if (sections) s.rulesSections = sections;
    NSArray *refused = Get(d, @"rulesNeverOffer", NSArray.class);
    if (refused) s.rulesNeverOffer = refused;
    NSArray *clipPaths = Get(d, @"rulesClipPaths", NSArray.class);
    if (clipPaths) s.rulesClipPaths = clipPaths;
    if ((n = Get(d, @"playerVolume", NSNumber.class))) s.playerVolume = MAX(0, MIN(1, n.doubleValue));
    if ((n = Get(d, @"windowWidth", NSNumber.class))) s.windowWidth = n.doubleValue;
    if ((n = Get(d, @"windowHeight", NSNumber.class))) s.windowHeight = n.doubleValue;
    if ((n = Get(d, @"windowMaximized", NSNumber.class))) s.windowMaximized = n.boolValue;
    return s;
}

- (void)save {
    NSDictionary *d = @{
        @"language": self.language,
        @"theme": self.theme,
        @"animations": @(self.animations),
        @"backdrop": @(self.backdrop),
        @"destination": self.destination,
        @"parallel": @(self.parallel),
        @"confirmDownloads": @(self.confirmDownloads),
        @"refreshOnLaunch": @(self.refreshOnLaunch),
        @"lyricsEnabled": @(self.lyricsEnabled),
        @"lyricsEmbed": @(self.lyricsEmbed),
        @"lyricsSidecar": @(self.lyricsSidecar),
        @"lyricsTimedInTag": @(self.lyricsTimedInTag),
        @"playerVolume": @(self.playerVolume),
        @"rulesOneVersion": @(self.rulesOneVersion),
        @"rulesSkipReleased": @(self.rulesSkipReleased),
        @"rulesSkipUnfinished": @(self.rulesSkipUnfinished),
        @"rulesOneFolder": @(self.rulesOneFolder),
        @"rulesWithClips": @(self.rulesWithClips),
        @"rulesSections": self.rulesSections,
        @"rulesNeverOffer": self.rulesNeverOffer,
        @"rulesClipPaths": self.rulesClipPaths,
        @"windowWidth": @(self.windowWidth),
        @"windowHeight": @(self.windowHeight),
        @"windowMaximized": @(self.windowMaximized),
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!data) return;
    NSString *path = [CCSettings filePath];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:path atomically:YES];
}

@end

// ───────────── localization ─────────────

NSNotificationName const CCLanguageDidChangeNotification = @"CCLanguageDidChange";

@implementation CCLanguage
+ (instancetype)code:(NSString *)code name:(NSString *)name {
    CCLanguage *l = [CCLanguage new];
    l.code = code;
    l.nativeName = name;
    return l;
}
@end

@implementation CCLocalization {
    NSDictionary<NSString *, NSString *> *_strings;
    NSString *_code;
}

+ (CCLocalization *)shared {
    static CCLocalization *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [CCLocalization new];
        NSString *resources = NSBundle.mainBundle.resourcePath;
        shared.searchFolders = @[ [resources stringByAppendingPathComponent:@"Strings"],
                                  [resources stringByAppendingPathComponent:@"Strings-mac"] ];
        [shared setLanguage:@"auto"];
    });
    return shared;
}

+ (NSArray<CCLanguage *> *)languages {
    static NSArray *languages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        languages = @[
            [CCLanguage code:@"en" name:@"English"],
            [CCLanguage code:@"ru" name:@"Русский"],
        ];
    });
    return languages;
}

+ (NSString *)systemLanguageCode {
    for (NSString *preferred in NSLocale.preferredLanguages) {
        NSString *lower = preferred.lowercaseString;
        for (CCLanguage *l in self.languages)
            if ([lower isEqualToString:l.code.lowercaseString] || [lower hasPrefix:[l.code.lowercaseString stringByAppendingString:@"-"]]) return l.code;
    }
    return @"en";
}

- (NSString *)code { return _code ?: @"en"; }

static NSDictionary *ReadStrings(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    // The Windows files are saved with a byte order mark, which NSJSONSerialization rejects.
    if (data.length >= 3 && memcmp(data.bytes, "\xEF\xBB\xBF", 3) == 0) data = [data subdataWithRange:NSMakeRange(3, data.length - 3)];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

- (void)setLanguage:(NSString *)codeOrAuto {
    NSString *code = [codeOrAuto isEqualToString:@"auto"] ? [CCLocalization systemLanguageCode] : codeOrAuto;
    BOOL known = NO;
    for (CCLanguage *l in CCLocalization.languages) known |= [l.code isEqualToString:code];
    if (!known) code = @"en";

    // English underneath, so a key missing from a translation still shows readable text.
    NSMutableDictionary *strings = [NSMutableDictionary dictionary];
    for (NSString *lang in [code isEqualToString:@"en"] ? @[ @"en" ] : @[ @"en", code ])
        for (NSString *folder in self.searchFolders) {
            NSDictionary *d = ReadStrings([[folder stringByAppendingPathComponent:lang] stringByAppendingPathExtension:@"json"]);
            if (d) [strings addEntriesFromDictionary:d];
        }

    BOOL changed = _code && ![_code isEqualToString:code];
    _strings = strings;
    _code = code;
    CCSetFormatLocale([NSLocale localeWithLocaleIdentifier:code]);
    if (changed) [NSNotificationCenter.defaultCenter postNotificationName:CCLanguageDidChangeNotification object:self];
}

- (BOOL)hasKey:(NSString *)key { return _strings[key] != nil; }

- (NSString *)string:(NSString *)key { return _strings[key] ?: key; }

- (NSString *)format:(NSString *)key arguments:(NSArray *)arguments {
    NSMutableString *s = [[self string:key] mutableCopy];
    for (NSUInteger i = 0; i < arguments.count; i++) {
        NSString *token = [NSString stringWithFormat:@"{%lu}", (unsigned long)i];
        [s replaceOccurrencesOfString:token withString:[arguments[i] description] options:0 range:NSMakeRange(0, s.length)];
    }
    return s;
}

@end

NSString *L(NSString *key) { return [CCLocalization.shared string:key]; }

NSString *CCLF(NSString *key, NSArray *arguments) { return [CCLocalization.shared format:key arguments:arguments]; }
