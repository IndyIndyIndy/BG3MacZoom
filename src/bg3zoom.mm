#import "bg3zoom.h"
#import "config.h"
#import <Foundation/Foundation.h>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <pthread.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

namespace bg3zoom {

// --- Logging ---------------------------------------------------------------

static FILE* g_log = nullptr;
static pthread_mutex_t g_log_mtx = PTHREAD_MUTEX_INITIALIZER;

static const char* log_path() {
    static char path[1024];
    const char* home = getenv("HOME");
    snprintf(path, sizeof(path), "%s/Library/Logs/BG3MacZoom.log", home ? home : "/tmp");
    return path;
}

void log_line(const char* fmt, ...) {
    pthread_mutex_lock(&g_log_mtx);
    if (!g_log) g_log = fopen(log_path(), "a");
    if (g_log) {
        va_list ap; va_start(ap, fmt);
        vfprintf(g_log, fmt, ap);
        va_end(ap);
        fputc('\n', g_log);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_log_mtx);
}

// --- Image lookup ----------------------------------------------------------

ImageInfo find_main_executable() {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const auto* h = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
        if (h && h->filetype == MH_EXECUTE) {
            return { h, _dyld_get_image_vmaddr_slide(i), _dyld_get_image_name(i), true };
        }
    }
    return { nullptr, 0, nullptr, false };
}

// --- Camera config patching ------------------------------------------------
//
// BG3's camera settings live in one global config object. Reverse-engineered
// against BG3 4.1.1 (arm64); see tools/re_notes.md. Layout, per mode sub-block:
//   config_root = *(kConfigGlobalStatic + slide)
//   sub-block   = config_root + {0x7c4 exploration | 0x958 combat | 0xc80 special}
//     +0x28  max zoom distance   (vanilla 12 / 15 / 19)
//     +0x2c  min zoom distance   (vanilla 3.5 / 4 / 0.5)
//     +0x160..+0x16c  pitch angle (degrees); +0x178/+0x17c  lower pitch limit

static const uintptr_t kConfigGlobalStatic  = 0x108b25f40;  // &config_root, static file address
static const size_t    kSubblocks[]         = {0x7c4, 0x958, 0xc80};
static const size_t    kMaxZoomOff          = 0x28;
static const size_t    kMinZoomOff          = 0x2c;
static const size_t    kPitchCurveOff[]     = {0x160, 0x164, 0x168, 0x16c};
static const size_t    kPitchFlatLimitOff[] = {0x178, 0x17c};

// Read from our own process without faulting on an invalid address.
static bool safe_read(uintptr_t addr, void* out, size_t n) {
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)addr,
                                              n, (mach_vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == n;
}

static inline bool approx(float v, float target, float tol) {
    return v > target - tol && v < target + tol;
}

// Multi-point signature over fields we never write, so it stays valid after our
// patches and the memory scan can't match unrelated memory:
//   +0x50 ~= 0.30 in all three sub-blocks, +0x58 ~= 50, and a plausible min < max.
static bool looks_like_config(uintptr_t root) {
    if (root < 0x100000 || root > 0x7fffffffffffULL) return false;
    float a50 = 0, b50 = 0, c50 = 0, a58 = 0, b58 = 0, amax = 0, amin = 0;
    if (!safe_read(root + 0x7c4 + 0x50, &a50, 4)) return false;
    if (!safe_read(root + 0x958 + 0x50, &b50, 4)) return false;
    if (!safe_read(root + 0xc80 + 0x50, &c50, 4)) return false;
    if (!safe_read(root + 0x7c4 + 0x58, &a58, 4)) return false;
    if (!safe_read(root + 0x958 + 0x58, &b58, 4)) return false;
    if (!safe_read(root + 0x7c4 + kMaxZoomOff, &amax, 4)) return false;
    if (!safe_read(root + 0x7c4 + kMinZoomOff, &amin, 4)) return false;
    return approx(a50, 0.30f, 0.05f) && approx(b50, 0.30f, 0.05f) && approx(c50, 0.30f, 0.05f)
        && approx(a58, 50.0f, 5.0f) && approx(b58, 50.0f, 5.0f)
        && amax > 5.0f && amax < 60.0f && amin > 0.0f && amin < amax;
}

// Fallback for game builds where the fixed address no longer resolves: scan writable
// memory for the config object by its signature.
static uintptr_t scan_for_config() {
    mach_port_t task = mach_task_self();
    mach_vm_address_t addr = 0;
    while (true) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj;
        if (mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
        uintptr_t start = (uintptr_t)addr, end = start + (uintptr_t)size;
        addr += size;
        if (!(info.protection & VM_PROT_WRITE)) continue;
        if (size < 0xd00 || size > (512ull << 20)) continue;
        for (uintptr_t root = start; root + 0xd00 <= end; root += 4) {
            float av = *(const float*)(root + 0x7c4 + 0x50);
            if (av < 0.25f || av > 0.35f) continue;  // cheap pre-filter on +0x50 ~= 0.30
            if (looks_like_config(root)) return root;
        }
    }
    return 0;
}

// Resolve config_root: cache, then the fixed address (with a grace period, since the
// global pointer is set slightly after the object exists), then the signature scan.
static uintptr_t g_config_root = 0;
static int       g_fixed_fail_polls = 0;
static uintptr_t resolve_config_root(intptr_t slide) {
    if (g_config_root && looks_like_config(g_config_root)) return g_config_root;

    uintptr_t via_global = 0;
    if (safe_read(kConfigGlobalStatic + (uintptr_t)slide, &via_global, sizeof(via_global))
        && looks_like_config(via_global)) {
        log_line("Camera config via fixed address @ 0x%lx.", via_global);
        return g_config_root = via_global;
    }

    if (++g_fixed_fail_polls < 10) return 0;
    uintptr_t scanned = scan_for_config();
    if (scanned) {
        log_line("Camera config via signature scan @ 0x%lx (fixed address unavailable).", scanned);
        g_config_root = scanned;
    }
    return scanned;
}

// Vanilla values captured once, before we write anything, so disabling a feature at
// runtime restores the original instead of leaving our last value behind.
static constexpr size_t kNumSub = sizeof(kSubblocks) / sizeof(kSubblocks[0]);
static struct { float minz, pitch[4], plimit[2]; } g_orig[kNumSub];
static bool g_orig_captured = false;

// Writes value if the current field is a plausible config float and actually differs;
// logs and returns true when it does.
static bool set_field(uintptr_t addr, float value, const char* what, size_t sub_off) {
    float* f = (float*)addr;
    if (!(*f > -1000.0f && *f < 1000.0f)) return false;
    if (fabsf(*f - value) <= 0.01f) return false;
    log_line("subblock +0x%zx %s: %.2f -> %.2f", sub_off, what, *f, value);
    *f = value;
    return true;
}

bool apply_value_tweaks(const Config& cfg) {
    ImageInfo bg3 = find_main_executable();
    if (!bg3.valid) return false;

    uintptr_t config_root = resolve_config_root(bg3.slide);
    if (!config_root) {
        static int misses = 0;
        if (++misses == 15) {  // config should have loaded by now
            log_line("Camera config not found. Possibly an unsupported BG3 build. No memory modified.");
        }
        return false;
    }

    if (!g_orig_captured) {
        for (size_t i = 0; i < kNumSub; i++) {
            uintptr_t sub = config_root + kSubblocks[i];
            g_orig[i].minz = *(float*)(sub + kMinZoomOff);
            for (size_t j = 0; j < 4; j++) g_orig[i].pitch[j] = *(float*)(sub + kPitchCurveOff[j]);
            for (size_t j = 0; j < 2; j++) g_orig[i].plimit[j] = *(float*)(sub + kPitchFlatLimitOff[j]);
        }
        g_orig_captured = true;
    }

    float maxTarget   = fminf(200.0f, fmaxf(1.0f, cfg.max_zoom));
    float pitchTarget = fminf(89.0f, fmaxf(1.0f, cfg.pitch_deg));

    bool wrote = false;
    for (size_t i = 0; i < kNumSub; i++) {
        uintptr_t sub = config_root + kSubblocks[i];

        wrote |= set_field(sub + kMaxZoomOff, maxTarget, "max zoom", kSubblocks[i]);

        float minTarget = cfg.min_zoom_enable ? cfg.min_zoom : g_orig[i].minz;
        if (minTarget > 0.0f && minTarget < maxTarget)
            wrote |= set_field(sub + kMinZoomOff, minTarget, "min zoom", kSubblocks[i]);

        for (size_t j = 0; j < 4; j++) {
            float t = cfg.unlock_pitch ? pitchTarget : g_orig[i].pitch[j];
            wrote |= set_field(sub + kPitchCurveOff[j], t, "pitch", kSubblocks[i]);
        }
        for (size_t j = 0; j < 2; j++) {
            float t = cfg.unlock_pitch ? fminf(g_orig[i].plimit[j], pitchTarget) : g_orig[i].plimit[j];
            wrote |= set_field(sub + kPitchFlatLimitOff[j], t, "pitch limit", kSubblocks[i]);
        }
    }
    return wrote;
}

void run_patcher() {
    [NSThread detachNewThreadWithBlock:^{
        bool applied = false;
        while (true) {
            // Re-read config.toml every tick so edits apply live, without restarting.
            if (apply_value_tweaks(load_config()) && !applied) {
                applied = true;
                log_line("Camera tweaks applied.");
            }
            [NSThread sleepForTimeInterval:applied ? 2.0 : 1.0];
        }
    }];
}

} // namespace bg3zoom

// Runs when the dylib is loaded via DYLD_INSERT_LIBRARIES.
__attribute__((constructor))
static void bg3zoom_init() {
    using namespace bg3zoom;

    Config cfg = load_config();
    log_line("BG3MacZoom 0.3  max_zoom=%.1f min_zoom=%s(%.1f) unlock_pitch=%s(%.1f)",
             cfg.max_zoom,
             cfg.min_zoom_enable ? "on" : "off", cfg.min_zoom,
             cfg.unlock_pitch ? "on" : "off", cfg.pitch_deg);

    ImageInfo bg3 = find_main_executable();
    if (!bg3.valid) { log_line("ERROR: main executable not found."); return; }
    log_line("Host: %s (slide 0x%lx)", bg3.path ? bg3.path : "?", (unsigned long)bg3.slide);

    run_patcher();
}
