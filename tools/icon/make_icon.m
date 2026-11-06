// Draws the app icon, a juice carton after the one juicewrldapi.com uses, as vectors, and writes what each system wants.
//
//   clang -fobjc-arc -framework Cocoa -framework CoreText tools/icon/make_icon.m -o /tmp/make_icon && /tmp/make_icon <repo>
//
// macOS  a carton on Apple's rounded tile, with its margin and shadow: MacApp/Resources/AppIcon.icns
// Windows  the carton alone with a sticker edge, for dark and light taskbars: src/JuiceDownloader/Assets/app.ico
// Linux  the same at 512 px: LinuxApp/Assets/icon.png
// In the apps  logo.png, the simple carton, for 24 to 96 points
//
// Below 64 px letters turn to mud, so the small sizes are a simple carton with heavier lines, not a scaled-down big one.
#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>

static const CGFloat Unit = 512; // drawing space, y down

static void Poly(CGContextRef c, int n, const CGFloat *p) {
    CGContextMoveToPoint(c, p[0], p[1]);
    for (int i = 1; i < n; i++) CGContextAddLineToPoint(c, p[i * 2], p[i * 2 + 1]);
    CGContextClosePath(c);
}
static CGColorRef Hex(unsigned v) {
    return CGColorCreateSRGB(((v >> 16) & 255) / 255.0, ((v >> 8) & 255) / 255.0, (v & 255) / 255.0, 1);
}
static void Fill(CGContextRef c, unsigned color, int n, const CGFloat *p, CGFloat line) {
    CGColorRef col = Hex(color), ink = Hex(0x000000);
    Poly(c, n, p);
    CGContextSetFillColorWithColor(c, col);
    CGContextSetStrokeColorWithColor(c, ink);
    CGContextSetLineWidth(c, line);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextDrawPath(c, line > 0 ? kCGPathFillStroke : kCGPathFill);
    CGColorRelease(col);
    CGColorRelease(ink);
}

// Text laid on the carton's face: shear keeps it on the face's slope, width keeps it in the panel.
static void Label(CGContextRef c, NSString *text, CGFloat x, CGFloat y, CGFloat width, CGFloat height, CGFloat shear, unsigned fill, CGFloat outline) {
    NSFont *font = [NSFont fontWithName:@"Arial Black" size:100] ?: [NSFont boldSystemFontOfSize:100];
    CFDictionaryRef attrs = (__bridge CFDictionaryRef)@{ (__bridge id)kCTFontAttributeName: font };
    CFAttributedStringRef string = CFAttributedStringCreate(NULL, (__bridge CFStringRef)text, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(string);
    CGRect ink = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);

    CGMutablePathRef path = CGPathCreateMutable();
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, r);
        CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        for (CFIndex g = 0; g < CTRunGetGlyphCount(run); g++) {
            CGGlyph glyph; CGPoint pos;
            CTRunGetGlyphs(run, CFRangeMake(g, 1), &glyph);
            CTRunGetPositions(run, CFRangeMake(g, 1), &pos);
            CGPathRef outlinePath = CTFontCreatePathForGlyph(runFont, glyph, NULL);
            if (!outlinePath) continue;
            CGAffineTransform t = CGAffineTransformMakeTranslation(pos.x, pos.y);
            CGPathAddPath(path, &t, outlinePath);
            CGPathRelease(outlinePath);
        }
    }

    CGContextSaveGState(c);
    CGAffineTransform place = CGAffineTransformMake(1, shear, 0, 1, x, y); // shear in y
    CGContextConcatCTM(c, place);
    CGContextTranslateCTM(c, 0, height);
    CGContextScaleCTM(c, width / ink.size.width, -height / ink.size.height);
    CGContextTranslateCTM(c, -ink.origin.x, -ink.origin.y);
    CGColorRef f = Hex(fill), k = Hex(0x000000);
    if (outline > 0) {
        CGContextAddPath(c, path);
        CGContextSetStrokeColorWithColor(c, k);
        CGContextSetLineWidth(c, outline * ink.size.height / height);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        CGContextStrokePath(c);
    }
    CGContextAddPath(c, path);
    CGContextSetFillColorWithColor(c, f);
    CGContextFillPath(c);
    CGContextRestoreGState(c);
    CGColorRelease(f); CGColorRelease(k); CGPathRelease(path); CFRelease(line); CFRelease(string);
}

static void Straw(CGContextRef c, CGFloat w, CGFloat line) {
    const CGFloat x0 = 196, y0 = 18, x1 = 234, y1 = 124;
    CGFloat dx = x1 - x0, dy = y1 - y0, len = hypot(dx, dy), nx = -dy / len * w / 2, ny = dx / len * w / 2;
    CGFloat body[] = { x0 + nx, y0 + ny, x1 + nx, y1 + ny, x1 - nx, y1 - ny, x0 - nx, y0 - ny };
    Fill(c, 0xFFFFFF, 4, body, line);
    const int stripes = 5;
    for (int i = 0; i < stripes; i++) {
        CGFloat a = (i + 0.15) / stripes, b = (i + 0.65) / stripes;
        CGFloat q[] = { x0 + dx * a + nx, y0 + dy * a + ny, x0 + dx * b + nx, y0 + dy * b + ny, x0 + dx * b - nx, y0 + dy * b - ny, x0 + dx * a - nx, y0 + dy * a - ny };
        Fill(c, 0xE5322D, 4, q, 0);
    }
    Poly(c, 4, body);
    CGColorRef k = Hex(0);
    CGContextSetStrokeColorWithColor(c, k); CGContextSetLineWidth(c, line); CGContextStrokePath(c); CGColorRelease(k);
}

// The carton; `full` adds the lettering and the citrus.
static void Carton(CGContextRef c, BOOL full) {
    const unsigned blue = 0x35B5EA, yellow = 0xFFEE00;
    const CGFloat line = full ? 7 : 15;

    const CGFloat ridge[] = { 186, 42, 350, 42, 344, 92, 192, 86 };
    Fill(c, yellow, 4, ridge, line);

    Straw(c, full ? 20 : 30, full ? 5 : 10);

    const CGFloat roof[] = { 192, 86, 344, 92, 282, 182, 128, 156 };
    Fill(c, blue, 4, roof, line);
    const CGFloat roofStripe[] = { 228, 88, 280, 90, 228, 174, 176, 164 };
    Fill(c, yellow, 4, roofStripe, 0);
    const CGFloat gable[] = { 344, 92, 384, 132, 282, 182 };
    Fill(c, blue, 3, gable, line);
    const CGFloat gableIn[] = { 338, 112, 366, 136, 304, 166 };
    Fill(c, yellow, 3, gableIn, 0);
    // the stripe was drawn over the roof's edge
    Poly(c, 4, roof);
    CGColorRef k = Hex(0);
    CGContextSetStrokeColorWithColor(c, k); CGContextSetLineWidth(c, line); CGContextStrokePath(c); CGColorRelease(k);

    const CGFloat front[] = { 128, 156, 282, 182, 282, 492, 138, 442 };
    const CGFloat side[] = { 282, 182, 384, 132, 386, 428, 282, 492 };
    Fill(c, blue, 4, side, 0);
    const CGFloat sideStripe[] = { 308, 170, 358, 146, 360, 444, 310, 476 };
    Fill(c, yellow, 4, sideStripe, 0);
    Poly(c, 4, side);
    k = Hex(0);
    CGContextSetStrokeColorWithColor(c, k); CGContextSetLineWidth(c, line); CGContextStrokePath(c); CGColorRelease(k);
    Fill(c, blue, 4, front, line);

    if (!full) {
        const CGFloat band[] = { 134, 300, 282, 334, 282, 400, 137, 362 };
        Fill(c, yellow, 4, band, line);
        return;
    }

    // Citrus half, cut off by the carton's bottom edge.
    CGContextSaveGState(c);
    Poly(c, 4, front);
    CGContextClip(c);
    CGColorRef y = Hex(yellow), ink = Hex(0);
    CGContextSetFillColorWithColor(c, y);
    CGContextSetStrokeColorWithColor(c, ink);
    CGContextSetLineWidth(c, 6);
    CGRect disc = CGRectMake(148, 396, 124, 116);
    CGContextAddEllipseInRect(c, disc);
    CGContextDrawPath(c, kCGPathFillStroke);
    CGContextSetLineWidth(c, 4);
    for (int i = 0; i < 8; i++) {
        CGFloat a = i * M_PI / 4;
        CGContextMoveToPoint(c, CGRectGetMidX(disc), CGRectGetMidY(disc));
        CGContextAddLineToPoint(c, CGRectGetMidX(disc) + cos(a) * 58, CGRectGetMidY(disc) + sin(a) * 54);
    }
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    CGColorRelease(y); CGColorRelease(ink);

    const CGFloat shear = 26.0 / 154.0;
    Label(c, @"JUICE", 142, 182, 122, 50, shear, 0xFFFFFF, 11);
    Label(c, @"WRLD", 142, 248, 128, 50, shear, 0xFFFFFF, 11);
    const CGFloat band[] = { 136, 306, 278, 332, 278, 396, 138, 366 };
    Fill(c, yellow, 4, band, 6);
    Label(c, @"LEGEND", 146, 322, 122, 36, shear, 0x000000, 0);
    const CGFloat tag[] = { 292, 258, 372, 222, 372, 318, 293, 360 };
    Fill(c, 0xFFFFFF, 4, tag, 5);
    Label(c, @"999", 302, 268, 60, 44, -0.46, 0x000000, 0);
}

typedef NS_ENUM(int, IconStyle) { StyleTile, StyleSticker, StylePlain };

static NSData *Render(int px, IconStyle style, BOOL full) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGContextTranslateCTM(c, 0, px);
    CGContextScaleCTM(c, 1, -1);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    const CGFloat s = px / Unit;

    if (style == StyleTile) {
        // Apple's grid: the tile is 824 of 1024, 100 from each side, with a soft shadow below.
        const CGFloat in = px * 100 / 1024.0, size = px - 2 * in, radius = size * 0.2237;
        CGRect tile = CGRectMake(in, in, size, size);
        CGPathRef shape = CGPathCreateWithRoundedRect(tile, radius, radius, NULL);
        CGContextSaveGState(c);
        CGColorRef shadow = CGColorCreateSRGB(0, 0, 0, 0.35);
        CGContextSetShadowWithColor(c, CGSizeMake(0, -px * 0.012), px * 0.02, shadow);
        CGColorRelease(shadow);
        CGContextAddPath(c, shape);
        CGColorRef base = Hex(0x20223A);
        CGContextSetFillColorWithColor(c, base);
        CGContextFillPath(c);
        CGColorRelease(base);
        CGContextRestoreGState(c);

        CGContextSaveGState(c);
        CGContextAddPath(c, shape);
        CGContextClip(c);
        CGColorRef a = Hex(0x8B7BFF), b = Hex(0x25C7F0);
        const void *colors[] = { a, b };
        CFArrayRef list = CFArrayCreate(NULL, colors, 2, &kCFTypeArrayCallBacks);
        CGGradientRef g = CGGradientCreateWithColors(space, list, NULL);
        CGContextDrawLinearGradient(c, g, CGPointMake(in, in), CGPointMake(px - in, px - in), 0);
        CGGradientRelease(g); CFRelease(list); CGColorRelease(a); CGColorRelease(b);
        CGContextRestoreGState(c);
        CGPathRelease(shape);

        const CGFloat k = 0.72 * px / Unit;
        CGContextTranslateCTM(c, (px - 258 * k) / 2 - 128 * k, (px - 480 * k) / 2 - 14 * k);
        CGContextScaleCTM(c, k, k);
        CGColorRef under = CGColorCreateSRGB(0, 0, 0, 0.35);
        CGContextSetShadowWithColor(c, CGSizeMake(0, -6 * s), 10 * s, under);
        CGColorRelease(under);
        CGContextBeginTransparencyLayer(c, NULL);
        Carton(c, full);
        CGContextEndTransparencyLayer(c);
    } else {
        // Fills its square: on a taskbar the icon has no tile to stand on.
        const CGFloat k = px / 500.0;
        CGContextTranslateCTM(c, (px - 258 * k) / 2 - 128 * k, (px - 480 * k) / 2 - 14 * k);
        CGContextScaleCTM(c, k, k);
        if (style == StyleSticker) {
            // The black outline disappears on a dark taskbar; a white edge holds the shape on any background.
            CGContextSaveGState(c);
            const CGFloat outer[] = { 186, 42, 350, 42, 344, 92, 384, 132, 386, 428, 282, 492, 138, 442, 128, 156, 192, 86 };
            Poly(c, 9, outer);
            CGColorRef w = Hex(0xFFFFFF);
            CGContextSetStrokeColorWithColor(c, w); CGContextSetFillColorWithColor(c, w);
            CGContextSetLineWidth(c, full ? 22 : 30);
            CGContextSetLineJoin(c, kCGLineJoinRound);
            CGContextDrawPath(c, kCGPathFillStroke);
            CGColorRelease(w);
            CGContextRestoreGState(c);
        }
        Carton(c, full);
    }

    CGImageRef image = CGBitmapContextCreateImage(c);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    CGImageRelease(image); CGContextRelease(c); CGColorSpaceRelease(space);
    return png;
}

static void WriteIco(NSString *path, NSArray<NSNumber *> *sizes) {
    NSMutableData *head = [NSMutableData data], *body = [NSMutableData data];
    uint16_t h[3] = { 0, CFSwapInt16HostToLittle(1), CFSwapInt16HostToLittle((uint16_t)sizes.count) };
    [head appendBytes:h length:6];
    uint32_t offset = 6 + 16 * (uint32_t)sizes.count;
    for (NSNumber *n in sizes) {
        int px = n.intValue;
        NSData *png = Render(px, StyleSticker, px >= 64);
        uint8_t w = px >= 256 ? 0 : (uint8_t)px;
        uint8_t e[4] = { w, w, 0, 0 };
        uint16_t f[2] = { CFSwapInt16HostToLittle(1), CFSwapInt16HostToLittle(32) };
        uint32_t size = CFSwapInt32HostToLittle((uint32_t)png.length), at = CFSwapInt32HostToLittle(offset + (uint32_t)body.length);
        [head appendBytes:e length:4]; [head appendBytes:f length:4]; [head appendBytes:&size length:4]; [head appendBytes:&at length:4];
        [body appendData:png];
    }
    [head appendData:body];
    [head writeToFile:path atomically:YES];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:argc > 1 ? argv[1] : "."];
        NSFileManager *fm = NSFileManager.defaultManager;

        NSString *iconset = [NSTemporaryDirectory() stringByAppendingPathComponent:@"JuiceDownloader.iconset"];
        [fm removeItemAtPath:iconset error:nil];
        [fm createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSNumber *n in @[@16, @32, @128, @256, @512]) {
            int p = n.intValue;
            [Render(p, StyleTile, p >= 64) writeToFile:[iconset stringByAppendingFormat:@"/icon_%dx%d.png", p, p] atomically:YES];
            [Render(p * 2, StyleTile, p * 2 >= 64) writeToFile:[iconset stringByAppendingFormat:@"/icon_%dx%d@2x.png", p, p] atomically:YES];
        }
        NSTask *task = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/iconutil" arguments:@[@"-c", @"icns", iconset, @"-o", [root stringByAppendingPathComponent:@"MacApp/Resources/AppIcon.icns"]]];
        [task waitUntilExit];

        WriteIco([root stringByAppendingPathComponent:@"src/JuiceDownloader/Assets/app.ico"], @[@16, @20, @24, @32, @40, @48, @64, @128, @256]);
        [Render(512, StyleSticker, YES) writeToFile:[root stringByAppendingPathComponent:@"LinuxApp/Assets/icon.png"] atomically:YES];

        // Inside the apps: the simple carton, sharp from 24 to 96 points.
        NSData *logo = Render(256, StylePlain, NO);
        [logo writeToFile:[root stringByAppendingPathComponent:@"src/JuiceDownloader/Assets/logo.png"] atomically:YES];
        [logo writeToFile:[root stringByAppendingPathComponent:@"LinuxApp/Assets/logo.png"] atomically:YES];
        [logo writeToFile:[root stringByAppendingPathComponent:@"MacApp/Resources/logo.png"] atomically:YES];
        [Render(1024, StyleTile, YES) writeToFile:[root stringByAppendingPathComponent:@"docs/logo.png"] atomically:YES];

        // A contact sheet for looking at every size.
        if (argc > 2) {
            NSString *out = [NSString stringWithUTF8String:argv[2]];
            [Render(512, StyleTile, YES) writeToFile:[out stringByAppendingPathComponent:@"mac512.png"] atomically:YES];
            [Render(64, StyleTile, YES) writeToFile:[out stringByAppendingPathComponent:@"mac64.png"] atomically:YES];
            [Render(32, StyleTile, NO) writeToFile:[out stringByAppendingPathComponent:@"mac32.png"] atomically:YES];
            [Render(512, StyleSticker, YES) writeToFile:[out stringByAppendingPathComponent:@"win512.png"] atomically:YES];
            [Render(48, StyleSticker, NO) writeToFile:[out stringByAppendingPathComponent:@"win48.png"] atomically:YES];
            [Render(32, StyleSticker, NO) writeToFile:[out stringByAppendingPathComponent:@"win32.png"] atomically:YES];
            [Render(16, StyleSticker, NO) writeToFile:[out stringByAppendingPathComponent:@"win16.png"] atomically:YES];
        }
    }
    return 0;
}
