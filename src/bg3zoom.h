#pragma once
#include <cstdint>
#include <cstddef>
#include "config.h"

namespace bg3zoom {

void log_line(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

struct ImageInfo {
    const void* header;
    intptr_t    slide;
    const char* path;
    bool        valid;
};

ImageInfo find_main_executable();

// Writes the enabled tweaks into the camera-config object, after validating its
// signature. Returns true if anything changed.
bool apply_value_tweaks(const Config& cfg);

// Background thread that re-reads config.toml and applies it every tick, so edits
// take effect live and survive level loads.
void run_patcher();

} // namespace bg3zoom
