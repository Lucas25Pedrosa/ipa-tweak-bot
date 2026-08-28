#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// XLegacyNativeGlass prototype for X 12.21.
// Reintroduces the native UITabBar bridge that existed in X 12.20's
// T1TabBarViewController without touching XAppearance or root/navigation gates.

static char kXLNativeTabBarKey;
static BOOL gInstalled = NO;

typedef void (*Void0IMP)(id, SEL);
typedef void (*VoidObjIMP)(id, SEL, id);
typedef void (*VoidIntIMP)(id, SEL, NSInteger);
typedef id (*Id0IMP)(id, SEL);
typedef NSInteger (*Int0IMP)(id, SEL);

static Void0IMP gOrigViewDidLoad = NULL;
static Void0IMP gOrigViewWillLayoutSubviews = NULL;
static VoidObjIMP gOrigSetTabViews = NULL;
static VoidIntIMP gOrigSetSelectedTabIndex = NULL;

static inline id XLGSendId(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static inline NSInteger XLGSendInteger(id obj, SEL sel, NSInteger fallback) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return fallback;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel);
}

static inline BOOL XLGSendBool(id obj, SEL sel, BOOL fallback) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

static UITabBar *XLGNativeTabBar(id controller) {
    return objc_getAssociatedObject(controller, &kXLNativeTabBarKey);
}

static NSArray *XLGTabViews(id controller) {
    id value = XLGSendId(controller, sel_registerName("tabViews"));
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static UIImage *XLGImageForTabModel(id model, BOOL selected) {
    NSArray<NSString *> *objectSelectors = selected
        ? @[@"selectedImage", @"image", @"largeContentImage"]
        : @[@"image", @"largeContentImage"];

    for (NSString *name in objectSelectors) {
        id value = XLGSendId(model, NSSelectorFromString(name));
        if ([value isKindOfClass:[UIImage class]]) return value;
    }

    NSArray<NSString *> *nameSelectors = selected
        ? @[@"selectedImageName", @"imageName"]
        : @[@"imageName"];

    for (NSString *name in nameSelectors) {
        id value = XLGSendId(model, NSSelectorFromString(name));
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            UIImage *image = [UIImage imageNamed:value];
            if (image) return image;
        }
    }

    return nil;
}

static NSString *XLGTitleForTabModel(id model) {
    id title = XLGSendId(model, sel_registerName("title"));
    if ([title isKindOfClass:[NSString class]]) return title;

    id label = XLGSendId(model, sel_registerName("accessibilityLabel"));
    if ([label isKindOfClass:[NSString class]]) return label;

    return nil;
}

static void XLGSyncSelection(id controller) {
    UITabBar *bar = XLGNativeTabBar(controller);
    if (!bar || bar.items.count == 0) return;

    NSInteger index = XLGSendInteger(controller, sel_registerName("selectedTabIndex"), NSNotFound);
    if (index >= 0 && index < (NSInteger)bar.items.count) {
        bar.selectedItem = bar.items[(NSUInteger)index];
    }
}

static void XLGSyncBadges(id controller) {
    UITabBar *bar = XLGNativeTabBar(controller);
    NSArray *models = XLGTabViews(controller);
    NSUInteger count = MIN(models.count, bar.items.count);

    for (NSUInteger i = 0; i < count; i++) {
        id model = models[i];
        UITabBarItem *item = bar.items[i];

        NSInteger badgeCount = XLGSendInteger(model, sel_registerName("badgeCount"), 0);
        BOOL unread = XLGSendBool(model, sel_registerName("hasUnreadContent"), NO);
        if (badgeCount > 0) {
            item.badgeValue = [NSString stringWithFormat:@"%ld", (long)badgeCount];
        } else if (unread) {
            item.badgeValue = @"•";
        } else {
            item.badgeValue = nil;
        }
    }
}

static void XLGSyncItems(id controller) {
    UITabBar *bar = XLGNativeTabBar(controller);
    if (!bar) return;

    NSArray *models = XLGTabViews(controller);
    NSMutableArray<UITabBarItem *> *items = [NSMutableArray arrayWithCapacity:models.count];

    [models enumerateObjectsUsingBlock:^(id model, NSUInteger idx, BOOL *stop) {
        UIImage *image = XLGImageForTabModel(model, NO);
        UIImage *selected = XLGImageForTabModel(model, YES);
        NSString *title = XLGTitleForTabModel(model);

        UITabBarItem *item = [[UITabBarItem alloc] initWithTitle:title
                                                           image:image
                                                   selectedImage:selected ?: image];
        item.tag = (NSInteger)idx;

        id accessibilityLabel = XLGSendId(model, sel_registerName("accessibilityLabel"));
        if ([accessibilityLabel isKindOfClass:[NSString class]]) {
            item.accessibilityLabel = accessibilityLabel;
        }

        id largeContentImage = XLGSendId(model, sel_registerName("largeContentImage"));
        if ([largeContentImage isKindOfClass:[UIImage class]]) {
            item.largeContentSizeImage = largeContentImage;
        }

        [items addObject:item];
    }];

    [bar setItems:items animated:NO];
    XLGSyncSelection(controller);
    XLGSyncBadges(controller);
}

static void XLGLayout(id controller) {
    UITabBar *bar = XLGNativeTabBar(controller);
    if (!bar) return;

    UIView *view = XLGSendId(controller, sel_registerName("view"));
    if (![view isKindOfClass:[UIView class]]) return;

    UIEdgeInsets safe = view.safeAreaInsets;
    CGFloat height = 49.0 + MAX(0.0, safe.bottom);
    CGRect bounds = view.bounds;
    bar.frame = CGRectMake(CGRectGetMinX(bounds),
                           CGRectGetMaxY(bounds) - height,
                           CGRectGetWidth(bounds),
                           height);
    [view bringSubviewToFront:bar];

    // Keep the original custom bar alive for the controller's internal layout,
    // but make it visually/touch-wise inert under the restored native bar.
    id custom = XLGSendId(controller, sel_registerName("tabBar"));
    if ([custom isKindOfClass:[UIView class]] && custom != bar) {
        UIView *customView = custom;
        customView.alpha = 0.0;
        customView.userInteractionEnabled = NO;
    }
}

static void XLGEnsureNativeTabBar(id controller) {
    if (XLGNativeTabBar(controller)) {
        XLGSyncItems(controller);
        XLGLayout(controller);
        return;
    }

    UIView *view = XLGSendId(controller, sel_registerName("view"));
    if (![view isKindOfClass:[UIView class]]) return;

    UITabBar *bar = [[UITabBar alloc] initWithFrame:CGRectZero];
    bar.delegate = (id<UITabBarDelegate>)controller;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
    [appearance configureWithDefaultBackground];
    bar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        bar.scrollEdgeAppearance = appearance;
    }

    objc_setAssociatedObject(controller, &kXLNativeTabBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [view addSubview:bar];

    XLGSyncItems(controller);
    XLGLayout(controller);
}

static void XLGViewDidLoad(id self, SEL _cmd) {
    gOrigViewDidLoad(self, _cmd);
    XLGEnsureNativeTabBar(self);
}

static void XLGViewWillLayoutSubviews(id self, SEL _cmd) {
    gOrigViewWillLayoutSubviews(self, _cmd);
    XLGLayout(self);
    XLGSyncSelection(self);
    XLGSyncBadges(self);
}

static void XLGSetTabViews(id self, SEL _cmd, id views) {
    gOrigSetTabViews(self, _cmd, views);
    XLGEnsureNativeTabBar(self);
}

static void XLGSetSelectedTabIndex(id self, SEL _cmd, NSInteger index) {
    gOrigSetSelectedTabIndex(self, _cmd, index);
    XLGSyncSelection(self);
}

// This selector existed on T1TabBarViewController in X 12.20 and was removed in 12.21.
static void XLGTabBarDidSelectItem(id self, SEL _cmd, UITabBar *tabBar, UITabBarItem *item) {
    NSInteger index = item.tag;
    NSArray *models = XLGTabViews(self);
    if (index < 0 || index >= (NSInteger)models.count) return;

    // Use the real 12.21 selection method so all existing navigation/content logic stays intact.
    if (gOrigSetSelectedTabIndex) {
        gOrigSetSelectedTabIndex(self, sel_registerName("setSelectedTabIndex:"), index);
        XLGSyncSelection(self);
    }
}

static BOOL XLGReplaceMethod(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    IMP original = method_getImplementation(method);
    if (!original) return NO;
    if (originalOut) *originalOut = original;
    method_setImplementation(method, replacement);
    return YES;
}

static void XLGInstallIfPossible(void) {
    if (gInstalled) return;

    Class cls = objc_getClass("T1TabBarViewController");
    if (!cls) return;

    Method viewDidLoad = class_getInstanceMethod(cls, sel_registerName("viewDidLoad"));
    Method layout = class_getInstanceMethod(cls, sel_registerName("viewWillLayoutSubviews"));
    Method setViews = class_getInstanceMethod(cls, sel_registerName("setTabViews:"));
    Method setIndex = class_getInstanceMethod(cls, sel_registerName("setSelectedTabIndex:"));
    if (!viewDidLoad || !layout || !setViews || !setIndex) return;

    // Exact 12.21 Objective-C type encodings verified before installing hooks.
    if (strcmp(method_getTypeEncoding(viewDidLoad), "v16@0:8") != 0) return;
    if (strcmp(method_getTypeEncoding(layout), "v16@0:8") != 0) return;
    if (strcmp(method_getTypeEncoding(setViews), "v24@0:8@16") != 0) return;
    if (strcmp(method_getTypeEncoding(setIndex), "v24@0:8q16") != 0) return;

    if (!XLGReplaceMethod(cls, sel_registerName("viewDidLoad"), (IMP)XLGViewDidLoad, (IMP *)&gOrigViewDidLoad)) return;
    if (!XLGReplaceMethod(cls, sel_registerName("viewWillLayoutSubviews"), (IMP)XLGViewWillLayoutSubviews, (IMP *)&gOrigViewWillLayoutSubviews)) return;
    if (!XLGReplaceMethod(cls, sel_registerName("setTabViews:"), (IMP)XLGSetTabViews, (IMP *)&gOrigSetTabViews)) return;
    if (!XLGReplaceMethod(cls, sel_registerName("setSelectedTabIndex:"), (IMP)XLGSetSelectedTabIndex, (IMP *)&gOrigSetSelectedTabIndex)) return;

    SEL didSelect = sel_registerName("tabBar:didSelectItem:");
    if (!class_getInstanceMethod(cls, didSelect)) {
        class_addMethod(cls, didSelect, (IMP)XLGTabBarDidSelectItem, "v32@0:8@16@24");
    }

    gInstalled = YES;
}

__attribute__((constructor))
static void XLegacyNativeGlassInitialize(void) {
    // Objective-C classes are normally registered before dylib initializers, so try immediately.
    XLGInstallIfPossible();

    // Harmless second chance in case T1Twitter registration completes later.
    dispatch_async(dispatch_get_main_queue(), ^{
        XLGInstallIfPossible();
    });
}
