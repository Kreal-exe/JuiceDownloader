// The API's tree as the app sees it: nodes with their sizes and selection, the sidebar's sections, the flattened rows
// of a section page, and where a file goes on disk. The port of Catalog.cs, LibraryRows.cs and LocalPath.cs.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One entry of /files/list-all/.
@interface CCApiItem : NSObject
@property (nonatomic, copy, nullable) NSString *path;
@property (nonatomic, copy, nullable) NSString *type;
@property (nonatomic) long long size;
@property (nonatomic, readonly) BOOL isDirectory;
+ (instancetype)path:(nullable NSString *)path type:(nullable NSString *)type size:(long long)size;
+ (nullable instancetype)fromJSON:(id)json;
- (NSDictionary *)JSON;
@end

/// One file or folder of the tree, with its size and the selection kept up to date all the way to the root.
@interface CCCatalogNode : NSObject {
@public
    long long _size, _selectedBytes;
    int _fileCount, _selectedFiles;
}
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, readonly) BOOL isDirectory;
@property (nonatomic, readonly) long long size;
@property (nonatomic, readonly) int fileCount;
@property (nonatomic, weak, readonly, nullable) CCCatalogNode *parent;
@property (nonatomic, readonly) NSArray<CCCatalogNode *> *children;
@property (nonatomic, readonly) long long selectedBytes;
@property (nonatomic, readonly) int selectedFiles;
/// The name without the API's ordering number: "7. Goodbye & Good Riddance" reads "Goodbye & Good Riddance".
@property (nonatomic, readonly) NSString *displayName;
/// Every file at or below this node, in tree order.
- (void)forEachFile:(void (^)(CCCatalogNode *file))block;
@end

/// A page of the sidebar: the folders of the API's tree that belong on it.
@interface CCCatalogSection : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSArray<NSString *> *roots;
@property (nonatomic, readonly) NSArray<CCCatalogNode *> *rows;
@property (nonatomic, readonly) long long size;
@property (nonatomic, readonly) int fileCount;
@property (nonatomic, readonly) long long selectedBytes;
@property (nonatomic, readonly) int selectedFiles;
@end

@interface CCCatalog : NSObject
/// Section id -> the tree's folders. Everything the API offers lands on one of them: "media" takes whatever is unclaimed.
+ (NSArray<NSArray *> *)sectionTable;
+ (NSArray<NSString *> *)sectionIds;
/// Every real song that never came out officially: no snippets, original files, beats or art.
+ (NSArray<NSString *> *)unreleasedSectionIds;
/// What By Rules takes songs from: every section but snippets and art, which nobody collects as songs.
+ (NSArray<NSString *> *)ruleSectionIds;
+ (CCCatalog *)build:(NSArray<CCApiItem *> *)items;
+ (NSString *)displayName:(NSString *)name;
/// Numbers compare as numbers: the API's "2. affliction" comes before "10. Outsiders".
+ (NSInteger)naturalCompare:(NSString *)a with:(NSString *)b;
/// Selects or clears a file or a whole folder. Main thread once the catalog is on screen.
+ (void)select:(CCCatalogNode *)node selected:(BOOL)selected;

@property (nonatomic, readonly) CCCatalogNode *root;
@property (nonatomic, readonly) NSArray<CCCatalogSection *> *sections;
/// Every section's rows as one: what the Overview's search goes through.
- (CCCatalogSection *)everything;
@property (nonatomic, readonly) long long totalBytes;
@property (nonatomic, readonly) int totalFiles;
@property (nonatomic, readonly) long long selectedBytes;
@property (nonatomic, readonly) int selectedFiles;
- (nullable CCCatalogSection *)section:(NSString *)identifier;
- (NSArray<CCCatalogNode *> *)selectedFilesList;
- (void)clearSelection;
@end

/// One line of a section page's list: a folder that opens in place, or a file.
@interface CCLibraryRow : NSObject
@property (nonatomic, strong, readonly) CCCatalogNode *node;
@property (nonatomic, readonly) NSInteger depth;
@property (nonatomic, readonly) BOOL expanded;
@end

/// What a section page shows, flattened to a list so the view can virtualize it: the Photos folder alone holds 9,481
/// files. A search lists the matching files and folders of the section, whatever their depth. What is open is kept by
/// path, so it survives a refresh of the catalog.
@interface CCLibraryRows : NSObject
- (instancetype)initWithSection:(CCCatalogSection *)section;
@property (nonatomic, strong) CCCatalogSection *section;
@property (nonatomic, copy) NSString *query;
- (BOOL)toggle:(CCCatalogNode *)folder;
/// Clears the search and opens the folders down to a file, so it can be scrolled to.
- (void)reveal:(CCCatalogNode *)node;
- (NSArray<CCLibraryRow *> *)rows;
@end

/// Turns a path the API sent into a file under the chosen folder. Nothing in it may climb out of that folder, and it
/// has to be a legal name on all three systems.
@interface CCLocalPath : NSObject
/// The file for an API path, or nil when the path holds nothing usable.
+ (nullable NSString *)resolve:(NSString *)apiPath under:(NSString *)destination;
+ (NSString *)clean:(NSString *)component;
@end

NS_ASSUME_NONNULL_END
