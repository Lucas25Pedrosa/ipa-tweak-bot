#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdbool.h>

// XLegacyGlass prototype for X 12.21.
// Goal: reproduce the X 12.20 separation between global Liquid Glass
// and the internal redesign/navigation bootstrap introduced in 12.21.
// Build revision: 2.

static _Atomic int gRootBuildDepth = 0;
static _Atomic bool gRootReady = false;

typedef BOOL (*Bool0IMP)(id, SEL);
typedef void (*Void1IMP)(id, SEL, id);
typedef void (*Void4IMP)(id, SEL, id, id, id, id);
typedef id (*Id1IMP)(id, SEL, id);

static Bool0IMP gOrigIsLiquidGlassEnabled = NULL;
static Void1IMP gOrigHandleRootSetup = NULL;
static Void4IMP gOrigConfigureRoot = NULL;
static Void1IMP gOrigSceneSetup = NULL;
static Id1IMP gOrigRootForAccount = NULL;

static inline void XLGEnterRootBuild(void) {
    atomic_fetch_add_explicit(&gRootBuildDepth, 1, memory_order_seq_cst);
}

static inline void XLGLeaveRootBuild(bool markReady) {
    int previous = atomic_fetch_sub_explicit(&gRootBuildDepth, 1, memory_order_seq_cst);
    if (previous <= 1) {
        atomic_store_explicit(&gRootBuildDepth, 0, memory_order_seq_cst);
        if (markReady) {
            atomic_store_explicit(&gRootReady, true, memory_order_seq_cst);
        }
    }
}

static BOOL XLGIsLiquidGlassEnabled(id self, SEL _cmd) {
    // During 12.21 root bootstrap expose Glass as disabled so the complete
    // legacy/root content tree can be assembled. Once root setup is finished,
    // expose Glass as enabled for the normal appearance path.
    if (!atomic_load_explicit(&gRootReady, memory_order_seq_cst) ||
        atomic_load_explicit(&gRootBuildDepth, memory_order_seq_cst) > 0) {
        return NO;
    }

    return YES;
}

static void XLGHandleRootSetup(id self, SEL _cmd, id account) {
    XLGEnterRootBuild();
    gOrigHandleRootSetup(self, _cmd, account);
    XLGLeaveRootBuild(true);
}

static void XLGConfigureRoot(id self,
                             SEL _cmd,
                             id selectorValue,
                             id window,
                             id cache,
                             id stopwatch) {
    XLGEnterRootBuild();
    gOrigConfigureRoot(self, _cmd, selectorValue, window, cache, stopwatch);
    XLGLeaveRootBuild(true);
}

static void XLGSceneSetup(id self, SEL _cmd, id account) {
    XLGEnterRootBuild();
    gOrigSceneSetup(self, _cmd, account);
    XLGLeaveRootBuild(true);
}

static id XLGRootForAccount(id self, SEL _cmd, id account) {
    XLGEnterRootBuild();
    id result = gOrigRootForAccount(self, _cmd, account);
    XLGLeaveRootBuild(result != nil);
    return result;
}

static bool XLGHookInstanceMethod(const char *className,
                                  const char *selectorName,
                                  IMP replacement,
                                  IMP *originalOut) {
    Class cls = objc_getClass(className);
    if (!cls) {
        return false;
    }

    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return false;
    }

    IMP original = method_getImplementation(method);
    if (!original) {
        return false;
    }

    if (originalOut) {
        *originalOut = original;
    }
    method_setImplementation(method, replacement);
    return true;
}

static bool XLGHookClassMethod(const char *className,
                               const char *selectorName,
                               IMP replacement,
                               IMP *originalOut) {
    Class cls = objc_getClass(className);
    if (!cls) {
        return false;
    }

    Class meta = object_getClass(cls);
    if (!meta) {
        return false;
    }

    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(meta, selector);
    if (!method) {
        return false;
    }

    IMP original = method_getImplementation(method);
    if (!original) {
        return false;
    }

    if (originalOut) {
        *originalOut = original;
    }
    method_setImplementation(method, replacement);
    return true;
}

__attribute__((constructor))
static void XLegacyGlassInitialize(void) {
    // Swift runtime name for XAppearance.Appearance in X 12.21.
    XLGHookClassMethod("_TtC11XAppearance10Appearance",
                       "isLiquidGlassEnabled",
                       (IMP)XLGIsLiquidGlassEnabled,
                       (IMP *)&gOrigIsLiquidGlassEnabled);

    XLGHookInstanceMethod("T1HostViewController",
                          "handleRootViewControllerSetupWithAccount:",
                          (IMP)XLGHandleRootSetup,
                          (IMP *)&gOrigHandleRootSetup);

    XLGHookInstanceMethod("T1AppEventHandlerUtils",
                          "configureRootViewControllerFromSelector:window:homeTimelineUpdateDisplaySourceCache:stopwatch:",
                          (IMP)XLGConfigureRoot,
                          (IMP *)&gOrigConfigureRoot);

    XLGHookInstanceMethod("T1WindowSceneRootViewController",
                          "setupWithAccount:",
                          (IMP)XLGSceneSetup,
                          (IMP *)&gOrigSceneSetup);

    XLGHookInstanceMethod("T1WindowSceneRootViewController",
                          "rootViewControllerForAccount:",
                          (IMP)XLGRootForAccount,
                          (IMP *)&gOrigRootForAccount);
}
