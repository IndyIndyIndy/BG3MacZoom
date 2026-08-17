# BG3MacZoom - Camera Tweaks for Baldur's Gate 3 (macOS)

A tiny, configurable camera mod for Baldur's Gate 3 on **macOS (Apple Silicon)**:

- **Zoom out much further**: Raise the max zoom-out distance from the vanilla ~12 to a configurable **30** (or more).
- **Zoom in closer** (optional): Lower the minimum distance below the vanilla 3.5.
- **Flatter camera angle** (optional): A more horizontal, 3rd-person-style view.

All options are toggleable via a config file, and you can edit it while the game is running:
changes apply within about two seconds. With no configuration you get the
further zoom-out and otherwise vanilla behaviour.

## Why

The default max zoom in Larian's games always makes me feel like I've got my nose
pressed against the screen. I want to lean back and actually see the area.

There are great camera mods that fix exactly this... and every one of them is
**Windows-only**. So I reverse-engineered the native
Apple-Silicon build and made my own. It's small, it touches no game files, and it's easy
to install. Sharing it in case other Mac players were just as annoyed.

## Requirements

- A Mac with **Apple Silicon** (M1 or newer)
- **Baldur's Gate 3** - Steam is tested; the GOG build should work too (it's the same game
  binary, and the mod finds the camera config by signature) but is currently untested

No build tools needed: on first run the launcher downloads a prebuilt, signed binary. (If
you'd rather build from source, install the Xcode Command Line Tools with
`xcode-select --install`. The launcher falls back to building if the download fails.)

## Setup

```bash
git clone https://github.com/IndyIndyIndy/BG3MacZoom.git
cd BG3MacZoom
./launch-bg3.sh
```

On first run the script downloads the prebuilt mod (or builds it, if you have the Command
Line Tools), finds your BG3 installation, and launches the game with the mod loaded. Load
a save and zoom out. You'll be able to pull the camera much further back.

**If using Steam:** Keep the Steam client running (logged in), but launch the game with
`./launch-bg3.sh` instead of Steam's Play button. 

## Configuration

A config file is created automatically on first launch at:

```
~/Library/Application Support/BG3MacZoom/config.toml
```

Every option is documented inline in the file, including the vanilla values. Summary:

| Option            | Default   | What it does                                                                                         |
|-------------------|-----------|------------------------------------------------------------------------------------------------------|
| `max_zoom`        | `30.0`    | Max zoom-out distance. Vanilla: 12 (exploration) / 15 (combat) / 19 (special). Values up to 50 work. |
| `min_zoom_enable` | `false`   | Enable zooming in closer than vanilla.                                                               |
| `min_zoom`        | `1.5`     | Minimum distance when enabled. Vanilla is 3.5.                                                       |
| `unlock_pitch`    | `false`   | Fix the camera to a flatter angle (more horizon).                                                    |
| `pitch_deg`       | `20.0`    | The pitch angle when enabled - smaller = flatter, larger = steeper. Vanilla is ~40°.                 |

### Tweak it live

You don't have to restart the game to try values. Keep BG3 running, open the config file
in any editor, change a value, and **save** - the camera follows within ~2 seconds. Great
for finding the zoom distance and pitch angle you like. Turning an option back to `false`
reverts it live too.

The mod writes a small log to `~/Library/Logs/BG3MacZoom.log`. On success you'll see the
patched values and `Camera tweaks applied.`

## Tested on

|                 |                                        |
|-----------------|----------------------------------------|
| Mac             | MacBook Pro (Mac16,8), Apple M4 Pro    |
| macOS           | 26.5.2 (build 25F84)                   |
| Baldur's Gate 3 | 4.1.1.7398727 (Steam buildid 24532579) |

It should work on other Apple-Silicon Macs and BG3 versions: the mod finds the camera
settings by a data signature, so it survives most game updates. If Larian ever changes
the camera internals, the mod detects the mismatch and **does nothing** (it never writes
to unverified memory).

## How it works

BG3's camera distance is clamped every frame to a per-mode maximum (exploration ≈ 12,
combat ≈ 15) that lives in a global camera-config object inside the game.

1. **Injection.** The native macOS build has no Hardened Runtime and no restrictive
   entitlements, so a plain `.dylib` can be loaded via `DYLD_INSERT_LIBRARIES`. The launcher
   starts the game binary directly (setting `SteamAppId` for Steam installs).
2. **Find the limit.** The build ships with full symbols. Using an lldb watchpoint on the
   live camera-distance field, the zoom clamp was traced to
   `ecl::CameraSystem::UpdateGameCameraBehavior`, where the target distance is capped to a
   maximum read from the camera-config object (field `+0x28` of each mode sub-block).
3. **Patch.** On load, a background thread locates that config object. First via a known
   address, then by a multi-point float signature as a fallback, validates it, and writes
   the enabled tweaks: the max-zoom field (`+0x28`), the min-zoom field (`+0x2c`), and the
   pitch fields (`+0x160…`). The game's own logic then uses the new values. Every couple of
   seconds it re-reads `config.toml` and re-applies, which is what makes live editing work
   and keeps the tweaks in place across level loads. Original values are captured first, so
   disabling an option restores vanilla.

The min-zoom and pitch fields were found the same way (lldb watchpoints and live memory
pokes into the same config object). All three tweaks are just values in that one struct, so
the mod is a small, self-validating set of guarded writes.

Everything happens in memory in the running process. **No game files are modified.**