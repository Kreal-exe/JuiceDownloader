// JuiceDownloader for macOS: the app delegate, the menu bar and the command line (App.xaml.cs).
//
//   --page <name>      open on overview, albums, unreleased, compilations, sessionEdits, originals, studio, instrumentals,
//                      remixes, snippets, media, rules, lyrics, gaps, settings or about; with --capture, shoot only that page
//   --theme <mode>     dark, light or system for this run
//   --lang <code>      interface language for this run
//   --capture <dir>    save a PNG of every page into <dir>, quit. Nothing is downloaded; the player shot plays the first
//                      track of Albums for a moment, and the Missing Lyrics shot checks the download folder.
#import <Cocoa/Cocoa.h>
#import "CCControls.h"
#import "CCModel.h"
#import "CCWindow.h"

@interface CCAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation CCAppDelegate {
    CCWindowController *_window;
}

static NSString *Argument(NSString *name) {
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger i = [args indexOfObject:name];
    return i != NSNotFound && i + 1 < args.count ? args[i + 1] : nil;
}

static NSMenuItem *Item(NSString *key, SEL action, NSString *keyEquivalent) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:L(key) action:action keyEquivalent:keyEquivalent];
    item.representedObject = key;
    return item;
}

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];

    NSMenu *app = [NSMenu new];
    [app addItem:Item(@"menu.about", @selector(showAbout:), @"")];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:Item(@"menu.settings", @selector(showSettings:), @",")];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:Item(@"menu.hide", @selector(hide:), @"h")];
    NSMenuItem *hideOthers = Item(@"menu.hideOthers", @selector(hideOtherApplications:), @"h");
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [app addItem:hideOthers];
    [app addItem:Item(@"menu.showAll", @selector(unhideAllApplications:), @"")];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:Item(@"menu.quit", @selector(terminate:), @"q")];
    NSMenuItem *appItem = [NSMenuItem new];
    appItem.submenu = app;
    [bar addItem:appItem];

    NSMenu *edit = [[NSMenu alloc] initWithTitle:L(@"menu.edit")];
    [edit addItem:Item(@"menu.undo", @selector(undo:), @"z")];
    NSMenuItem *redo = Item(@"menu.redo", @selector(redo:), @"z");
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:redo];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItem:Item(@"menu.cut", @selector(cut:), @"x")];
    [edit addItem:Item(@"menu.copy", @selector(copy:), @"c")];
    [edit addItem:Item(@"menu.paste", @selector(paste:), @"v")];
    [edit addItem:Item(@"menu.selectAll", @selector(selectAll:), @"a")];
    NSMenuItem *editItem = [NSMenuItem new];
    editItem.submenu = edit;
    editItem.representedObject = @"menu.edit";
    [bar addItem:editItem];

    NSMenu *view = [[NSMenu alloc] initWithTitle:L(@"menu.view")];
    for (NSInteger i = 0; i < CCPageCount; i++) {
        // Shortcuts for the first nine: Overview to Instrumentals.
        NSString *key = i < 9 ? [NSString stringWithFormat:@"%ld", (long)i + 1] : @"";
        NSMenuItem *item = Item([@"nav." stringByAppendingString:CCPageName(i)], @selector(showPageFromMenu:), key);
        item.tag = i;
        [view addItem:item];
    }
    [view addItem:NSMenuItem.separatorItem];
    [view addItem:Item(@"catalog.refresh", @selector(refreshCatalog:), @"r")];
    NSMenuItem *viewItem = [NSMenuItem new];
    viewItem.submenu = view;
    viewItem.representedObject = @"menu.view";
    [bar addItem:viewItem];

    NSMenu *window = [[NSMenu alloc] initWithTitle:L(@"menu.window")];
    [window addItem:Item(@"menu.minimize", @selector(performMiniaturize:), @"m")];
    [window addItem:Item(@"menu.zoom", @selector(performZoom:), @"")];
    [window addItem:Item(@"menu.close", @selector(performClose:), @"w")];
    NSMenuItem *windowItem = [NSMenuItem new];
    windowItem.submenu = window;
    windowItem.representedObject = @"menu.window";
    [bar addItem:windowItem];
    NSApp.windowsMenu = window;

    NSApp.mainMenu = bar;
}

- (void)relabel:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.representedObject isKindOfClass:NSString.class]) {
            item.title = L(item.representedObject);
            item.submenu.title = item.title;
        }
        if (item.submenu) [self relabel:item.submenu];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    CCModel *model = CCModel.shared;
    CCSettings *settings = model.settings;
    [CCLocalization.shared setLanguage:Argument(@"--lang") ?: settings.language];
    CCSetMotionEnabled(settings.animations);
    [CCTheme applyMode:Argument(@"--theme") ?: settings.theme];

    NSString *page = Argument(@"--page");
    for (NSInteger i = 0; i < CCPageCount; i++)
        if (page && [page caseInsensitiveCompare:CCPageName(i)] == NSOrderedSame) model.page = (CCPage)i;

    [self buildMenu];
    [NSNotificationCenter.defaultCenter addObserverForName:CCLanguageDidChangeNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { [self relabel:NSApp.mainMenu]; }];

    _window = [CCWindowController new];
    [_window showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [model start];

    NSString *capture = Argument(@"--capture");
    if (capture) [_window captureInto:capture.stringByStandardizingPath];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)showAbout:(id)sender { CCModel.shared.page = CCPageAbout; }
- (void)showSettings:(id)sender { CCModel.shared.page = CCPageSettings; }
- (void)showPageFromMenu:(NSMenuItem *)sender { CCModel.shared.page = (CCPage)sender.tag; }
- (void)refreshCatalog:(id)sender { [CCModel.shared refreshCatalog]; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        CCAppDelegate *delegate = [CCAppDelegate new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        [app run];
    }
    return 0;
}
