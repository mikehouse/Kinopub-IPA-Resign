// Ad-hoc signed Catalyst apps can't use the data protection keychain (no entitlements),
// so Cinepub's tokens were silently dropped. Generic-password items are kept in a 0600
// plist instead; every other item class still goes to the real keychain.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <crt_externs.h>
#import <mach-o/getsect.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <sys/stat.h>

static NSLock *lock;
static NSMutableArray<NSDictionary *> *items;

static NSString *storePath(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/CinepubFix"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"keychain.plist"];
}

static void load(void) {
    if (items) return;
    items = [NSMutableArray arrayWithContentsOfFile:storePath()] ?: [NSMutableArray array];
}

static void save(void) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:items format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [data writeToFile:storePath() options:NSDataWritingAtomic error:nil];
    chmod(storePath().fileSystemRepresentation, 0600);
}

static BOOL isGenericPassword(CFDictionaryRef query) {
    return [((__bridge NSDictionary *)query)[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword];
}

// Attributes that identify an item; control keys (m_*, r_*, u_*) and storage policy are ignored.
static NSDictionary *identity(NSDictionary *dict) {
    NSSet *policy = [NSSet setWithObjects:(__bridge id)kSecAttrAccessible, (__bridge id)kSecAttrAccessGroup,
                     (__bridge id)kSecAttrSynchronizable, (__bridge id)kSecUseDataProtectionKeychain,
                     (__bridge id)kSecValueData, nil];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [dict enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if ([key hasPrefix:@"m_"] || [key hasPrefix:@"r_"] || [key hasPrefix:@"u_"] || [policy containsObject:key]) return;
        if (![NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListBinaryFormat_v1_0]) return;
        out[key] = value;
    }];
    return out;
}

static NSIndexSet *matches(NSDictionary *query) {
    NSDictionary *want = identity(query);
    return [items indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        for (NSString *key in want) if (![item[key] isEqual:want[key]]) return NO;
        return YES;
    }];
}

static id resultFor(NSDictionary *item, NSDictionary *query) {
    BOOL wantData = [query[(__bridge id)kSecReturnData] boolValue];
    BOOL wantAttrs = [query[(__bridge id)kSecReturnAttributes] boolValue];
    if (wantAttrs) {
        NSMutableDictionary *attrs = [item mutableCopy];
        if (!wantData) [attrs removeObjectForKey:(__bridge id)kSecValueData];
        return attrs;
    }
    return wantData ? item[(__bridge id)kSecValueData] : nil;
}

static OSStatus fix_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!isGenericPassword(attributes)) return SecItemAdd(attributes, result);
    NSDictionary *attrs = (__bridge NSDictionary *)attributes;
    [lock lock]; load();
    OSStatus status = errSecDuplicateItem;
    if (matches(attrs).count == 0) {
        NSMutableDictionary *item = [identity(attrs) mutableCopy];
        item[(__bridge id)kSecValueData] = attrs[(__bridge id)kSecValueData] ?: [NSData data];
        [items addObject:item];
        save();
        if (result) *result = (__bridge_retained CFTypeRef)resultFor(item, attrs);
        status = errSecSuccess;
    }
    [lock unlock];
    return status;
}

static OSStatus fix_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!isGenericPassword(query)) return SecItemCopyMatching(query, result);
    NSDictionary *q = (__bridge NSDictionary *)query;
    [lock lock]; load();
    NSArray *found = [items objectsAtIndexes:matches(q)];
    [lock unlock];
    if (found.count == 0) return errSecItemNotFound;
    if (result) {
        id out;
        if ([q[(__bridge id)kSecMatchLimit] isEqual:(__bridge id)kSecMatchLimitAll]) {
            NSMutableArray *all = [NSMutableArray array];
            for (NSDictionary *item in found) { id r = resultFor(item, q); if (r) [all addObject:r]; }
            out = all;
        } else {
            out = resultFor(found.firstObject, q);
        }
        *result = out ? (__bridge_retained CFTypeRef)out : NULL;
    }
    return errSecSuccess;
}

static OSStatus fix_SecItemDelete(CFDictionaryRef query) {
    if (!isGenericPassword(query)) return SecItemDelete(query);
    [lock lock]; load();
    NSIndexSet *hits = matches((__bridge NSDictionary *)query);
    if (hits.count) { [items removeObjectsAtIndexes:hits]; save(); }
    [lock unlock];
    return hits.count ? errSecSuccess : errSecItemNotFound;
}

// The app sizes its layout from UIScreen.bounds, which on a Mac is the whole display.
// Calls made from the app's own code get the window size; UIKit still sees the real screen.
static CGRect (*origScreenBounds)(id, SEL);
static uintptr_t appTextStart, appTextEnd;

static CGRect fix_screenBounds(UIScreen *self, SEL _cmd) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if (caller >= appTextStart && caller < appTextEnd) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState != UISceneActivationStateBackground)
                return ((UIWindowScene *)scene).coordinateSpace.bounds;
        }
    }
    return origScreenBounds(self, _cmd);
}

// Escape goes back like the "<" button: pop the deepest visible navigation stack.
// UIApplication is last in the responder chain, so text fields and the player still get Escape first.
static UINavigationController *visibleNavigation(UIViewController *vc) {
    UIViewController *presented = vc.presentedViewController;
    if (presented && !presented.isBeingDismissed) {
        UINavigationController *nav = visibleNavigation(presented);
        if (nav) return nav;
    }
    for (UIViewController *child in vc.childViewControllers.reverseObjectEnumerator) {
        if (!child.viewIfLoaded.window || child.view.hidden) continue;
        UINavigationController *nav = visibleNavigation(child);
        if (nav) return nav;
    }
    if ([vc isKindOfClass:UINavigationController.class] && ((UINavigationController *)vc).viewControllers.count > 1)
        return (UINavigationController *)vc;
    return nil;
}

static void goBack(UIApplication *self, SEL _cmd, id sender) {
    for (UIScene *scene in self.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow) continue;
            [visibleNavigation(window.rootViewController) popViewControllerAnimated:YES];
            return;
        }
    }
}

// Right click works as the iPad long press: it becomes a left press held for at least
// kLongPress seconds, so the app's LongPressGesture fires. Done on NSEvents, before UIKit sees them.
enum { kLeftDown = 1, kLeftUp = 2, kRightDown = 3, kRightUp = 4, kLeftDragged = 6, kRightDragged = 7 };
static const double kLongPress = 0.6;
static void (*origSendEvent)(id, SEL, id);
static double rightDownAt;

static id leftEvent(id event, NSUInteger type) {
    Class NSEvent = objc_getClass("NSEvent");
    SEL make = sel_getUid("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:");
    return ((id (*)(Class, SEL, NSUInteger, CGPoint, NSUInteger, double, NSInteger, id, NSInteger, NSInteger, float))objc_msgSend)(
        NSEvent, make, type,
        ((CGPoint (*)(id, SEL))objc_msgSend)(event, sel_getUid("locationInWindow")),
        ((NSUInteger (*)(id, SEL))objc_msgSend)(event, sel_getUid("modifierFlags")),
        NSProcessInfo.processInfo.systemUptime,
        ((NSInteger (*)(id, SEL))objc_msgSend)(event, sel_getUid("windowNumber")), nil,
        ((NSInteger (*)(id, SEL))objc_msgSend)(event, sel_getUid("eventNumber")),
        ((NSInteger (*)(id, SEL))objc_msgSend)(event, sel_getUid("clickCount")), 1.0f);
}

static void fix_sendEvent(id app, SEL _cmd, id event) {
    NSUInteger type = ((NSUInteger (*)(id, SEL))objc_msgSend)(event, sel_getUid("type"));
    if (type == kRightDown) {
        rightDownAt = NSProcessInfo.processInfo.systemUptime;
        return origSendEvent(app, _cmd, leftEvent(event, kLeftDown));
    }
    if (type == kRightDragged) return origSendEvent(app, _cmd, leftEvent(event, kLeftDragged));
    if (type == kRightUp) {
        id up = leftEvent(event, kLeftUp);
        double wait = kLongPress - (NSProcessInfo.processInfo.systemUptime - rightDownAt);
        if (wait <= 0) return origSendEvent(app, _cmd, up);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            origSendEvent(app, _cmd, up);
        });
        return;
    }
    origSendEvent(app, _cmd, event);
}

static NSArray *(*origKeyCommands)(id, SEL);

static NSArray *fix_keyCommands(UIApplication *self, SEL _cmd) {
    UIKeyCommand *escape = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cinepubGoBack:)];
    escape.wantsPriorityOverSystemBehavior = YES;
    return [origKeyCommands(self, _cmd) ?: @[] arrayByAddingObject:escape];
}

// Seasons and episode cards of Cinepub 2.35 are enlarged: frames and fonts created by their code
// are scaled per zone. The code ranges were found by logging _FrameLayout calls on a series page,
// so they are pinned to that build's UUID and other builds are left alone.
static const uint8_t kZonesBuildUUID[16] = {0x05, 0x90, 0xCB, 0x39, 0x2B, 0x18, 0x35, 0xE0,
                                            0x88, 0x0D, 0xA5, 0x34, 0xA3, 0x27, 0x4B, 0x5E};
typedef struct { uintptr_t start, end; double zoom; bool heightOnly; } Zone;
static const Zone kZones[] = {  // first match wins
    { 0x100486438, 0x100486444, 1.5 },      // episode titles: Text(title).font(.caption / .caption2)
    { 0x100487494, 0x100487498, 1.25 },     // "s1e1" episode number badge (a helper right after the cards)
    { 0x100477a10, 0x100477a14, 4.5, true },  // trailer banner: .frame(width: proxy width, height: 140)
    { 0x100478e98, 0x100478e9c, 4.5, true },  // the same banner with the TMDB backdrop
    { 0x10054d7d0, 0x10054db94, 1 / 1.3 },  // "СМОТРЕЛ" ribbon text: undo the text scale so it fits the ribbon
    { 0x100480d80, 0x1004828b0, 1.5 },      // seasons row and season tiles
    { 0x100483268, 0x1004870ec, 2 },        // episode cards
};
static const Zone kNoZone = { 0, 0, 1 };
static const uintptr_t kSeasonsBoxFrame = 0x10047e728;  // .frame(height: 320) around seasons + episodes
static uintptr_t slide;
static bool knownBuild;
uintptr_t cinepub_font_caller;  // set by the font trampolines; fonts are made on the main thread

static const Zone *zoneFor(uintptr_t caller) {
    if (!knownBuild) return &kNoZone;
    for (size_t i = 0; i < sizeof kZones / sizeof *kZones; i++)
        if (caller - slide >= kZones[i].start && caller - slide < kZones[i].end) return &kZones[i];
    return &kNoZone;
}

double cinepub_font_zoom(void) { return zoneFor(cinepub_font_caller)->zoom; }

// Called by the _FrameLayout.init trampoline with pointers to the saved width/height and their nil flags.
void cinepub_frame_zoom(double *width, uint32_t *widthIsNil, double *height, uint32_t *heightIsNil, uintptr_t caller) {
    if (knownBuild && caller - slide == kSeasonsBoxFrame) {  // let the box grow with its enlarged content
        *height = 0;
        *heightIsNil = 1;
        return;
    }
    const Zone *zone = zoneFor(caller);
    if (!(*widthIsNil & 1) && !zone->heightOnly) *width *= zone->zoom;
    if (!(*heightIsNil & 1)) *height *= zone->zoom;
}

static void findZones(const struct mach_header_64 *app) {
    const struct load_command *cmd = (const void *)(app + 1);
    for (uint32_t i = 0; i < app->ncmds; i++, cmd = (const void *)((const char *)cmd + cmd->cmdsize)) {
        if (cmd->cmd != LC_UUID || memcmp(((const struct uuid_command *)cmd)->uuid, kZonesBuildUUID, 16)) continue;
        slide = (uintptr_t)app - 0x100000000;
        knownBuild = true;
    }
}

__attribute__((constructor)) static void init(void) {
    lock = [NSLock new];
    findZones(_NSGetMachExecuteHeader());
    unsigned long size = 0;
    appTextStart = (uintptr_t)getsegmentdata(_NSGetMachExecuteHeader(), "__TEXT", &size);
    appTextEnd = appTextStart + size;
    Method bounds = class_getInstanceMethod(UIScreen.class, @selector(bounds));
    origScreenBounds = (CGRect (*)(id, SEL))method_setImplementation(bounds, (IMP)fix_screenBounds);

    Class nsApp = objc_getClass("UINSApplication") ?: objc_getClass("NSApplication");
    Method sendEvent = class_getInstanceMethod(nsApp, sel_getUid("sendEvent:"));
    if (sendEvent) origSendEvent = (void (*)(id, SEL, id))method_setImplementation(sendEvent, (IMP)fix_sendEvent);

    // Override keyCommands on UIApplication only, not on every UIResponder.
    origKeyCommands = (NSArray *(*)(id, SEL))class_getMethodImplementation(UIApplication.class, @selector(keyCommands));
    class_addMethod(UIApplication.class, @selector(cinepubGoBack:), (IMP)goBack, "v@:@");
    if (!class_addMethod(UIApplication.class, @selector(keyCommands), (IMP)fix_keyCommands, "@@:")) {
        origKeyCommands = (NSArray *(*)(id, SEL))method_setImplementation(
            class_getInstanceMethod(UIApplication.class, @selector(keyCommands)), (IMP)fix_keyCommands);
    }

    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillConnectNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (![note.object isKindOfClass:UIWindowScene.class]) return;
        // Content under a hidden title bar gets a top safe-area inset, like the iPad status bar the layout expects.
        UITitlebar *titlebar = ((UIWindowScene *)note.object).titlebar;
        titlebar.titleVisibility = UITitlebarTitleVisibilityHidden;
        titlebar.toolbar = nil;
    }];
}

// SwiftUI replacements live in EnvFallback.swift, TextScale.swift and tramp.s.
// Font replacements are reached through *_tramp in tramp.s, which records the caller first.
extern void cinepub_view_env(void);
extern void cinepub_env_init(void);
extern void cinepub_frame_layout(void);
extern void cinepub_font_system_tramp(void);
extern void cinepub_font_system_optional_tramp(void);
extern void orig_frame_layout(void) __asm__("_$s7SwiftUI12_FrameLayoutV5width6height9alignmentAC12CoreGraphics7CGFloatVSg_AjA9AlignmentVtcfC");
extern void orig_font_system(void) __asm__("_$s7SwiftUI4FontV6system4size6weight6designAC12CoreGraphics7CGFloatV_AC6WeightVAC6DesignOtFZ");
extern void orig_font_system_optional(void) __asm__("_$s7SwiftUI4FontV6system4size6weight6designAC12CoreGraphics7CGFloatV_AC6WeightVSgAC6DesignOSgtFZ");

// Font.<style> getters: $s7SwiftUI4FontV<len><name>ACvgZ
#define TEXT_STYLES(X) X(largeTitle, "10largeTitle") X(title, "5title") X(title2, "6title2") X(title3, "6title3") \
    X(headline, "8headline") X(body, "4body") X(callout, "7callout") X(subheadline, "11subheadline") \
    X(footnote, "8footnote") X(caption, "7caption") X(caption2, "8caption2")
#define DECLARE_STYLE(name, mangled) extern void cinepub_font_##name##_tramp(void); \
    extern void orig_font_##name(void) __asm__("_$s7SwiftUI4FontV" mangled "ACvgZ");
#define INTERPOSE_STYLE(name, mangled) { (const void *)cinepub_font_##name##_tramp, (const void *)orig_font_##name },
TEXT_STYLES(DECLARE_STYLE)
extern void orig_view_env(void) __asm__("_$s7SwiftUI4ViewPAAE11environmentyQrqd__SgRld__C11Observation10ObservableRd__lF");
extern void orig_env_init(void) __asm__("_$s7SwiftUI11EnvironmentVyACyxGxmcRlzC11Observation10ObservableRzlufC");

// dyld interposing: the app's calls go to these replacements.
__attribute__((used, section("__DATA,__interpose"))) static const void *interposers[][2] = {
    { (const void *)fix_SecItemAdd, (const void *)SecItemAdd },
    { (const void *)fix_SecItemCopyMatching, (const void *)SecItemCopyMatching },
    { (const void *)fix_SecItemDelete, (const void *)SecItemDelete },
    { (const void *)cinepub_view_env, (const void *)orig_view_env },
    { (const void *)cinepub_env_init, (const void *)orig_env_init },
    { (const void *)cinepub_frame_layout, (const void *)orig_frame_layout },
    { (const void *)cinepub_font_system_tramp, (const void *)orig_font_system },
    { (const void *)cinepub_font_system_optional_tramp, (const void *)orig_font_system_optional },
    TEXT_STYLES(INTERPOSE_STYLE)
};
