-- =============================================================================
-- VOCAL VOLUME MACRO v6.6.1
-- Melodyne-style dynamic correction for REAPER
-- =============================================================================
--
-- Developed by: Acrosonus Mastering
-- Developed for: REAPER + ReaImGui
-- Algorithm: Custom spectral classification (ZCR + Spectral Centroid + Flux) + 
--            Perceptive K-weighting filtering + Asymmetric smoothing + Live features
-- VocalVolumeMacro for REAPER
-- Copyright (C) 2025-2026 Acrosonus Mastering
-- 
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
-- See the GNU General Public License for more details.
-- 
-- https://www.gnu.org/licenses/gpl-3.0.html
--
-- NOUVEAUTÉS v6.6.1 intégrées :
--  [#1] DOUBLE CLICK RESET
-- NOUVEAUTÉS v6.6 intégrées :
--   [#1] Pondération perceptive K-weighting (Passe-haut 60Hz + High-shelf +4dB @ 3kHz)
--        appliquée au calcul du RMS/gain pour coller à la sonie perçue (courbes isophoniques).
--   [#2] Lissage asymétrique montée / descente (Attack / Release) dissocié pour
--        éviter de pomper le bruit de fond tout en domptant rapidement les pics.
--   [#3] Sliders "Live" pour ZCR, SC et Flux : reclassification et mise à jour 
--        instantanée de l'affichage sans relire l'audio.
-- =============================================================================

local r = reaper
local ctx  -- contexte ImGui, assigné après vérification ReaImGui

-- Localisation des fonctions math
local sin   = math.sin
local cos   = math.cos
local sqrt  = math.sqrt
local log   = math.log
local exp   = math.exp
local floor = math.floor
local ceil  = math.ceil
local abs   = math.abs
local max   = math.max
local min   = math.min
local pi    = math.pi

-- ============================================================
-- CONFIG GLOBALE
-- ============================================================
local CFG = {
  block_ms          = 10,
  min_silence_db    = -50,
  zcr_tonal_max     = 0.15,
  sc_tonal_max      = 2500,
  flux_onset_thresh = 0.30,
  smooth_frames     = 3,
  fade_ms           = 5,
  min_seg_ms        = 30,
  dft_downsample    = 4,
  n_bins            = 50,
  low_cut_bins      = 2,    -- bins DFT ignorés en basse fréquence
  flux_alpha        = 0.7,
  per_block_gain    = false,
}

-- ============================================================
-- MATH UTILS & FILTRES PERCEPTIFS (K-Weighting inspiré)
-- ============================================================
local function db_to_lin(db)  return 10 ^ (db / 20) end
local function lin_to_db(lin)
  if lin <= 0 then return -144 end
  return 20 * log(lin, 10)
end
local function clamp(v, lo, hi) return max(lo, min(hi, v)) end

local function compute_N_eff(block_samples, ds)
  return floor((block_samples - 1) / ds) + 1
end

local function compute_freq_max(samplerate, ds, N_eff, n_bins)
  local sr_eff   = samplerate / ds
  local freq_res = sr_eff / N_eff
  return n_bins * freq_res
end

-- Calcul des coefficients Biquad (RBJ Audio EQ Cookbook)
local function get_hpf_coeffs(sr, f0, Q)
  local w0 = 2 * pi * f0 / sr
  local alpha = sin(w0) / (2 * Q)
  local cos_w0 = cos(w0)
  local b0 =  (1 + cos_w0) / 2
  local b1 = -(1 + cos_w0)
  local b2 =  (1 + cos_w0) / 2
  local a0 =  1 + alpha
  local a1 = -2 * cos_w0
  local a2 =  1 - alpha
  return b0/a0, b1/a0, b2/a0, a1/a0, a2/a0
end

local function get_hsf_coeffs(sr, f0, dbGain, Q)
  local A = 10 ^ (dbGain / 40)
  local w0 = 2 * pi * f0 / sr
  local alpha = sin(w0) / (2 * Q)
  local cos_w0 = cos(w0)
  local sqrtA = sqrt(A)
  local b0 =       A * ((A + 1) + (A - 1) * cos_w0 + 2 * sqrtA * alpha)
  local b1 = -2 * A * ((A - 1) + (A + 1) * cos_w0)
  local b2 =       A * ((A + 1) + (A - 1) * cos_w0 - 2 * sqrtA * alpha)
  local a0 =            (A + 1) - (A - 1) * cos_w0 + 2 * sqrtA * alpha
  local a1 =     2 * ((A - 1) - (A + 1) * cos_w0)
  local a2 =            (A + 1) - (A - 1) * cos_w0 - 2 * sqrtA * alpha
  return b0/a0, b1/a0, b2/a0, a1/a0, a2/a0
end

-- Application de la pondération perceptive (K-weighting: HPF 60Hz + High-Shelf +4dB @ 3kHz)
local function compute_perceptive_rms(mono, block_samples, samplerate)
  if block_samples <= 0 then return 0 end
  local hpf_b0, hpf_b1, hpf_b2, hpf_a1, hpf_a2 = get_hpf_coeffs(samplerate, 60, 0.707)
  local hsf_b0, hsf_b1, hsf_b2, hsf_a1, hsf_a2 = get_hsf_coeffs(samplerate, 3000, 4.0, 0.707)

  local x1_1, x2_1, y1_1, y2_1 = 0, 0, 0, 0
  local x1_2, x2_2, y1_2, y2_2 = 0, 0, 0, 0
  local sum_sq = 0

  for i = 1, block_samples do
    local x = mono[i]
    -- Stage 1: High-Pass (60Hz)
    local y_hpf = hpf_b0 * x + hpf_b1 * x1_1 + hpf_b2 * x2_1 - hpf_a1 * y1_1 - hpf_a2 * y2_1
    x2_1, x1_1 = x1_1, x
    y2_1, y1_1 = y1_1, y_hpf

    -- Stage 2: High-Shelf (+4dB @ 3kHz)
    local y_hsf = hsf_b0 * y_hpf + hsf_b1 * x1_2 + hsf_b2 * x2_2 - hsf_a1 * y1_2 - hsf_a2 * y2_2
    x2_2, x1_2 = x1_2, y_hpf
    y2_2, y1_2 = y1_2, y_hsf

    sum_sq = sum_sq + y_hsf * y_hsf
  end
  return sqrt(sum_sq / block_samples)
end

-- ============================================================
-- CACHES TRIG + HANN
-- ============================================================
local trig_cache = {}
local hann_cache = {}

local function get_hann_window(N_eff)
  if hann_cache[N_eff] then return hann_cache[N_eff] end
  local w = {}
  local denom = max(N_eff - 1, 1)
  for n = 1, N_eff do
    w[n] = 0.5 * (1 - cos(2 * pi * (n - 1) / denom))
  end
  hann_cache[N_eff] = w
  return w
end

local function get_trig_tables(N_eff, n_bins)
  local key = N_eff .. "_" .. n_bins
  if trig_cache[key] then return trig_cache[key] end
  local ct, st = {}, {}
  for k = 1, n_bins do
    ct[k], st[k] = {}, {}
    for n = 1, N_eff do
      local angle = 2 * pi * k * (n - 1) / N_eff
      ct[k][n] = cos(angle)
      st[k][n] = sin(angle)
    end
  end
  trig_cache[key] = { cos = ct, sin = st }
  return trig_cache[key]
end

local function purge_caches()
  trig_cache = {}
  hann_cache = {}
end

-- ============================================================
-- HELPER SLIDERS AVEC RESET SUR DOUBLE-CLIC
-- ============================================================
local function slider_double(label, val, min_v, max_v, fmt, def_v)
  local changed, new_val = r.ImGui_SliderDouble(ctx, label, val, min_v, max_v, fmt)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    return true, def_v
  end
  return changed, new_val
end

local function slider_int(label, val, min_v, max_v, fmt, def_v)
  local changed, new_val = r.ImGui_SliderInt(ctx, label, val, min_v, max_v, fmt)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    return true, def_v
  end
  return changed, new_val
end

-- ============================================================
-- ANALYSE D'UN SEUL BLOC (Avec RMS perçu + RMS brut)
-- ============================================================
local function analyze_block(buf, block_samples, nch, samplerate, n_bins, ds, N_eff, trig, hann, mono, ds_buf, mags, low_cut_bins)
  mono   = mono   or {}
  ds_buf = ds_buf or {}
  mags   = mags   or {}

  -- Mixdown mono
  if nch == 1 then
    for i = 1, block_samples do
      mono[i] = buf[i]
    end
  else
    for i = 1, block_samples do
      local s    = 0
      local base = (i - 1) * nch
      for c = 0, nch - 1 do
        s = s + buf[base + c + 1]
      end
      mono[i] = s / nch
    end
  end

  -- DC Blocker
  local dc_sum = 0
  for i = 1, block_samples do dc_sum = dc_sum + mono[i] end
  local dc = dc_sum / block_samples
  if abs(dc) > 1e-6 then
    for i = 1, block_samples do mono[i] = mono[i] - dc end
  end

  -- RMS Brut
  local sum_sq = 0
  for i = 1, block_samples do sum_sq = sum_sq + mono[i] * mono[i] end
  local rms = sqrt(sum_sq / block_samples)

  -- RMS Perceptif (K-weighting inspiré) pour le calcul de gain/cible
  local weighted_rms = compute_perceptive_rms(mono, block_samples, samplerate)

  -- ZCR
  local zc = 0
  for i = 2, block_samples do
    if (mono[i] >= 0) ~= (mono[i-1] >= 0) then zc = zc + 1 end
  end
  local zcr = (block_samples > 1) and (zc / (block_samples - 1)) or 0

  -- Sous-échantillonnage + Hann
  local idx = 0
  for i = 1, block_samples, ds do
    idx = idx + 1
    ds_buf[idx] = mono[i] * (hann[idx] or 0)
  end
  if idx > N_eff then idx = N_eff end

  -- DFT Partielle (Spectral Centroid)
  local sr_eff     = samplerate / ds
  local freq_step  = sr_eff / N_eff
  local k_start    = (low_cut_bins or 2) + 1

  local sum_mag, sum_weighted = 0, 0
  for k = k_start, n_bins do
    local re, im = 0, 0
    local ck = trig.cos[k]
    local sk = trig.sin[k]
    for n = 1, idx do
      local s = ds_buf[n]
      re = re + s * ck[n]
      im = im - s * sk[n]
    end
    local mag = sqrt(re*re + im*im)
    mags[k]      = mag
    sum_mag      = sum_mag + mag
    sum_weighted = sum_weighted + mag * (k * freq_step)
  end

  local sc = (sum_mag > 0) and (sum_weighted / sum_mag) or 0

  return rms, weighted_rms, zcr, sc, mags, sum_mag
end

-- ============================================================
-- ÉTAT GLOBAL ASYNC
-- ============================================================
local async = {
  running       = false,
  cancelled     = false,
  progress      = 0.0,
  blocks        = nil,
  done          = false,
  aa            = nil,
  samplerate    = 0,
  nch           = 0,
  n_blocks      = 0,
  block_samples = 0,
  N_eff         = 0,
  n_bins        = 0,
  ds            = 0,
  trig          = nil,
  hann          = nil,
  cfg           = nil,
  cur_block     = 0,
  buf           = nil,
  prev_mags     = nil,
  flux_smooth   = 0,
}

-- ============================================================
-- ANALYSE ASYNC — chunk par chunk
-- ============================================================
local BLOCKS_PER_DEFER = 40

local function async_analyze_chunk()
  if async.cancelled then
    if async.aa then r.DestroyAudioAccessor(async.aa) end
    async.running     = false
    async.done        = false
    async.flux_smooth = 0
    async.prev_mags   = nil
    r.ShowConsoleMsg("[VVM] Analysis cancelled.\n")
    return
  end

  local ok, err = pcall(function()

  local cfg    = async.cfg
  local aa     = async.aa
  local sr     = async.samplerate
  local nch    = async.nch
  local bs     = async.block_samples
  local N_eff  = async.N_eff
  local n_bins = async.n_bins
  local ds     = async.ds
  local trig   = async.trig
  local hann   = async.hann
  local buf    = async.buf
  local blocks = async.blocks

  local stop_at = min(async.cur_block + BLOCKS_PER_DEFER - 1, async.n_blocks - 1)

  local item_pos = async.item_pos
  local playrate = async.playrate

  for b = async.cur_block, stop_at do
    local t_proj   = b * bs / sr
    local t_timeline = item_pos + t_proj
    local t_env    = t_proj * playrate

    r.GetAudioAccessorSamples(aa, sr, nch, t_timeline, bs, buf)

    local rms, weighted_rms, zcr, sc, mags, sum_mag = analyze_block(
      buf, bs, nch, sr, n_bins, ds, N_eff, trig, hann,
      async.mono, async.ds_buf, async.mags,
      cfg.low_cut_bins
    )

    -- Flux spectral
    local flux = 0
    if async.prev_mags and sum_mag > 0 then
      for k = 1, n_bins do
        local diff = (mags[k] or 0) - (async.prev_mags[k] or 0)
        if diff > 0 then flux = flux + diff end
      end
      flux = flux / sum_mag
    end
    async.flux_smooth = cfg.flux_alpha * async.flux_smooth
                      + (1 - cfg.flux_alpha) * flux
    async.prev_mags = mags

    blocks[b + 1] = {
      t_timeline     = t_timeline,
      t_env          = t_env,
      rms            = rms,
      rms_db         = lin_to_db(rms),
      weighted_rms   = weighted_rms,
      weighted_rms_db= lin_to_db(weighted_rms),
      zcr            = zcr,
      sc             = sc,
      flux           = async.flux_smooth,
      is_tonal       = false,
    }
  end

  async.cur_block = stop_at + 1
  async.progress  = async.cur_block / async.n_blocks

  if async.cur_block >= async.n_blocks then
    r.DestroyAudioAccessor(aa)
    async.aa = nil

    -- Seuil de silence adaptatif basé sur le RMS perceptif
    local rms_values = {}
    for i = 1, #blocks do rms_values[i] = blocks[i].weighted_rms end
    table.sort(rms_values)
    local p10_idx   = max(1, floor(#rms_values * 0.10))
    local noise_rms = rms_values[p10_idx] or 0.0001
    local noise_db  = lin_to_db(noise_rms)
    local adaptive_silence = clamp(noise_db + 6, -60, -30)
    
    r.ShowConsoleMsg(string.format(
      "[VVM] Noise floor estimate: %.1f dB → adaptive silence threshold: %.1f dB\n",
      noise_db, adaptive_silence))

    -- Classification brute
    local raw_tonal = {}
    for i = 1, #blocks do
      local bl       = blocks[i]
      local audible  = bl.weighted_rms_db > adaptive_silence
      local low_zcr  = bl.zcr   < cfg.zcr_tonal_max
      local low_sc   = bl.sc    < cfg.sc_tonal_max
      local no_onset = bl.flux  < cfg.flux_onset_thresh
      raw_tonal[i]   = audible and low_zcr and low_sc and no_onset
    end

    -- Lissage temporel
    local sf = cfg.smooth_frames
    for i = 1, #blocks do
      local votes, total = 0, 0
      for j = max(1, i - sf), min(#blocks, i + sf) do
        votes = votes + (raw_tonal[j] and 1 or 0)
        total = total + 1
      end
      blocks[i].is_tonal = (votes / total) > 0.5
    end

    async.running = false
    async.done    = true
    r.ShowConsoleMsg(string.format("[VVM] Analysis complete — %d blocks.\n", #blocks))
  else
    r.defer(async_analyze_chunk)
  end

  end) -- fin pcall

  if not ok then
    if async.aa then
      r.DestroyAudioAccessor(async.aa)
      async.aa = nil
    end
    async.running     = false
    async.done        = false
    async.flux_smooth = 0
    async.prev_mags   = nil
    r.ShowConsoleMsg("[VVM] ERREUR dans l'analyse : " .. tostring(err) .. "\n")
    r.ShowMessageBox(
      "Erreur fatale pendant l'analyse :\n" .. tostring(err),
      "Erreur d'analyse", 0)
  end
end

-- ============================================================
-- LANCEMENT ANALYSE
-- ============================================================
local function start_analysis(item, cfg)
  local take = r.GetActiveTake(item)
  if not take then return false, "Pas de take actif" end

  local src_check = r.GetMediaItemTake_Source(take)
  if not src_check then
    return false, "Take sans source audio"
  end
  local src_filename = r.GetMediaSourceFileName(src_check, "")
  if src_filename == "" then
    return false, "Source audio vide ou offline"
  end
  local src_type = r.GetMediaSourceType(src_check, "")
  if src_type == "MIDI" or src_type == "EMPTY" then
    return false, "This take is of type " .. src_type .. " — please select an audio take"
  end

  local track      = r.GetMediaItem_Track(item)
  local samplerate = r.GetMediaSourceSampleRate(src_check)
  local nch        = r.GetMediaSourceNumChannels(src_check)
  local item_pos   = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len   = r.GetMediaItemInfo_Value(item, "D_LENGTH")

  local playrate   = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate == 0 then playrate = 1.0 end

  if samplerate <= 0 then samplerate = 44100 end
  if nch < 1        then nch = 1 end

  local block_samples = floor(samplerate * cfg.block_ms / 1000)
  if block_samples < 4 then return false, "Bloc trop petit (augmente block_ms)" end

  local n_blocks = floor((samplerate * item_len) / block_samples)
  if n_blocks < 1 then return false, "Item trop court" end

  local ds    = cfg.dft_downsample
  local N_eff = compute_N_eff(block_samples, ds)
  if N_eff < 4 then return false, "N_eff too small" end

  local n_bins = min(cfg.n_bins, floor(N_eff / 2))
  if n_bins < 1 then return false, "n_bins invalide" end

  local freq_max = compute_freq_max(samplerate, ds, N_eff, n_bins)
  r.ShowConsoleMsg(string.format(
    "[VVM] sr=%d Hz | nch=%d | block=%d smp | N_eff=%d | n_bins=%d | freq_max=%.0f Hz\n",
    samplerate, nch, block_samples, N_eff, n_bins, freq_max
  ))

  local trig = get_trig_tables(N_eff, n_bins)
  local hann = get_hann_window(N_eff)

  local buf = r.new_array(block_samples * nch)
  local aa = r.CreateTrackAudioAccessor(track)

  async.running       = true
  async.cancelled     = false
  async.done          = false
  async.progress      = 0.0
  async.blocks        = {}
  async.aa            = aa
  async.samplerate    = samplerate
  async.nch           = nch
  async.n_blocks      = n_blocks
  async.block_samples = block_samples
  async.N_eff         = N_eff
  async.n_bins        = n_bins
  async.ds            = ds
  async.trig          = trig
  async.hann          = hann
  async.cfg           = cfg
  async.cur_block     = 0
  async.buf           = buf
  async.prev_mags     = nil
  async.flux_smooth   = 0
  async.item_pos      = item_pos
  async.playrate      = playrate
  
  async.mono   = {}
  async.ds_buf = {}
  async.mags   = {}
  for i = 1, block_samples do async.mono[i] = 0 end
  for i = 1, N_eff         do async.ds_buf[i] = 0; async.mags[i] = 0 end

  r.defer(async_analyze_chunk)
  return true, nil
end

-- ============================================================
-- SEGMENTATION — Gap Bridging
-- ============================================================
local function build_segments(blocks, min_seg_ms, block_ms, max_gap_ms)
  if #blocks == 0 then return {} end

  max_gap_ms          = max_gap_ms or 100
  local max_gap_blks  = ceil(max_gap_ms / block_ms)
  local min_blks      = max(1, ceil(min_seg_ms / block_ms))

  -- Passe 1 : segments tonaux bruts
  local raw = {}
  local cur = nil
  for i, bl in ipairs(blocks) do
    if bl.is_tonal then
      if not cur then cur = { from = i, to = i }
      else             cur.to = i end
    else
      if cur then raw[#raw + 1] = cur; cur = nil end
    end
  end
  if cur then raw[#raw + 1] = cur end

  -- Passe 2 : Gap Bridging
  local merged = {}
  if #raw > 0 then
    local current = raw[1]
    for i = 2, #raw do
      local nxt = raw[i]
      local gap = nxt.from - current.to
      if gap <= max_gap_blks then
        for b = current.to + 1, nxt.from - 1 do
          blocks[b].is_tonal = true
        end
        current.to = nxt.to
      else
        merged[#merged + 1] = current
        current = nxt
      end
    end
    merged[#merged + 1] = current
  end

  -- Passe 3 : calcul avg_rms perceptif, filtrage par taille minimum
  local final = {}
  for _, seg in ipairs(merged) do
    local count = seg.to - seg.from + 1
    if count >= min_blks then
      local rms_sum = 0
      for i = seg.from, seg.to do rms_sum = rms_sum + blocks[i].weighted_rms end
      final[#final + 1] = {
        from     = seg.from,
        to       = seg.to,
        is_tonal = true,
        avg_rms  = rms_sum / count,
        count    = count,
      }
    end
  end

  return final
end

-- ============================================================
-- CALCUL DES GAINS (Avec Lissage Asymétrique Attack / Release)
-- ============================================================
local function compute_gains(segments, blocks, target_db, macro_pct, per_block, smooth_attack, smooth_release, gate_db)
  smooth_attack  = smooth_attack or 0.15
  smooth_release = smooth_release or 0.35
  gate_db        = gate_db or -40.0
  local gains = {}
  for i = 1, #blocks do gains[i] = 1.0 end

  local gain_min = db_to_lin(-18)
  local gain_max = db_to_lin(12)

  for _, seg in ipairs(segments) do
    if seg.is_tonal then
      if per_block then
        for i = seg.from, seg.to do
          local bl_db = blocks[i].weighted_rms_db
          if bl_db > gate_db then
            local delta_db    = target_db - bl_db
            local applied_db  = delta_db * macro_pct
            local applied_lin = db_to_lin(applied_db)
            gains[i] = clamp(applied_lin, gain_min, gain_max)
          end
        end
      else
        local seg_db = lin_to_db(seg.avg_rms)
        if seg_db > gate_db then
          local delta_db    = target_db - seg_db
          local applied_db  = delta_db * macro_pct
          local applied_lin = db_to_lin(applied_db)
          local gain_lin    = clamp(applied_lin, gain_min, gain_max)
          for i = seg.from, seg.to do
            gains[i] = gain_lin
          end
        end
      end
    end
  end

  -- Lissage exponentiel asymétrique double-pass (Attack / Release)
  if per_block then
    for _, seg in ipairs(segments) do
      if seg.is_tonal and seg.to > seg.from then
        local cur_g = gains[seg.from]
        -- Passage aller
        for i = seg.from + 1, seg.to do
          local target_g = gains[i]
          local alpha = (target_g < cur_g) and smooth_attack or smooth_release
          cur_g = cur_g + alpha * (target_g - cur_g)
          gains[i] = cur_g
        end
        -- Passage retour
        cur_g = gains[seg.to]
        for i = seg.to - 1, seg.from, -1 do
          local target_g = gains[i]
          local alpha = (target_g < cur_g) and smooth_attack or smooth_release
          cur_g = cur_g + alpha * (target_g - cur_g)
          gains[i] = cur_g
        end
      end
    end
  end

  return gains
end

-- ============================================================
-- APPLICATION — TAKE ENVELOPE
-- ============================================================
local function apply_take_envelope(item, blocks, gains, fade_ms, block_ms)
  local take = r.GetActiveTake(item)
  if not take then return false end

  if not gains or #gains == 0 then
    r.ShowMessageBox("No gain data. Run the analysis first.", "Error", 0)
    return false
  end

  local playrate   = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate == 0 then playrate = 1.0 end

  local env = r.GetTakeEnvelopeByName(take, "Volume")
  if not env then
    r.SelectAllMediaItems(0, false)
    r.SetMediaItemSelected(item, true)
    r.Main_OnCommand(40693, 0)
    env = r.GetTakeEnvelopeByName(take, "Volume")
  end
  if not env then
    r.ShowMessageBox("Could not create Take Volume Envelope.", "Error", 0)
    return false
  end

  do
    local _, env_str = r.GetEnvelopeStateChunk(env, "", false)
    if env_str then
      if env_str:find("ARM 0") then
        env_str = env_str:gsub("ARM 0", "ARM 1")
        r.SetEnvelopeStateChunk(env, env_str, false)
      elseif not env_str:find("ARM ") then
        env_str = env_str:gsub("(\n)", "%1ARM 1\n", 1)
        r.SetEnvelopeStateChunk(env, env_str, false)
      end
    end
  end

  local block_sec   = block_ms / 1000.0
  local fade_sec    = fade_ms  / 1000.0
  local actual_fade = min(fade_sec, block_sec * 0.9)

  local env_mode = r.GetEnvelopeScalingMode(env)
  local function to_env(g)
    return r.ScaleToEnvelopeMode(env_mode, g)
  end

  r.DeleteEnvelopePointRange(env, 0, 1e12)

  local last_inserted_g = gains[1]
  local n_points = 1
  
  r.InsertEnvelopePoint(env, 0, to_env(last_inserted_g), 0, 0, false, true)

  for i = 2, #blocks do
    local env_t  = blocks[i].t_env
    local g_cur  = gains[i]
    local g_prev = gains[i - 1]

    local is_step  = abs(g_cur - g_prev)          > 0.05
    local is_drift = abs(g_cur - last_inserted_g) > 0.015
    local is_last  = (i == #blocks)

    if is_step or is_drift or is_last then
      if is_step then
        local env_t_prev = blocks[i - 1].t_env
        local fade_start = max(
          env_t  - (actual_fade * playrate),
          env_t_prev + (block_sec * 0.1 * playrate)
        )
        r.InsertEnvelopePoint(env, fade_start, to_env(g_prev), 0, 0, false, true)
        n_points = n_points + 1
      end

      r.InsertEnvelopePoint(env, env_t, to_env(g_cur), 0, 0, false, true)
      last_inserted_g = g_cur
      n_points = n_points + 1
    end
  end

  local item_len     = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local end_env_t    = item_len * playrate
  r.InsertEnvelopePoint(env, end_env_t, to_env(1.0), 0, 0, false, true)

  r.Envelope_SortPoints(env)
  r.UpdateItemInProject(item)
  r.UpdateArrange()
  return true
end

-- ============================================================
-- PERSISTANCE DES PARAMÈTRES
-- ============================================================
local EXT_SECTION = "VocalVolumeMacro_v66"

local function ext_load(key, default)
  local ok, val = pcall(function()
    local s = r.GetExtState(EXT_SECTION, key)
    return (s ~= "") and tonumber(s) or default
  end)
  return ok and val or default
end

local function ext_save(key, val)
  r.SetExtState(EXT_SECTION, key, tostring(val), true)
end

local function load_settings()
  return {
    zcr_thresh     = ext_load("zcr_thresh",     CFG.zcr_tonal_max),
    sc_thresh      = ext_load("sc_thresh",      CFG.sc_tonal_max),
    flux_thresh    = ext_load("flux_thresh",    CFG.flux_onset_thresh),
    block_ms       = ext_load("block_ms",       CFG.block_ms),
    target_db      = ext_load("target_db",     -18.0),
    gate_db        = ext_load("gate_db",       -40.0),
    gap_ms         = ext_load("gap_ms",        100),
    macro_pct      = ext_load("macro_pct",     80),
    fade_ms        = ext_load("fade_ms",       CFG.fade_ms),
    per_block      = (ext_load("per_block", 0) == 1),
    smooth_attack  = ext_load("smooth_attack",  0.15),
    smooth_release = ext_load("smooth_release", 0.35),
  }
end

local function save_settings(g)
  ext_save("zcr_thresh",     g.zcr_thresh)
  ext_save("sc_thresh",      g.sc_thresh)
  ext_save("flux_thresh",    g.flux_thresh)
  ext_save("block_ms",       g.block_ms)
  ext_save("target_db",      g.target_db)
  ext_save("gate_db",        g.gate_db)
  ext_save("gap_ms",         g.gap_ms)
  ext_save("macro_pct",      g.macro_pct)
  ext_save("fade_ms",        g.fade_ms)
  ext_save("per_block",      g.per_block and 1 or 0)
  ext_save("smooth_attack",  g.smooth_attack)
  ext_save("smooth_release", g.smooth_release)
end

local _saved = load_settings()
local gui = {
  item           = nil,
  item_name      = "",
  item_locked    = false,
  analyzed       = false,
  blocks         = nil,
  segments       = nil,
  zcr_thresh     = _saved.zcr_thresh,
  sc_thresh      = _saved.sc_thresh,
  flux_thresh    = _saved.flux_thresh,
  block_ms       = _saved.block_ms,
  target_db      = _saved.target_db,
  gate_db        = _saved.gate_db,
  gap_ms         = _saved.gap_ms,
  macro_pct      = _saved.macro_pct,
  fade_ms        = _saved.fade_ms,
  per_block      = _saved.per_block,
  smooth_attack  = _saved.smooth_attack,
  smooth_release = _saved.smooth_release,
  stats          = { n_tonal=0, n_noise=0, avg_rms_db=-144, n_segments=0 },
  preview_gains  = nil,
  freq_max_hz    = 0,
  auto_target_db = nil,
  prev_block_ms  = -1,
  prev_ds        = -1,
  analysis_start = nil,
}

-- ============================================================
-- RECLASSIFICATION LIVE (Sans relire l'audio)
-- ============================================================
local function live_reclassify()
  if not gui.blocks or #gui.blocks == 0 then return end
  local cfg = CFG
  cfg.zcr_tonal_max     = gui.zcr_thresh
  cfg.sc_tonal_max      = gui.sc_thresh
  cfg.flux_onset_thresh = gui.flux_thresh

  local rms_values = {}
  for i = 1, #gui.blocks do rms_values[i] = gui.blocks[i].weighted_rms end
  table.sort(rms_values)
  local p10_idx   = max(1, floor(#rms_values * 0.10))
  local noise_rms = rms_values[p10_idx] or 0.0001
  local noise_db  = lin_to_db(noise_rms)
  local adaptive_silence = clamp(noise_db + 6, -60, -30)

  local raw_tonal = {}
  for i = 1, #gui.blocks do
    local bl       = gui.blocks[i]
    local audible  = bl.weighted_rms_db > adaptive_silence
    local low_zcr  = bl.zcr   < cfg.zcr_tonal_max
    local low_sc   = bl.sc    < cfg.sc_tonal_max
    local no_onset = bl.flux  < cfg.flux_onset_thresh
    raw_tonal[i]   = audible and low_zcr and low_sc and no_onset
  end

  local sf = cfg.smooth_frames
  for i = 1, #gui.blocks do
    local votes, total = 0, 0
    for j = max(1, i - sf), min(#gui.blocks, i + sf) do
      votes = votes + (raw_tonal[j] and 1 or 0)
      total = total + 1
    end
    gui.blocks[i].is_tonal = (votes / total) > 0.5
  end

  gui.segments = build_segments(gui.blocks, CFG.min_seg_ms, CFG.block_ms, gui.gap_ms)

  local n_tonal, n_noise = 0, 0
  for _, bl in ipairs(gui.blocks) do
    if bl.is_tonal then n_tonal = n_tonal + 1 else n_noise = n_noise + 1 end
  end
  gui.stats.n_tonal    = n_tonal
  gui.stats.n_noise    = n_noise
  gui.stats.n_segments = #gui.segments

  gui.preview_gains = compute_gains(
    gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100,
    gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db
  )
end

-- ============================================================
-- GUI
-- ============================================================
local function draw_gui()
  local W, H = 530, 820
  r.ImGui_SetNextWindowSize(ctx, W, H, r.ImGui_Cond_FirstUseEver())
  r.ImGui_SetNextWindowPos(ctx, 80, 60, r.ImGui_Cond_FirstUseEver())

  local vis, open = r.ImGui_Begin(ctx, "🎙 Vocal Volume Macro v1.5.1", true)
  if not vis then
    return open
  end

  -- ── Item ─────────────────────────────────────────────────
  r.ImGui_SeparatorText(ctx, "Target item")

  if not gui.item_locked then
    local sel = r.GetSelectedMediaItem(0, 0)
    if sel then
      local tk = r.GetActiveTake(sel)
      gui.item      = sel
      gui.item_name = tk and r.GetTakeName(tk) or "?"

      if tk then
        local src = r.GetMediaItemTake_Source(tk)
        if src then
          local sr = r.GetMediaSourceSampleRate(src)
          if sr > 0 then
            local bs = floor(sr * CFG.block_ms / 1000)
            local ne = compute_N_eff(bs, CFG.dft_downsample)
            local nb = min(CFG.n_bins, floor(ne / 2))
            gui.freq_max_hz = compute_freq_max(sr, CFG.dft_downsample, ne, nb)
          end
        end
      end
    else
      gui.item      = nil
      gui.item_name = ""
      if gui.freq_max_hz == 0 then
        local sr = 44100
        local bs = floor(sr * CFG.block_ms / 1000)
        local ne = compute_N_eff(bs, CFG.dft_downsample)
        local nb = min(CFG.n_bins, floor(ne / 2))
        gui.freq_max_hz = compute_freq_max(sr, CFG.dft_downsample, ne, nb)
      end
    end
  end

  if gui.item then
    r.ImGui_TextColored(ctx, 0x88FF88FF, "✓ " .. gui.item_name)
    if gui.item_locked then
      r.ImGui_SameLine(ctx)
      r.ImGui_TextDisabled(ctx, " [locked]")
      r.ImGui_SameLine(ctx)
      if r.ImGui_SmallButton(ctx, "Change") then
        gui.item_locked    = false
        gui.analyzed       = false
        gui.blocks         = nil
        gui.segments       = nil
        gui.auto_target_db = nil
      end
    else
      r.ImGui_SameLine(ctx)
      r.ImGui_TextDisabled(ctx, " [select then Analyse]")
    end
  else
    r.ImGui_TextColored(ctx, 0xFF6666FF, "✗ Select an audio item in REAPER")
  end

  r.ImGui_Spacing(ctx)

  -- ── Barre de progression ─────────────────────────────────
  if async.running then
    r.ImGui_SeparatorText(ctx, "Analysis in progress...")
    local eta_str = ""
    if gui.analysis_start and async.progress > 0.02 then
      local elapsed   = r.time_precise() - gui.analysis_start
      local total_est = elapsed / async.progress
      local remaining = max(0, total_est - elapsed)
      if remaining < 60 then
        eta_str = string.format("  (~%ds remaining)", ceil(remaining))
      else
        eta_str = string.format("  (~%dm%02ds remaining)",
          floor(remaining/60), floor(remaining%60))
      end
    end
    r.ImGui_ProgressBar(ctx, async.progress, -1, 0,
      string.format("Block %d / %d  (%.0f%%)%s",
        async.cur_block, async.n_blocks, async.progress * 100, eta_str))
    if r.ImGui_Button(ctx, "✖ Cancel", 160, 28) then
      async.cancelled = true
    end
    r.ImGui_End(ctx)
    return open
  end

  if async.done then
    async.done   = false
    gui.blocks   = async.blocks
    gui.segments = build_segments(gui.blocks, CFG.min_seg_ms, CFG.block_ms, gui.gap_ms)
    gui.analyzed = true

    local n_tonal, n_noise = 0, 0
    local rms_sum, tonal_rms_sum = 0, 0

    for _, bl in ipairs(gui.blocks) do
      if bl.is_tonal then
        n_tonal       = n_tonal + 1
        tonal_rms_sum = tonal_rms_sum + bl.weighted_rms
      else
        n_noise = n_noise + 1
      end
      rms_sum = rms_sum + bl.weighted_rms
    end

    gui.stats = {
      n_tonal    = n_tonal,
      n_noise    = n_noise,
      avg_rms_db = lin_to_db(rms_sum / max(1, #gui.blocks)),
      n_segments = #gui.segments,
    }

    if n_tonal > 0 then
      local avg_tonal_db = lin_to_db(tonal_rms_sum / n_tonal)
      if avg_tonal_db > -60 then
        gui.auto_target_db = clamp(avg_tonal_db, -40, -6)
        gui.target_db      = gui.auto_target_db
        save_settings(gui)
      end
    end

    gui.preview_gains = compute_gains(
      gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100, gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db)
  end

  -- ── Paramètres d'analyse (Live Sliders) ───────────────────
  r.ImGui_SeparatorText(ctx, "Analysis parameters (Live)")
  local changed, zcr_changed, sc_changed, flux_changed

  r.ImGui_Text(ctx, "ZCR threshold  (tonal if below)")
  r.ImGui_SetNextItemWidth(ctx, 350)
  zcr_changed, gui.zcr_thresh = slider_double("##zcr", gui.zcr_thresh, 0.05, 0.40, "%.3f", CFG.zcr_tonal_max)
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_SetTooltip(ctx, "Low → pure vowels | High → soft fricatives included")
  end

  local sc_max = max(gui.freq_max_hz > 0 and gui.freq_max_hz or 22050, 500.0)
  gui.sc_thresh = clamp(gui.sc_thresh, 200, sc_max)
  
  r.ImGui_Text(ctx, "Spectral centroid max (Hz)")
  if gui.freq_max_hz > 0 then
    r.ImGui_SameLine(ctx)
    r.ImGui_TextColored(ctx, 0xFFDD66FF, string.format("  ← max analysed: %.0f Hz", gui.freq_max_hz))
  end
  r.ImGui_SetNextItemWidth(ctx, 350)
  sc_changed, gui.sc_thresh = slider_double("##sc", gui.sc_thresh, 200, sc_max, "%.0f Hz", CFG.sc_tonal_max)

  r.ImGui_Text(ctx, "Consonant onset sensitivity (Flux)")
  r.ImGui_SetNextItemWidth(ctx, 350)
  flux_changed, gui.flux_thresh = slider_double("##flux", gui.flux_thresh, 0.05, 1.0, "%.2f", CFG.flux_onset_thresh)

  if (zcr_changed or sc_changed or flux_changed) and gui.analyzed then
    live_reclassify()
  end
  if zcr_changed or sc_changed or flux_changed then
    save_settings(gui)
  end

  r.ImGui_Text(ctx, "Analysis resolution (ms / block)")
  r.ImGui_SetNextItemWidth(ctx, 350)
  changed, gui.block_ms = slider_double("##blk", gui.block_ms, 5, 30, "%.0f ms", CFG.block_ms)
  if changed then
    gui.analyzed      = false
    gui.blocks        = nil
    gui.segments      = nil
    gui.preview_gains = nil
    save_settings(gui)
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_SeparatorText(ctx, "Correction parameters")

  r.ImGui_Text(ctx, "Target RMS level (dB - Perceptive K-Weight)")
  r.ImGui_SetNextItemWidth(ctx, 295)
  changed, gui.target_db = slider_double("##tgt", gui.target_db, -40, -6, "%.1f dB", -18.0)

  if gui.analyzed and gui.auto_target_db then
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "↺ Auto") then
      gui.target_db = gui.auto_target_db
      changed = true
    end
  end

  if changed and gui.analyzed then
    gui.preview_gains = compute_gains(
      gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100, gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db)
  end
  if changed then save_settings(gui) end

  r.ImGui_Text(ctx, "Gate threshold (ignore blocks below)")
  r.ImGui_SetNextItemWidth(ctx, 350)
  changed, gui.gate_db = slider_double("##gate", gui.gate_db, -60, -10, "%.1f dB", -40.0)
  if changed and gui.analyzed then
    gui.preview_gains = compute_gains(
      gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100,
      gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db)
  end
  if changed then save_settings(gui) end

  r.ImGui_Text(ctx, "Vibrato / gap tolerance (ms)")
  r.ImGui_SetNextItemWidth(ctx, 350)
  changed, gui.gap_ms = slider_int("##gap", gui.gap_ms, 10, 200, "%d ms", 100)
  if changed then
    if gui.analyzed and gui.blocks then
      gui.segments = build_segments(gui.blocks, CFG.min_seg_ms, CFG.block_ms, gui.gap_ms)
      gui.preview_gains = compute_gains(
        gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100,
        gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db)
    end
    save_settings(gui)
  end

  r.ImGui_Text(ctx, "Correction strength (%)")
  r.ImGui_SetNextItemWidth(ctx, 350)
  changed, gui.macro_pct = slider_int("##mac", gui.macro_pct, 0, 100, gui.macro_pct .. "%%", 80)
  if changed and gui.analyzed then
    gui.preview_gains = compute_gains(
      gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100, gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db)
  end
  if changed then save_settings(gui) end

  r.ImGui_Text(ctx, "Transition fade (ms)")
  r.ImGui_SetNextItemWidth(ctx, 350)
  changed, gui.fade_ms = slider_double("##fad", gui.fade_ms, 1, 20, "%.0f ms", CFG.fade_ms)
  if gui.fade_ms > gui.block_ms * 0.9 then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFF8800FF)
    r.ImGui_TextWrapped(ctx, string.format("⚠ Effective fade: %.0f ms (90%% of block)", gui.block_ms * 0.9))
    r.ImGui_PopStyleColor(ctx)
  end

  r.ImGui_Spacing(ctx)

  changed, gui.per_block = r.ImGui_Checkbox(
    ctx, "Volume Rider mode (per-block gain 10ms)", gui.per_block)
  if changed and gui.analyzed then
    gui.preview_gains = compute_gains(
      gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100,
      gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db)
  end
  if changed then save_settings(gui) end

  -- Sliders de lissage asymétrique (Attack / Release)
  if gui.per_block then
    r.ImGui_Text(ctx, "Smooth Attack speed (catching peaks)")
    r.ImGui_SetNextItemWidth(ctx, 350)
    local att_changed, new_att = slider_double("##att", gui.smooth_attack, 0.01, 0.50, "Attack %.2f", 0.15)
    if att_changed then
      gui.smooth_attack = new_att
      if gui.analyzed then
        gui.preview_gains = compute_gains(gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100, gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db)
      end
      save_settings(gui)
    end

    r.ImGui_Text(ctx, "Smooth Release speed (boosting quiet words)")
    r.ImGui_SetNextItemWidth(ctx, 350)
    local rel_changed, new_rel = slider_double("##rel", gui.smooth_release, 0.01, 0.50, "Release %.2f", 0.35)
    if rel_changed then
      gui.smooth_release = new_rel
      if gui.analyzed then
        gui.preview_gains = compute_gains(gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100, gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db)
      end
      save_settings(gui)
    end
  end

  r.ImGui_Spacing(ctx)

  -- ── BOUTONS ──────────────────────────────────────────────
  r.ImGui_Separator(ctx)
  local btn_w = 225
  r.ImGui_SetCursorPosX(ctx, (W - btn_w * 2 - 12) / 2)

  local can_analyze = (gui.item ~= nil) and not async.running
  if not can_analyze then r.ImGui_BeginDisabled(ctx) end
  if r.ImGui_Button(ctx, "🔍 Analyse", btn_w, 38) then
    if gui.block_ms ~= gui.prev_block_ms or CFG.dft_downsample ~= gui.prev_ds then
      purge_caches()
      gui.prev_block_ms = gui.block_ms
      gui.prev_ds       = CFG.dft_downsample
    end

    CFG.block_ms          = gui.block_ms
    CFG.zcr_tonal_max     = gui.zcr_thresh
    CFG.sc_tonal_max      = gui.sc_thresh
    CFG.flux_onset_thresh = gui.flux_thresh
    CFG.per_block_gain    = gui.per_block

    gui.item_locked    = true
    gui.analyzed       = false
    gui.blocks         = nil
    gui.segments       = nil
    gui.freq_max_hz    = 0
    gui.auto_target_db = nil

    local ok, err = start_analysis(gui.item, CFG)
    if not ok then
      r.ShowMessageBox("Error: " .. (err or "?"), "Error", 0)
      gui.item_locked = false
    else
      gui.analysis_start = r.time_precise()
      local take = r.GetActiveTake(gui.item)
      if take then
        local src = r.GetMediaItemTake_Source(take)
        local sr  = r.GetMediaSourceSampleRate(src)
        local bs  = floor(sr * CFG.block_ms / 1000)
        local ne = compute_N_eff(bs, CFG.dft_downsample)
        local nb = min(CFG.n_bins, floor(ne / 2))
        gui.freq_max_hz = compute_freq_max(sr, CFG.dft_downsample, ne, nb)
        if gui.sc_thresh > gui.freq_max_hz then
          gui.sc_thresh = gui.freq_max_hz * 0.75
        end
      end
    end
  end
  if not can_analyze then r.ImGui_EndDisabled(ctx) end

  r.ImGui_SameLine(ctx)

  local can_apply = gui.analyzed and (gui.item ~= nil)
  if not can_apply then r.ImGui_BeginDisabled(ctx) end
  if r.ImGui_Button(ctx, "✅ Apply", btn_w, 38) then
    if not gui.segments or #gui.segments == 0 then
      r.ShowMessageBox("No segments detected.\nAnalysis may have failed.", "Error", 0)
    else
      local gains = compute_gains(
        gui.segments, gui.blocks, gui.target_db, gui.macro_pct / 100, gui.per_block, gui.smooth_attack, gui.smooth_release, gui.gate_db)
      r.Undo_BeginBlock()
      local ok = apply_take_envelope(
        gui.item, gui.blocks, gains, gui.fade_ms, gui.block_ms)
      r.Undo_EndBlock("Vocal Volume Macro v6.6", -1)
      if ok then
        r.ShowConsoleMsg("[VVM] Take Envelope written successfully!\n")
        r.ShowMessageBox(
          "Volume Macro applied ✓\n\n" ..
          "Mode: " .. (gui.per_block and "per block" or "per segment") .. "\n" ..
          gui.stats.n_segments .. " segments | " ..
          gui.stats.n_tonal   .. " tonal | " ..
          gui.stats.n_noise   .. " noise\n\n" ..
          "Ctrl+Z to undo.",
          "Success", 0)
      end
    end
  end
  if not can_apply then r.ImGui_EndDisabled(ctx) end

  r.ImGui_SameLine(ctx)
  local can_reset = (gui.item ~= nil) and not async.running
  if not can_reset then r.ImGui_BeginDisabled(ctx) end
  if r.ImGui_Button(ctx, "🗑 Reset env.", 140, 38) then
    local take = r.GetActiveTake(gui.item)
    if take then
      local env = r.GetTakeEnvelopeByName(take, "Volume")
      if env then
        r.Undo_BeginBlock()
        r.DeleteEnvelopePointRange(env, 0, 1e12)
        local env_mode_reset = r.GetEnvelopeScalingMode(env)
        r.InsertEnvelopePoint(env, 0, r.ScaleToEnvelopeMode(env_mode_reset, 1.0), 0, 0, false, true)
        r.Envelope_SortPoints(env)
        r.UpdateItemInProject(gui.item)
        r.UpdateArrange()
        r.Undo_EndBlock("VVM Reset Take Envelope", -1)
        r.ShowConsoleMsg("[VVM] Take Volume Envelope reset.\n")
      else
        r.ShowMessageBox("No Take Volume Envelope found on this item.", "Info", 0)
      end
    end
  end
  if not can_reset then r.ImGui_EndDisabled(ctx) end

  r.ImGui_Spacing(ctx)

  -- ── STATS & WAVEFORM ANALYZER ────────────────────────────
  if gui.analyzed then
    r.ImGui_SeparatorText(ctx, "Results")
    local s = gui.stats

    if r.ImGui_BeginTable(ctx, "statcols", 2) then
      r.ImGui_TableSetupColumn(ctx, "label")
      r.ImGui_TableSetupColumn(ctx, "value")

      local function stat_row(label, val, col)
        r.ImGui_TableNextRow(ctx)
        r.ImGui_TableSetColumnIndex(ctx, 0)
        r.ImGui_Text(ctx, label .. " :")
        r.ImGui_TableSetColumnIndex(ctx, 1)
        r.ImGui_TextColored(ctx, col, val)
      end

      stat_row("Segments",      tostring(s.n_segments),                  0xFFDD66FF)
      stat_row("Tonal blocks",  tostring(s.n_tonal),                     0x88FF88FF)
      stat_row("Noise blocks",  tostring(s.n_noise),                     0xFF8866FF)
      stat_row("Avg Perceptual RMS", string.format("%.1f dB", s.avg_rms_db), 0xAADDFFFF)
      stat_row("Auto-target",   string.format("%.1f dB  ⟵ auto", gui.target_db), 0xFFDD66FF)

      if gui.preview_gains then
        local sum_db, cnt = 0, 0
        for i, bl in ipairs(gui.blocks) do
          if bl.is_tonal and gui.preview_gains[i] then
            sum_db = sum_db + lin_to_db(gui.preview_gains[i])
            cnt    = cnt + 1
          end
        end
        if cnt > 0 then
          local avg = sum_db / cnt
          stat_row("Δ avg gain (tonal)",
            string.format("%s%.1f dB", avg >= 0 and "+" or "", avg),
            avg >= 0 and 0x88FF88FF or 0xFF8866FF)
        end
      end

      r.ImGui_EndTable(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_SeparatorText(ctx, "Visual Waveform Analyzer")
    
    local draw_list = r.ImGui_GetWindowDrawList(ctx)
    local canvas_w = 480 
    local canvas_h = 60  
    local cx, cy = r.ImGui_GetCursorScreenPos(ctx)
    
    r.ImGui_DrawList_AddRectFilled(draw_list, cx, cy, cx + canvas_w, cy + canvas_h, 0x1A1A1AFF)
    r.ImGui_DrawList_AddRect(draw_list, cx, cy, cx + canvas_w, cy + canvas_h, 0x444444FF)
    
    local total_blks = #gui.blocks
    if total_blks > 0 then
      local step_x = canvas_w / total_blks
      local center_y = cy + (canvas_h / 2)
      
      local max_rms = 0.001
      for i = 1, total_blks do
        if gui.blocks[i].weighted_rms > max_rms then max_rms = gui.blocks[i].weighted_rms end
      end
      
      for i = 1, total_blks do
        local bl = gui.blocks[i]
        local norm_rms = bl.weighted_rms / max_rms
        local bar_h = max(1, norm_rms * (canvas_h - 4) / 2) 
        
        local x1 = cx + ((i - 1) * step_x)
        local x2 = cx + (i * step_x)
        if x2 - x1 < 1 then x2 = x1 + 1 end
        
        local color = 0x555555FF 
        if bl.is_tonal then
          if bl.weighted_rms_db > gui.gate_db then
            color = 0x44FF44FF 
          else
            color = 0x008800FF 
          end
        elseif bl.weighted_rms_db > gui.gate_db then
          color = 0xFF5555FF 
        end
        
        r.ImGui_DrawList_AddRectFilled(draw_list, x1, center_y - bar_h, x2, center_y + bar_h, color)
      end
    end
    
    r.ImGui_Dummy(ctx, canvas_w, canvas_h)
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_TextDisabled(ctx, "Take Envelope follows item if moved  |  Ctrl+Z to undo")

  r.ImGui_End(ctx)
  return open
end

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================
if not r.APIExists("ImGui_CreateContext") then
  r.ShowMessageBox("This script requires ReaImGui.", "ReaImGui required", 0)
  return
end

ctx = r.ImGui_CreateContext("VocalVolumeMacro_v66")

local function loop()
  local open = draw_gui()
  if open then
    r.defer(loop)
  else
    save_settings(gui)
    if async.aa then
      r.DestroyAudioAccessor(async.aa)
      async.aa      = nil
      async.running = false
    end
  end
end

r.defer(loop)