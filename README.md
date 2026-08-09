# Vocal Volume Macro
> **Melodyne-Style Dynamic Volume Correction for REAPER**  
> Intelligent, envelope-based vocal leveling using spectral analysis & tonal segmentation.

Changelog:
V1.5 AVAILABLE

[#1] Perceptive K-weighting (60Hz high-pass + 4dB high-shelf @ 3kHz)
        applied to RMS/gain calculation to match perceived loudness (equal-loudness contours).

[#2] Independent asymmetric attack/release smoothing to
        prevent background noise pumping while quickly taming peaks.

[#3] "Live" sliders for ZCR, SC, and Flux: reclassification and
        instantaneous display update without re-reading the audio.


V1.1 Available

    Fix: Resolved automation issues for items in the middle of the timeline (replaced TakeAudioAccessor with TrackAudioAccessor).

    Fix: Fixed the spectral centroid reset bug.

    Enhancement: Improved the gain calculation algorithm for better accuracy/performance.


Download script in the release ➡️

Or if you are lost on Github Direct link:
https://drive.google.com/file/d/1rsJ6O8wGIbAWAc1bQ-hxZjx9FOUteGAU/view?usp=sharing


[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![REAPER](https://img.shields.io/badge/REAPER-6%2B-blue)](https://www.reaper.fm)
[![ReaImGui](https://img.shields.io/badge/requires-ReaImGui-orange)](https://github.com/cfillion/reaimgui)
[![Lua](https://img.shields.io/badge/language-Lua-purple)](https://www.lua.org)

---

## 📖 Overview
**Vocal Volume Macro (VVM)** is a REAPER script that analyzes vocal performances block-by-block, classifies audio into tonal, consonant, and silent regions, and writes precise, editable gain automation directly to a **Take Volume Envelope**. 

It behaves like a manual, surgical leveler: identifying exactly where sung notes begin and end, ignoring breaths/bleed, bridging natural vibrato dips, and applying mathematically calculated gain targets without altering transients or introducing pumping artifacts.

<img src='https://i.postimg.cc/Dz7Gv0y4/2026-05-22-11-48-38-(online-video-cutter-com).gif' border='0' alt='2026-05-22-11-48-38-(online-video-cutter-com)'></a>
---

## 🆚 How It Differs from Traditional "Volume Rider" Plugins
Most commercial volume riders (Waves Vocal Rider, Auto-Level, etc.) are essentially **fast-acting compressors/expanders with sidechain filtering**. They react to RMS peaks in real-time, which often leads to:
- 🔊 Gain pumping or breathing artifacts
- 🌬️ Unwanted boosting of breaths, room noise, or mic bleed
- 📉 Squashed vocal transients and loss of natural dynamics

**VVM takes a fundamentally different approach:**
| Traditional Riders | Vocal Volume Macro |
|-------------------|------------------------|
| Real-time compressor/expander chains | Offline spectral analysis & segmentation |
| Reacts to overall level | Classifies audio by **ZCR, Spectral Centroid & Flux** |
| Boosts/cuts continuously | Applies gain **only to tonal blocks** |
| Hard to edit after rendering | Writes **native REAPER envelope points** (fully editable) |
| Often boosts breaths & noise | **Adaptive gate** ignores sub-threshold audio |
| Fixed attack/release curves | **Gap bridging** fuses vibrato dips into continuous segments |

In short: **VVM doesn't compress or expand. It analyzes, segments, and automates.** The result is natural, transparent vocal leveling that preserves performance dynamics and breaths exactly where they belong.

---

## ✨ Key Features
- 🔍 **Block-Based Spectral Analysis** – Classifies 10ms blocks as tonal, consonant, or silent
- 🚪 **Adaptive Gate Threshold** – Ignores breaths, bleed, and room noise below a configurable dB floor
- 🌉 **Gap Bridging (Vibrato Fix)** – Automatically merges tonal blocks separated by <100ms gaps (prevents micro-segmentation on vibrato)
- 🎯 **Auto-Target RMS** – Calculates the optimal target level from *tonal blocks only* (ignores silences/consonants)
- 🔄 **"↺ Auto" Button** – Instantly resets your target to the auto-calculated RMS
- 📊 **Visual Waveform Analyzer** – Real-time color-coded display:
  - 🟩 **Green** = Tonal (corrected)
  - 🟥 **Red** = Consonants/Sibilants (preserved)
  - ⬜ **Gray** = Silence/Gate (untouched)
- ⚡ **Async Processing** – Non-blocking analysis with ETA & cancel support
- 📉 **Intelligent Envelope Decimation** – Writes only meaningful points (hundreds instead of thousands)
- 💾 **Session Persistence** – All parameters auto-save via `reaper.ExtState`
- ♻️ **Full Undo/Redo** – Integrated with REAPER's native undo system

---

## 🛠 Requirements & Installation
### Requirements
- **REAPER 6.0+**
- **[ReaImGui](https://github.com/cfillion/reaimgui)** (install via ReaPack → `Extensions > ReaPack > Browse Packages`)
- An audio item with an active take

### Installation
1. Open REAPER → `Actions > Show Action List`
2. Click `ReaScript: Load...` → Select `VocalVolumeMacrogemini.lua`
3. Assign a custom shortcut or add to a toolbar
4. **First run:** The script will prompt you to install ReaImGui if missing.

---

## 🚀 Usage Workflow
1. **Select** your vocal item in the Arrange view
2. **Run** the script → GUI opens
3. **Adjust** analysis & correction parameters (see below)
4. Click **🔍 Analyse** → Wait for async processing (progress bar + ETA)
5. **Preview** results in the waveform analyzer & stats panel
6. Tweak `Target RMS`, `Gate`, or `Correction Strength` as needed
7. Click **✅ Apply** → Writes automation to a Take Volume Envelope
8. Use **Ctrl+Z** to undo at any time

> 💡 *Tip: The script creates/arms a Take Volume Envelope automatically. You can edit, smooth, or delete points manually after applying.*

---

## 🎛 Parameters Explained
| Parameter | Description | Recommended Range |
|-----------|-------------|-------------------|
| `ZCR Threshold` | Zero-Crossing Rate max for tonal detection | `0.08 – 0.15` |
| `Spectral Centroid Max` | Frequency ceiling for vocal tonality | `800 – 2500 Hz` |
| `Consonant Onset (Flux)` | Sensitivity to plosives/sibilants | `0.20 – 0.40` |
| `Target RMS (dB)` | Desired average vocal level | `-18 to -14 dB` (lead), `-24 to -18 dB` (BGV) |
| `Gate Threshold (dB)` | Blocks below this gain remain untouched | `-45 to -30 dB` |
| `Vibrato/Gap Tolerance` | Max gap to bridge into one segment | `80 – 120 ms` (default) |
| `Correction Strength` | % of calculated gain to apply | `60 – 100%` |
| `Volume Rider Mode` | ☑ Per-block (fast leveling) / ☐ Per-segment (Melodyne-style) | Toggle based on genre |
| `Smoothing` | Gain transition speed (Rider mode only) | `0.20 – 0.35` |

---

## 📸 Visual Waveform Analyzer
After analysis, the bottom panel renders a color-coded bar graph representing your vocal track:
- 🟩 **Green bars** → Tonal regions receiving gain correction
- 🟥 **Red bars** → Consonants/sibilants preserved above gate
- ⬜ **Gray bars** → Silence, breaths, or sub-gate audio (gain = 1.0)

The display updates in real-time as you adjust `Target RMS` or `Gate Threshold`, giving you immediate visual feedback before applying.

---

## ⚠️ Important Notes
- 🔒 **Non-destructive:** Only writes envelope automation. Original audio remains untouched.
- 📁 **Source sync aware:** Correctly handles cut items, playrate changes, and start offsets.
- 🧠 **Auto-target logic:** Calculates RMS *only from tonal blocks* to avoid skew from silence/noise.
- 🔄 **Re-analysis required** when changing `block_ms`, `ZCR`, `SC`, or `Flux` thresholds.
- 💾 Always keep a backup or use `Undo` before applying automation to critical tracks.

---

## 🤝 Credits & License
- **Developed by:** Acrosonus Mastering
- **Developed for:** REAPER + ReaImGui
- **Algorithm:** Custom spectral classification (ZCR + Spectral Centroid + Flux) + adaptive segmentation

> 🎙 *Level vocals like a pro. Without compressing them into submission.*


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
