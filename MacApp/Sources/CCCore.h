// Byte and number formatting. Foundation only, so the tests can build it without AppKit.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The locale numbers are formatted with; follows the interface language.
void CCSetFormatLocale(NSLocale *locale);
/// "12.4 GB" with 1024-based units, like the Windows app.
NSString *CCFormatBytes(double bytes);
void CCSplitBytes(double bytes, NSString *_Nullable *_Nullable number, NSString *_Nullable *_Nullable unit);
/// "133 697" with the locale's grouping.
NSString *CCFormatCount(long long count);
/// "0.4" with the locale's decimal separator.
NSString *CCFormatDecimal(double value);

NS_ASSUME_NONNULL_END
