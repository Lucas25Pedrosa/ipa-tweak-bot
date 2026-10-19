#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <sys/mman.h>
#import <sys/time.h>
#import <fcntl.h>
#import <unistd.h>
#import <pthread.h>
#import <dispatch/dispatch.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#define SPP_VERSION "SwiftgramPostboxProbe 0.2 Attribution"
#define SPP_TARGET_OFFSET ((uintptr_t)0x908638)
#define SPP_SAMPLE_BYTES 32
#define SPP_EXPECTED_TC_UUID "d8a0c19b-0918-336a-a542-9e30416542ec"

static int gLogFD = -1;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static __thread int gInHook = 0;
static uintptr_t gTarget = 0;
static uintptr_t gTargetPage = 0;
static size_t gPageSize = 0;
static uint8_t gOriginal[SPP_SAMPLE_BYTES];
static uint8_t gLast[SPP_SAMPLE_BYTES];
static volatile bool gTargetReady = false;
static volatile bool gMutationSeen = false;
static uint64_t gStartUsec = 0;
static dispatch_source_t gTimer = NULL;

static uint64_t nowUsec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return ((uint64_t)tv.tv_sec * 1000000ULL) + (uint64_t)tv.tv_usec;
}

static void writeRaw(const char *text, bool syncNow) {
    if (gLogFD < 0 || !text) return;
    pthread_mutex_lock(&gLogLock);
    (void)write(gLogFD, text, strlen(text));
    if (syncNow) (void)fsync(gLogFD);
    pthread_mutex_unlock(&gLogLock);
}

static void logV(bool syncNow, const char *fmt, va_list ap) {
    if (gLogFD < 0 || !fmt) return;
    char body[4096];
    char line[4608];
    if (vsnprintf(body, sizeof(body), fmt, ap) < 0) return;
    uint64_t elapsed = gStartUsec ? nowUsec() - gStartUsec : 0;
    if (snprintf(line, sizeof(line),
                 "[SPP2] +%llu.%03llums %s\n",
                 (unsigned long long)(elapsed / 1000ULL),
                 (unsigned long long)(elapsed % 1000ULL),
                 body) <= 0) return;
    writeRaw(line, syncNow);
}

static void logLine(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    logV(false, fmt, ap);
    va_end(ap);
}

static void logCritical(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    logV(true, fmt, ap);
    va_end(ap);
}

static void bytesHex(const void *ptr, size_t len, char *out, size_t cap) {
    static const char h[] = "0123456789abcdef";
    if (!out || cap == 0) return;
    out[0] = '\0';
    if (!ptr) return;
    size_t max = (cap - 1) / 2;
    if (len > max) len = max;
    const uint8_t *p = ptr;
    for (size_t i = 0; i < len; i++) {
        out[i * 2] = h[p[i] >> 4];
        out[i * 2 + 1] = h[p[i] & 0xf];
    }
    out[len * 2] = '\0';
}

static const char *baseName(const char *path) {
    if (!path) return "?";
    const char *p = strrchr(path, '/');
    return p ? p + 1 : path;
}

static void describeAddress(void *address, char *out, size_t cap) {
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (address && dladdr(address, &info)) {
        uintptr_t base = (uintptr_t)info.dli_fbase;
        uintptr_t a = (uintptr_t)address;
        snprintf(out, cap, "%s+0x%llx symbol=%s address=%p",
                 baseName(info.dli_fname),
                 (unsigned long long)(a >= base ? a - base : 0),
                 info.dli_sname ? info.dli_sname : "?",
                 address);
    } else {
        snprintf(out, cap, "unknown address=%p", address);
    }
}

typedef int (*BacktraceFn)(void **, int);
static BacktraceFn backtraceFn(void) {
    static BacktraceFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (BacktraceFn)dlsym(RTLD_DEFAULT, "backtrace");
    });
    return fn;
}

static void logBacktrace(const char *reason) {
    BacktraceFn bt = backtraceFn();
    if (!bt) {
        logLine("BACKTRACE unavailable reason=%s", reason);
        return;
    }
    void *frames[20];
    int count = bt(frames, 20);
    logLine("BACKTRACE_BEGIN reason=%s count=%d", reason, count);
    for (int i = 0; i < count; i++) {
        char d[768];
        describeAddress(frames[i], d, sizeof(d));
        logLine("BACKTRACE frame=%d %s", i, d);
    }
    logLine("BACKTRACE_END reason=%s", reason);
}

static void uuidForHeader(const struct mach_header *mh, char out[37]) {
    out[0] = '\0';
    if (!mh || (mh->magic != MH_MAGIC_64 && mh->magic != MH_CIGAM_64)) return;
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const uint8_t *cursor = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_UUID) {
            const struct uuid_command *uc = (const struct uuid_command *)cursor;
            const uint8_t *u = uc->uuid;
            snprintf(out, 37,
                     "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                     u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],
                     u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]);
            return;
        }
        if (!lc->cmdsize) return;
        cursor += lc->cmdsize;
    }
}

static bool findTarget(void) {
    if (gTargetReady) return true;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!name || !mh) continue;
        if (!strstr(name, "/TelegramCoreFramework.framework/TelegramCoreFramework")) continue;

        char uuid[37];
        uuidForHeader(mh, uuid);
        uintptr_t candidate = (uintptr_t)mh + SPP_TARGET_OFFSET;
        logLine("TELEGRAMCORE base=0x%llx uuid=%s target=0x%llx",
                (unsigned long long)(uintptr_t)mh,
                uuid[0] ? uuid : "?",
                (unsigned long long)candidate);

        if (!uuid[0] || strcasecmp(uuid, SPP_EXPECTED_TC_UUID) != 0) {
            logCritical("TARGET_BUILD_MISMATCH expectedUUID=%s actualUUID=%s monitoring=disabled",
                        SPP_EXPECTED_TC_UUID,
                        uuid[0] ? uuid : "?");
            return false;
        }

        gTarget = candidate;
        gPageSize = (size_t)getpagesize();
        gTargetPage = gTarget & ~((uintptr_t)gPageSize - 1U);
        memcpy(gOriginal, (const void *)gTarget, sizeof(gOriginal));
        memcpy(gLast, gOriginal, sizeof(gLast));
        gTargetReady = true;

        char hex[SPP_SAMPLE_BYTES * 2 + 1];
        bytesHex(gOriginal, sizeof(gOriginal), hex, sizeof(hex));
        logCritical("TARGET_ORIGINAL TelegramCore+0x%llx address=0x%llx page=0x%llx bytes=%s",
                    (unsigned long long)SPP_TARGET_OFFSET,
                    (unsigned long long)gTarget,
                    (unsigned long long)gTargetPage,
                    hex);
        return true;
    }
    return false;
}

static bool overlaps(uintptr_t a, size_t n, uintptr_t b, uintptr_t e) {
    if (!n) return false;
    uintptr_t end = a + n;
    if (end < a) end = UINTPTR_MAX;
    return a < e && end > b;
}

static bool touchesPage(uintptr_t a, size_t n) {
    return gTargetReady && gPageSize && overlaps(a, n, gTargetPage, gTargetPage + gPageSize);
}

static void logMemoryEvent(const char *api, uintptr_t address, size_t length, uint64_t detail, void *caller) {
    char d[768];
    describeAddress(caller, d, sizeof(d));
    logCritical("MEMORY_EVENT api=%s address=0x%llx length=0x%llx detail=0x%llx caller=%s",
                api,
                (unsigned long long)address,
                (unsigned long long)length,
                (unsigned long long)detail,
                d);
    logBacktrace(api);
    if (gLogFD >= 0) (void)fsync(gLogFD);
}

static void watchTick(void) {
    if (!gTargetReady) {
        (void)findTarget();
        return;
    }
    uint8_t current[SPP_SAMPLE_BYTES];
    memcpy(current, (const void *)gTarget, sizeof(current));
    if (!memcmp(current, gLast, sizeof(current))) return;

    char before[SPP_SAMPLE_BYTES * 2 + 1];
    char after[SPP_SAMPLE_BYTES * 2 + 1];
    bytesHex(gLast, sizeof(gLast), before, sizeof(before));
    bytesHex(current, sizeof(current), after, sizeof(after));
    bool first = !gMutationSeen;
    gMutationSeen = true;
    logCritical("%s TelegramCore+0x%llx address=0x%llx before=%s after=%s",
                first ? "FIRST_MUTATION" : "TARGET_MUTATION",
                (unsigned long long)SPP_TARGET_OFFSET,
                (unsigned long long)gTarget,
                before,
                after);
    uint32_t i0 = 0, i1 = 0;
    memcpy(&i0, current, 4);
    memcpy(&i1, current + 4, 4);
    logCritical("TARGET_PATCHED firstInsn=0x%08x secondInsn=0x%08x", i0, i1);
    memcpy(gLast, current, sizeof(gLast));

    if (first && gTimer) {
        dispatch_source_set_timer(gTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  50ULL * NSEC_PER_MSEC,
                                  5ULL * NSEC_PER_MSEC);
    }
}

static int probe_mprotect(void *addr, size_t len, int prot) {
    typedef int (*Fn)(void *, size_t, int);
    static Fn original = NULL;
    if (!original) original = (Fn)dlsym(RTLD_NEXT, "mprotect");
    if (!original) return -1;
    void *caller = __builtin_return_address(0);
    if (gInHook == 0 && touchesPage((uintptr_t)addr, len)) {
        gInHook++;
        logMemoryEvent("mprotect", (uintptr_t)addr, len, (uint64_t)prot, caller);
        gInHook--;
    }
    return original(addr, len, prot);
}

static kern_return_t probe_vm_protect(vm_map_t task, vm_address_t addr, vm_size_t len,
                                      boolean_t setMax, vm_prot_t prot) {
    typedef kern_return_t (*Fn)(vm_map_t, vm_address_t, vm_size_t, boolean_t, vm_prot_t);
    static Fn original = NULL;
    if (!original) original = (Fn)dlsym(RTLD_NEXT, "vm_protect");
    if (!original) return KERN_FAILURE;
    void *caller = __builtin_return_address(0);
    if (gInHook == 0 && touchesPage((uintptr_t)addr, (size_t)len)) {
        gInHook++;
        uint64_t detail = ((uint64_t)(uint32_t)setMax << 32) | (uint32_t)prot;
        logMemoryEvent("vm_protect", (uintptr_t)addr, (size_t)len, detail, caller);
        gInHook--;
    }
    return original(task, addr, len, setMax, prot);
}

static kern_return_t probe_mach_vm_protect(vm_map_t task, mach_vm_address_t addr,
                                           mach_vm_size_t len, boolean_t setMax,
                                           vm_prot_t prot) {
    typedef kern_return_t (*Fn)(vm_map_t, mach_vm_address_t, mach_vm_size_t, boolean_t, vm_prot_t);
    static Fn original = NULL;
    if (!original) original = (Fn)dlsym(RTLD_NEXT, "mach_vm_protect");
    if (!original) return KERN_FAILURE;
    void *caller = __builtin_return_address(0);
    if (gInHook == 0 && touchesPage((uintptr_t)addr, (size_t)len)) {
        gInHook++;
        uint64_t detail = ((uint64_t)(uint32_t)setMax << 32) | (uint32_t)prot;
        logMemoryEvent("mach_vm_protect", (uintptr_t)addr, (size_t)len, detail, caller);
        gInHook--;
    }
    return original(task, addr, len, setMax, prot);
}

static void probe_icache(void *start, size_t len) {
    typedef void (*Fn)(void *, size_t);
    static Fn original = NULL;
    if (!original) original = (Fn)dlsym(RTLD_NEXT, "sys_icache_invalidate");
    if (!original) return;
    void *caller = __builtin_return_address(0);
    if (gInHook == 0 && touchesPage((uintptr_t)start, len)) {
        gInHook++;
        logMemoryEvent("sys_icache_invalidate", (uintptr_t)start, len, 0, caller);
        gInHook--;
    }
    original(start, len);
}

#define SPP_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&replacee \
    };

SPP_INTERPOSE(probe_mprotect, mprotect)
SPP_INTERPOSE(probe_vm_protect, vm_protect)
SPP_INTERPOSE(probe_mach_vm_protect, mach_vm_protect)
SPP_INTERPOSE(probe_icache, sys_icache_invalidate)

static void scanImages(void) {
    uint32_t count = _dyld_image_count();
    logLine("IMAGE_SCAN count=%u", count);
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!name || !mh) continue;
        if (strstr(name, "/Swiftgram.app/") ||
            strstr(name, "TelegramCoreFramework") ||
            strstr(name, "PostboxFramework") ||
            strstr(name, "SwiftSignalKitFramework")) {
            char uuid[37];
            uuidForHeader(mh, uuid);
            logLine("IMAGE name=%s base=0x%llx uuid=%s path=%s",
                    baseName(name),
                    (unsigned long long)(uintptr_t)mh,
                    uuid[0] ? uuid : "?",
                    name);
        }
    }
}

static void startTimer(void) {
    dispatch_queue_t q = dispatch_queue_create("com.lucas.swiftgram.postboxprobe.attribution",
                                               DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!gTimer) {
        logCritical("WATCH_TIMER create_failed");
        return;
    }
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              2ULL * NSEC_PER_MSEC,
                              500000ULL);
    dispatch_source_set_event_handler(gTimer, ^{ watchTick(); });
    dispatch_resume(gTimer);
    logLine("WATCH_TIMER started interval=2ms fallback=polling");
}

static void initLog(void) {
    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *current = [docs stringByAppendingPathComponent:@"SwiftgramPostboxProbe.log"];
    NSString *previous = [docs stringByAppendingPathComponent:@"SwiftgramPostboxProbe.previous.log"];
    (void)unlink(previous.fileSystemRepresentation);
    (void)rename(current.fileSystemRepresentation, previous.fileSystemRepresentation);
    gLogFD = open(current.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    gStartUsec = nowUsec();
}

__attribute__((constructor))
static void probeInit(void) {
    @autoreleasepool {
        initLog();
        if (gLogFD < 0) return;
        logCritical("PROBE_START version=%s mode=diagnostic-attribution", SPP_VERSION);

        NSBundle *b = [NSBundle mainBundle];
        NSString *bundleID = b.bundleIdentifier ?: @"?";
        NSString *version = [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
        NSString *build = [b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
        logCritical("APP bundle=%s version=%s build=%s",
                    bundleID.UTF8String, version.UTF8String, build.UTF8String);
        logCritical("CRASH_SIGNATURE expected=EXC_BREAKPOINT/SIGTRAP queue=org.telegram.postbox.Postbox TelegramCore+0x%llx",
                    (unsigned long long)SPP_TARGET_OFFSET);

        if (![bundleID isEqualToString:@"app.swiftgram.ios"]) {
            logCritical("APP_MISMATCH expected=app.swiftgram.ios monitoring=disabled");
            return;
        }

        scanImages();
        (void)findTarget();
        startTimer();
        logCritical("PROBE_READY targetReady=%d interpose=mprotect,vm_protect,mach_vm_protect,sys_icache_invalidate",
                    gTargetReady ? 1 : 0);
    }
}
