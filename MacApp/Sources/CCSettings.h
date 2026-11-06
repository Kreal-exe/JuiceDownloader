// Settings (the same JSON shape as the other apps) and localization (the shared Strings/*.json plus a macOS overlay
// that replaces the Windows-specific wording).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CCSettings : NSObject
/// "auto" or a language code.
@property (nonatomic, copy) NSString *language;
/// "dark", "light" or "system".
@property (nonatomic, copy) NSString *theme;
@property (nonatomic) BOOL animations;
/// The translucent window ("backdrop" in the file).
@property (nonatomic) BOOL backdrop;
/// Where downloads go; ~/Music/Juice WRLD by default.
@property (nonatomic, copy) NSString *destination;
/// Downloads at a time, 1 to 32; the Settings page offers 1, 2, 4, 8, 16 and 32.
@property (nonatomic) NSInteger parallel;
@property (nonatomic) BOOL confirmDownloads;
@property (nonatomic) BOOL refreshOnLaunch;
@property (nonatomic) BOOL lyricsEnabled;
@property (nonatomic) BOOL lyricsEmbed;
@property (nonatomic) BOOL lyricsSidecar;
@property (nonatomic) BOOL lyricsTimedInTag;
/// 0 to 1.
@property (nonatomic) double playerVolume;
@property (nonatomic) BOOL rulesOneVersion, rulesSkipReleased, rulesSkipUnfinished, rulesOneFolder, rulesWithClips;
/// Files the user took out of the folder for good: By Rules never offers them again.
@property (nonatomic, copy) NSArray<NSString *> *rulesNeverOffer;
/// Files called clips by hand: lives with no mark in their names.
@property (nonatomic, copy) NSArray<NSString *> *rulesClipPaths;
@property (nonatomic, copy) NSArray<NSString *> *rulesSections;
@property (nonatomic) double windowWidth;
@property (nonatomic) double windowHeight;
@property (nonatomic) BOOL windowMaximized;

/// ~/Library/Application Support/JuiceDownloader/settings.json; JUICEDOWNLOADER_SETTINGS overrides it.
+ (NSString *)filePath;
/// The "cache" folder next to the settings file.
+ (NSString *)cacheDirectory;
+ (instancetype)load;
- (void)save;
- (void)resetToDefaults;
@end

@interface CCLanguage : NSObject
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *nativeName;
@end

FOUNDATION_EXPORT NSNotificationName const CCLanguageDidChangeNotification;

@interface CCLocalization : NSObject
@property (class, nonatomic, readonly) CCLocalization *shared;
@property (class, nonatomic, readonly) NSArray<CCLanguage *> *languages;
/// The language actually shown ("auto" resolved).
@property (nonatomic, readonly) NSString *code;
/// Folders holding <code>.json files, later folders overriding earlier ones.
@property (nonatomic, copy) NSArray<NSString *> *searchFolders;
/// "auto" follows the macOS language list.
- (void)setLanguage:(NSString *)codeOrAuto;
+ (NSString *)systemLanguageCode;
- (NSString *)string:(NSString *)key;
- (NSString *)format:(NSString *)key arguments:(NSArray *)arguments;
- (BOOL)hasKey:(NSString *)key;
@end

NSString *L(NSString *key);
NSString *CCLF(NSString *key, NSArray *arguments);
#define LF(key, ...) CCLF(key, @[ __VA_ARGS__ ])

NS_ASSUME_NONNULL_END
