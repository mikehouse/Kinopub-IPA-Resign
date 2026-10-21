// Ad-hoc signed Catalyst apps can't use the data protection keychain (no entitlements),
// so Cinepub's tokens were silently dropped. Generic-password items are kept in a 0600
// plist instead; every other item class still goes to the real keychain.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <crt_externs.h>
#import <mach-o/getsect.h>
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

static NSArray *(*origKeyCommands)(id, SEL);

static NSArray *fix_keyCommands(UIApplication *self, SEL _cmd) {
    UIKeyCommand *escape = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cinepubGoBack:)];
    escape.wantsPriorityOverSystemBehavior = YES;
    return [origKeyCommands(self, _cmd) ?: @[] arrayByAddingObject:escape];
}

__attribute__((constructor)) static void init(void) {
    lock = [NSLock new];
    unsigned long size = 0;
    appTextStart = (uintptr_t)getsegmentdata(_NSGetMachExecuteHeader(), "__TEXT", &size);
    appTextEnd = appTextStart + size;
    Method bounds = class_getInstanceMethod(UIScreen.class, @selector(bounds));
    origScreenBounds = (CGRect (*)(id, SEL))method_setImplementation(bounds, (IMP)fix_screenBounds);

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
extern void cinepub_view_env(void);
extern void cinepub_env_init(void);
extern void cinepub_font_system(void);
extern void cinepub_font_system_optional(void);
extern void orig_font_system(void) __asm__("_$s7SwiftUI4FontV6system4size6weight6designAC12CoreGraphics7CGFloatV_AC6WeightVAC6DesignOtFZ");
extern void orig_font_system_optional(void) __asm__("_$s7SwiftUI4FontV6system4size6weight6designAC12CoreGraphics7CGFloatV_AC6WeightVSgAC6DesignOSgtFZ");

// Font.<style> getters: $s7SwiftUI4FontV<len><name>ACvgZ
#define TEXT_STYLES(X) X(largeTitle, "10largeTitle") X(title, "5title") X(title2, "6title2") X(title3, "6title3") \
    X(headline, "8headline") X(body, "4body") X(callout, "7callout") X(subheadline, "11subheadline") \
    X(footnote, "8footnote") X(caption, "7caption") X(caption2, "8caption2")
#define DECLARE_STYLE(name, mangled) extern void cinepub_font_##name(void); \
    extern void orig_font_##name(void) __asm__("_$s7SwiftUI4FontV" mangled "ACvgZ");
#define INTERPOSE_STYLE(name, mangled) { (const void *)cinepub_font_##name, (const void *)orig_font_##name },
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
    { (const void *)cinepub_font_system, (const void *)orig_font_system },
    { (const void *)cinepub_font_system_optional, (const void *)orig_font_system_optional },
    TEXT_STYLES(INTERPOSE_STYLE)
};
