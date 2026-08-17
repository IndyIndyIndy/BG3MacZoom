#pragma once

struct Config {
    float max_zoom;         // vanilla 12/15/19; default 30
    bool  min_zoom_enable;
    float min_zoom;         // vanilla 3.5; default 1.5
    bool  unlock_pitch;
    float pitch_deg;        // smaller = flatter; default 20
};

Config config_defaults();

// Parses key = value lines ('#' comments), overwriting only the keys present.
void config_parse_string(const char* text, Config& cfg);

// BG3_ZOOM_MAX overrides max_zoom.
void config_apply_env(Config& cfg);

// Loads config.toml (creating it with commented defaults if absent), then applies env overrides.
Config load_config();
