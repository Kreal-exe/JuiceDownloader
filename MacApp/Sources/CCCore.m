#import "CCCore.h"

// ───────────── formatting ─────────────

static NSLocale *FormatLocale(void);
static NSLocale *gFormatLocale;

void CCSetFormatLocale(NSLocale *locale) {
    @synchronized ([NSLocale class]) { gFormatLocale = locale; }
}

static NSLocale *FormatLocale(void) {
    @synchronized ([NSLocale class]) { return gFormatLocale ?: NSLocale.currentLocale; }
}

static NSString *FormatNumber(double value, NSInteger fractionDigits, BOOL grouping) {
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    f.locale = FormatLocale();
    f.minimumFractionDigits = fractionDigits;
    f.maximumFractionDigits = fractionDigits;
    f.usesGroupingSeparator = grouping;
    f.roundingMode = NSNumberFormatterRoundHalfEven;
    return [f stringFromNumber:@(value)] ?: @"0";
}

void CCSplitBytes(double bytes, NSString **number, NSString **unit) {
    static NSArray<NSString *> *units;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ units = @[ @"B", @"KB", @"MB", @"GB", @"TB", @"PB" ]; });
    if (isnan(bytes) || bytes < 0) bytes = 0;

    NSUInteger index = 0;
    double value = bytes;
    while (value >= 1024 && index < units.count - 1) {
        value /= 1024;
        index++;
    }
    NSInteger digits = index == 0 ? 0 : value >= 100 ? 0 : value >= 10 ? 1 : 2;
    // "1023.6 KB" would round to "1 024 KB"; keep the number readable like the Windows formatter does.
    if (number) *number = FormatNumber(value, digits, NO);
    if (unit) *unit = units[index];
}

NSString *CCFormatBytes(double bytes) {
    NSString *number, *unit;
    CCSplitBytes(bytes, &number, &unit);
    return [NSString stringWithFormat:@"%@ %@", number, unit];
}

NSString *CCFormatCount(long long count) { return FormatNumber((double)count, 0, YES); }

NSString *CCFormatDecimal(double value) { return FormatNumber(value, 1, NO); }
