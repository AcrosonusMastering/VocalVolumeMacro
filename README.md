# Vocal Volume Macro

> Melodyne-style vocal dynamic correction for REAPER — Lua script with spectral analysis


[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![REAPER](https://img.shields.io/badge/REAPER-6%2B-blue)](https://www.reaper.fm)
[![ReaImGui](https://img.shields.io/badge/requires-ReaImGui-orange)](https://github.com/cfillion/reaimgui)
[![Lua](https://img.shields.io/badge/language-Lua-purple)](https://www.lua.org)

---

## What it does

Vocal Volume Macro analyses a vocal recording block by block and applies volume correction **only on tonal blocks** (sung vowels, held notes), leaving consonants, sibilants and breath noises completely untouched.

This is the core behaviour of Melodyne's Volume Macro — reproduced inside REAPER without any third-party plugin, using pure DSP in Lua.

```
Before  │  uneven dynamics
After   │  tonal parts levelled, noise intact
```

---

## Why not just use a compressor?

A compressor acts on overall amplitude with no content awareness. It cannot tell whether a volume peak is a sung **A** or a **S** sibilant. Sibilants ride up with vowels, intelligibility degrades, the voice loses its natural feel.

This script solves it at the block level:

| Feature | Compressor | This script |
|---|---|---|
| Acts on vowels only | ✗ | ✓ |
| Preserves sibilants | ✗ | ✓ |
| Preserves plosives | ✗ | ✓ |
| Non-destructive | depends | ✓ Take Envelope |
| Follows item if moved | ✗ | ✓ |
| Adjustable per voice type | limited | ✓ |

---

## Features

- **4-feature classification** per 10 ms block: RMS · ZCR · Spectral Centroid · Spectral Flux
- **Hann windowing** on DFT — eliminates spectral leakage (±2% vs ±30% without)
- **DC blocker** before ZCR — robust to preamp/interface DC offset
- **Adaptive silence threshold** — auto-detects noise floor from the recording itself
- **Async analysis** via `reaper.defer` — no UI freeze on long takes, cancellable
- **Per-block gain** (Melodyne blob mode) or constant segment gain (compressor mode)
- **Double-pass smoothing** — zero-phase anti-zipper filter, transitions centred on syllables
- **Take Volume Envelope** — automation follows the item if you move it
- **Pre-computed trig/Hann tables** — fast re-analysis when only correction params change
- **ReaImGui GUI** with live segment map, gain preview, adaptive freq display

---

## Requirements

| Dependency | Version | Install |
|---|---|---|
| REAPER | 6.0+ | [reaper.fm](https://www.reaper.fm) |
| ReaImGui | latest | ReaPack → Browse packages → "ReaImGui" |

---

## Installation

1. Download `VocalVolumeMacro_v5.lua`
2. Copy to your REAPER Scripts folder:
   - **Windows:** `%APPDATA%\REAPER\Scripts\`
   - **macOS:** `~/Library/Application Support/REAPER/Scripts/`
3. In REAPER: **Actions → Show action list → New action → Load ReaScript**
4. Select the `.lua` file
5. Optionally assign a keyboard shortcut

---

## Quick start

1. Select a vocal item in REAPER
2. Run the script
3. Click **Analyse** — watch the progress bar
4. Check the segment map: `▓` = tonal (will be corrected), `░` = noise (untouched)
5. Adjust target level and correction strength
6. Click **Apply**
7. `Ctrl+Z` to undo if needed

---

## Recommended chain order

```
[Vocal Volume Macro]  ← pre-correction, tonal parts only
      ↓
  [De-esser]          ← sibilants intact, clean target
      ↓
  [Compressor]        ← already balanced, lighter settings
      ↓
     [EQ]
      ↓
  [Reverb / FX]
```

---

## Files

| File | Description |
|---|---|
| `VocalVolumeMacro_v5.lua` | Main script |
| `README.md` | This file |
| `USER_MANUAL.md` | Full user manual with parameter reference |
| `TECHNICAL_DOC.md` | Algorithm documentation and architecture |

---

## Version history

| Version | Key changes |
|---|---|
| v5.0 | Double-pass zipper filter · adaptive silence threshold · UTF-8 safe segment map · flux_smooth reset on cancel |
| v4.0 | N_eff off-by-one fix · SC slider freq cap · robust segment merge · flux threshold in GUI |
| v3.0 | Take Envelope · async defer · item lock · fade clamp |
| v2.0 | Spectral Flux onset detection · Hann windowing · per-block gain |
| v1.0 | ZCR + Spectral Centroid · basic GUI |

## License

```
VocalVolumeMacro for REAPER
Copyright (C) 2025 Acrosonus Mastering

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.

https://www.gnu.org/licenses/gpl-3.0.html
```

**What this means in practice:**
- ✅ Free to use, modify and share
- ✅ Use in your own productions — no restrictions
- ✅ Fork and improve — contributions welcome
- ❌ Cannot be included in a closed-source commercial product
- ❌ Derivative works must remain open source under GPL v3

---
---

## License

MIT — free to use, modify and distribute. Credit appreciated.
