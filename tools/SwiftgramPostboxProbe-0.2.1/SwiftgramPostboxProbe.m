#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <pthread.h>
#import <sys/time.h>
#import <unistd.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#define SPP_VERSION "SwiftgramPostboxProbe 0.2.1 Safe Attribution"
#define SPP_TARGET_OFFSET ((uintptr_t)0x908638)
#define SPP_SAMPLE_BYTES 64
#define SPP_EXPECTED_TC_UUID "d8a0c19b-0918-336a-a542-9e30416542ec"

static const uint8_t kKnownIQTeleDestination[32] = {
    0x30,0x0a,0x00,0xd0,0x10,0x42,0x42,0xb9,
    0xb0,0x00,0x00,0x35,0x30,0x0a,0x00,0xd0,
    0x10,0x2a,0x41,0xf9,0x50,0x00,0x00,0xb4,
    0x00,0x02,0x1f,0xd6,0x00,0x00,0x80,0x52
};

static int gLogFD = -1;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static uintptr_t gTarget = 0;
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
                 "[SPP21] +%llu.%03llums %s\n",
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
    size_t maxLen = (cap - 1) / 2;
    if (len > maxLen) len = maxLen;
    const uint8_t *p = (const uint8_t *)ptr;
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

static bool describeAddress(uintptr_t address, char *out, size_t cap) {
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (address && dladdr((void *)address, &info)) {
        uintptr_t base = (uintptr_t)info.dli_fbase;
        snprintf(out, cap,
                 "%s+0x%llx symbol=%s address=0x%llx",
                 baseName(info.dli_fname),
                 (unsigned long long)(address >= base ? address - base : 0),
                 info.dli_sname ? info.dli_sname : "?",
                 (unsigned long long)address);
        return true;
    }
    snprintf(out, cap, "unknown address=0x%llx", (unsigned long long)address);
    return false;
}

static void uuidForHeader(const struct mach_header *mh, char out[37]) {
    out[0] = '\0';
    if (!mh || (mh->magic != MH_MAGIC_64 && mh->magic != MH_CIGAM_64)) return;
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const uint8_t *cursor = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (!lc->cmdsize) return;
        if (lc->cmd == LC_UUID) {
            const struct uuid_command *uc = (const struct uuid_command *)cursor;
            const uint8_t *u = uc->uuid;
            snprintf(out, 37,
                     "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                     u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],
                     u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]);
            return;
        }
        cursor += lc->cmdsize;
    }
}

static bool imageTextRange(const struct mach_header *mh, uintptr_t *start, size_t *length) {
    if (!mh || !start || !length || mh->magic != MH_MAGIC_64) return false;
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const uint8_t *cursor = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (!lc->cmdsize) return false;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (!strncmp(seg->segname, "__TEXT", 16)) {
                *start = (uintptr_t)mh;
                *length = (size_t)seg->vmsize;
                return *length > 0;
            }
        }
        cursor += lc->cmdsize;
    }
    return false;
}

static void scanKnownIQTeleDestination(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!name || !mh || !strstr(name, "iQTele.dylib")) continue;

        uintptr_t start = 0;
        size_t length = 0;
        if (!imageTextRange(mh, &start, &length) || length < sizeof(kKnownIQTeleDestination)) {
            logLine("IQTELE_FINGERPRINT range_unavailable path=%s", name);
            return;
        }

        const uint8_t *p = (const uint8_t *)start;
        for (size_t off = 0; off + sizeof(kKnownIQTeleDestination) <= length; off += 4) {
            if (!memcmp(p + off, kKnownIQTeleDestination, sizeof(kKnownIQTeleDestination))) {
                logCritical("IQTELE_DESTINATION_CANDIDATE address=0x%llx offset=0x%llx image=iQTele.dylib confidence=historical-fingerprint",
                            (unsigned long long)(start + off),
                            (unsigned long long)off);
                return;
            }
        }
        logLine("IQTELE_FINGERPRINT not_found textSize=0x%llx",
                (unsigned long long)length);
        return;
    }
    logLine("IQTELE_FINGERPRINT image_not_loaded");
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
        memcpy(gOriginal, (const void *)gTarget, sizeof(gOriginal));
        memcpy(gLast, gOriginal, sizeof(gLast));
        gTargetReady = true;

        char hex[SPP_SAMPLE_BYTES * 2 + 1];
        bytesHex(gOriginal, sizeof(gOriginal), hex, sizeof(hex));
        logCritical("TARGET_ORIGINAL TelegramCore+0x%llx address=0x%llx bytes=%s",
                    (unsigned long long)SPP_TARGET_OFFSET,
                    (unsigned long long)gTarget,
                    hex);
        return true;
    }
    return false;
}

static bool decodeDirectBranch(uintptr_t pc, uint32_t instruction, uintptr_t *destination) {
    if (!destination) return false;
    if ((instruction & 0x7c000000U) != 0x14000000U) return false;
    int64_t imm26 = (int64_t)(instruction & 0x03ffffffU);
    if (imm26 & 0x02000000LL) imm26 |= ~0x03ffffffLL;
    *destination = (uintptr_t)((int64_t)pc + (imm26 << 2));
    return true;
}

static bool decodeLiteralBranch(uintptr_t pc, const uint32_t insn[2], uintptr_t *destination) {
    if (!destination) return false;
    uint32_t ldr = insn[0];
    uint32_t br = insn[1];
    if ((ldr & 0xff000000U) != 0x58000000U) return false;
    uint32_t reg = ldr & 0x1fU;
    uint32_t expectedBR = 0xd61f0000U | (reg << 5);
    if (br != expectedBR) return false;

    int64_t imm19 = (int64_t)((ldr >> 5) & 0x7ffffU);
    if (imm19 & 0x40000LL) imm19 |= ~0x7ffffLL;
    uintptr_t literal = (uintptr_t)((int64_t)pc + (imm19 << 2));

    Dl_info check;
    memset(&check, 0, sizeof(check));
    if (!dladdr((void *)literal, &check)) return false;
    uintptr_t value = 0;
    memcpy(&value, (const void *)literal, sizeof(value));
    if (!value) return false;
    *destination = value;
    return true;
}

static void logBranchChain(uintptr_t start) {
    uintptr_t pc = start;
    for (int hop = 0; hop < 4; hop++) {
        char desc[768];
        bool mapped = describeAddress(pc, desc, sizeof(desc));
        logCritical("BRANCH_HOP index=%d %s", hop, desc);
        if (!mapped) return;

        uint32_t insn[2] = {0, 0};
        memcpy(insn, (const void *)pc, sizeof(insn));
        uintptr_t next = 0;
        if (decodeDirectBranch(pc, insn[0], &next) ||
            decodeLiteralBranch(pc, insn, &next)) {
            if (!next || next == pc) return;
            pc = next;
            continue;
        }
        return;
    }
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

    uint32_t firstInsn = 0;
    memcpy(&firstInsn, current, sizeof(firstInsn));
    uintptr_t destination = 0;
    if (decodeDirectBranch(gTarget, firstInsn, &destination)) {
        char desc[768];
        describeAddress(destination, desc, sizeof(desc));
        logCritical("DIRECT_BRANCH instruction=0x%08x destination=%s", firstInsn, desc);
        logBranchChain(destination);
    } else {
        logCritical("DIRECT_BRANCH not_detected firstInsn=0x%08x", firstInsn);
    }

    memcpy(gLast, current, sizeof(gLast));
    if (first && gTimer) {
        dispatch_source_set_timer(gTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  20ULL * NSEC_PER_MSEC,
                                  2ULL * NSEC_PER_MSEC);
    }
}

static void scanImages(void) {
    uint32_t count = _dyld_image_count();
    logLine("IMAGE_SCAN count=%u", count);
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!name || !mh) continue;
        if (strstr(name, "/Swiftgram.app/") ||
            strstr(name, "TelegramCoreFramework") ||
            strstr(name, "PostboxFramework")) {
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
    dispatch_queue_t q = dispatch_queue_create("com.lucas.swiftgram.postboxprobe.safe",
                                               DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!gTimer) {
        logCritical("WATCH_TIMER create_failed");
        return;
    }
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              1ULL * NSEC_PER_MSEC,
                              250000ULL);
    dispatch_source_set_event_handler(gTimer, ^{ watchTick(); });
    dispatch_resume(gTimer);
    logCritical("WATCH_TIMER started interval=1ms mode=polling-only no-interpose");
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

        logCritical("PROBE_START version=%s mode=safe-polling-only", SPP_VERSION);
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
        scanKnownIQTeleDestination();
        startTimer();
        logCritical("PROBE_READY targetReady=%d safety=no-dyld-interpose", gTargetReady ? 1 : 0);
    }
}
