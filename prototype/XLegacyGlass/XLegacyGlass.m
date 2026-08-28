#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// XLegacyGlassBridge prototype for X 12.21.
// Recreates the safest part of the X 12.20 bridge without touching Swift gates
// or re-parenting the app's content controllers.

static const void *kXLGBarKey = &kXLGBarKey;
static const void *kXLGDelegateKey = &kXLGDelegateKey;
static const void *kXLGOriginalBarKey = &kXLGOriginalBarKey;

typedef void (*Void0IMP)(id, SEL);
static Void0IMP gOrigViewDidLayoutSubviews = NULL;

static id XLGSendId(id obj, const char *selName) {
    if (!obj) return nil;
    SEL sel = sel_registerName(selName);
    if (![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static NSInteger XLGIndexOfItem(UITabBar *bar, UITabBarItem *item) {
    NSArray<UITabBarItem *> *items = bar.items;
    NSUInteger idx = [items indexOfObjectIdenticalTo:item];
    return idx == NSNotFound ? -1 : (NSInteger)idx;
}

@interface XLegacyGlassTabDelegate : NSObject <UITabBarDelegate>
@property(nonatomic, assign) id owner;
@property(nonatomic, assign) id originalTabBarController;
@end

@implementation XLegacyGlassTabDelegate
- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    id owner = self.owner;
    if (!owner) return;

    NSInteger index = XLGIndexOfItem(tabBar, item);
    if (index < 0) return;

    SEL selectSel = sel_registerName("tabBarViewController:selectTabAtIndex:withView:");
    if ([owner respondsToSelector:selectSel]) {
        ((void (*)(id, SEL, id, NSInteger, id))objc_msgSend)(
            owner, selectSel, self.originalTabBarController, index, tabBar
        );
        return;
    }

    id tabVC = self.originalTabBarController;
    SEL setIndex = sel_registerName("setSelectedIndex:");
    if (tabVC && [tabVC respondsToSelector:setIndex]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(tabVC, setIndex, (NSUInteger)index);
    }
}
@end

static void XLGLayoutBar(id self) {
    if (![self isKindOfClass:[UIViewController class]]) return;

    UIViewController *vc = (UIViewController *)self;
    UITabBar *bar = objc_getAssociatedObject(self, kXLGBarKey);
    if (!bar) return;

    UIView *view = vc.view;
    if (!view) return;

    CGFloat height = MAX(49.0, bar.intrinsicContentSize.height);
    UIEdgeInsets insets = view.safeAreaInsets;
    height += insets.bottom;
    bar.frame = CGRectMake(0.0,
                           CGRectGetHeight(view.bounds) - height,
                           CGRectGetWidth(view.bounds),
                           height);
    [view bringSubviewToFront:bar];
}

static void XLGInstallBridgeIfNeeded(id self) {
    if (objc_getAssociatedObject(self, kXLGBarKey)) return;
    if (![self isKindOfClass:[UIViewController class]]) return;

    UIViewController *owner = (UIViewController *)self;

    id tabBarVC = XLGSendId(self, "tabBarViewController");
    if (!tabBarVC) return;

    id originalBarObject = XLGSendId(tabBarVC, "tabBar");
    if (![originalBarObject isKindOfClass:[UITabBar class]]) return;

    UITabBar *originalBar = (UITabBar *)originalBarObject;
    NSArray<UITabBarItem *> *items = originalBar.items;
    if (items.count == 0) return;

    UITabBar *glassBar = [[UITabBar alloc] initWithFrame:CGRectZero];
    glassBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    glassBar.items = items;

    if (originalBar.selectedItem && [items containsObject:originalBar.selectedItem]) {
        glassBar.selectedItem = originalBar.selectedItem;
    }

    XLegacyGlassTabDelegate *delegate = [XLegacyGlassTabDelegate new];
    delegate.owner = self;
    delegate.originalTabBarController = tabBarVC;
    glassBar.delegate = delegate;

    objc_setAssociatedObject(self, kXLGBarKey, glassBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kXLGDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kXLGOriginalBarKey, originalBar, OBJC_ASSOCIATION_ASSIGN);

    [owner.view addSubview:glassBar];
    XLGLayoutBar(self);

    // Hide only the old bar itself. The original controller/content hierarchy remains intact.
    originalBar.hidden = YES;
}

static void XLGViewDidLayoutSubviews(id self, SEL _cmd) {
    if (gOrigViewDidLayoutSubviews) {
        gOrigViewDidLayoutSubviews(self, _cmd);
    }
    XLGInstallBridgeIfNeeded(self);
    XLGLayoutBar(self);
}

static BOOL XLGHookVoid0(const char *className,
                         const char *selectorName,
                         IMP replacement,
                         IMP *originalOut) {
    Class cls = objc_getClass(className);
    if (!cls) return NO;

    SEL sel = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP old = method_getImplementation(method);
    if (!old) return NO;
    if (originalOut) *originalOut = old;
    method_setImplementation(method, replacement);
    return YES;
}

__attribute__((constructor))
static void XLegacyGlassBridgeInitialize(void) {
    // Stable UIViewController signature. No private bootstrap hooks and no Swift gate hooks.
    XLGHookVoid0("T1TabbedAppNavigationViewController",
                 "viewDidLayoutSubviews",
                 (IMP)XLGViewDidLayoutSubviews,
                 (IMP *)&gOrigViewDidLayoutSubviews);
}
