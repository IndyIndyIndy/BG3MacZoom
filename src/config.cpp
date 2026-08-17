#include "config.h"
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <strings.h>
#include <sys/stat.h>

Config config_defaults() {
    return Config{ /*max_zoom*/30.0f, /*min_zoom_enable*/false, /*min_zoom*/1.5f,
                   /*unlock_pitch*/false, /*pitch_deg*/20.0f };
}

static void trim(char*& s, char*& end) {
    while (s < end && (*s==' '||*s=='\t'||*s=='\r'||*s=='\n')) ++s;
    while (end > s && (end[-1]==' '||end[-1]=='\t'||end[-1]=='\r'||end[-1]=='\n')) --end;
}

// Parse a positive float; leaves `out` unchanged and returns false if unparseable.
static bool parse_float(const char* v, float& out) {
    char* end = nullptr;
    float f = strtof(v, &end);
    if (end == v || f <= 0.0f) return false;
    out = f;
    return true;
}

static void parse_bool(const char* v, bool& out) {
    if (!strcasecmp(v, "true")  || !strcmp(v, "1")) out = true;
    else if (!strcasecmp(v, "false") || !strcmp(v, "0")) out = false;
    // anything else: leave unchanged
}

void config_parse_string(const char* text, Config& cfg) {
    if (!text) return;
    const char* p = text;
    while (*p) {
        const char* nl = strchr(p, '\n');
        const char* lineEnd = nl ? nl : p + strlen(p);
        char buf[256];
        size_t n = (size_t)(lineEnd - p); if (n > 255) n = 255;
        memcpy(buf, p, n); buf[n] = 0;

        if (char* hash = strchr(buf, '#')) *hash = 0;
        if (char* eq = strchr(buf, '=')) {
            *eq = 0;
            char* k = buf;    char* kend = k + strlen(k);
            char* v = eq + 1; char* vend = v + strlen(v);
            trim(k, kend); *kend = 0;
            trim(v, vend); *vend = 0;
            if (*k && *v) {
                if      (!strcmp(k, "max_zoom"))        parse_float(v, cfg.max_zoom);
                else if (!strcmp(k, "min_zoom"))        parse_float(v, cfg.min_zoom);
                else if (!strcmp(k, "pitch_deg"))       parse_float(v, cfg.pitch_deg);
                else if (!strcmp(k, "min_zoom_enable")) parse_bool(v, cfg.min_zoom_enable);
                else if (!strcmp(k, "unlock_pitch"))    parse_bool(v, cfg.unlock_pitch);
            }
        }
        if (!nl) break;
        p = nl + 1;
    }
}

void config_apply_env(Config& cfg) {
    if (const char* v = getenv("BG3_ZOOM_MAX")) parse_float(v, cfg.max_zoom);
}

// The parent dirs (~/Library/Application Support) already exist, so one mkdir suffices.
static void ensure_dir(const char* path) { mkdir(path, 0755); }

Config load_config() {
    Config cfg = config_defaults();
    const char* home = getenv("HOME");
    if (!home) { config_apply_env(cfg); return cfg; }

    char dir[1024], file[1200];
    snprintf(dir, sizeof(dir), "%s/Library/Application Support/BG3MacZoom", home);
    ensure_dir(dir);
    snprintf(file, sizeof(file), "%s/config.toml", dir);

    FILE* f = fopen(file, "r");
    if (!f) {
        FILE* w = fopen(file, "w");
        if (w) {
            fputs(
                "# BG3MacZoom configuration.\n"
                "# Created automatically on first launch. Edit and save while the game runs;\n"
                "# changes apply within a couple of seconds, no restart needed.\n"
                "# Environment variables override these values (e.g. BG3_ZOOM_MAX overrides max_zoom).\n"
                "\n"
                "# Maximum camera zoom-out distance (how far the camera can pull back).\n"
                "# Vanilla limits are 12 (exploration), 15 (combat), 19 (special cameras).\n"
                "# This raises all of them to the value below. Values up to 50 work; the default is 30.\n"
                "max_zoom        = 30.0\n"
                "\n"
                "# Allow zooming in CLOSER than vanilla. Vanilla minimum distance is 3.5 (exploration).\n"
                "# When enabled, the minimum is lowered to min_zoom. Leave false for vanilla behaviour.\n"
                "min_zoom_enable = false\n"
                "min_zoom        = 1.5\n"
                "\n"
                "# Camera pitch (vertical angle). Vanilla keeps a fairly top-down angle (~40 degrees)\n"
                "# that automatically steepens as you zoom out; there is no free vertical tilt with\n"
                "# mouse/keyboard. When enabled, the camera is fixed to a flatter angle (more horizon,\n"
                "# a 3rd-person feel). pitch_deg is that angle in degrees: smaller = flatter,\n"
                "# larger = steeper/more top-down. Leave false for vanilla behaviour.\n"
                "unlock_pitch    = false\n"
                "pitch_deg       = 20.0\n",
                w);
            fclose(w);
        }
    } else {
        char buf[8192];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        buf[n] = 0;
        fclose(f);
        config_parse_string(buf, cfg);
    }
    config_apply_env(cfg);
    return cfg;
}
