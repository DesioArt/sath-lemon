-- SATH_HaZe
-- generative composer inspired by the
-- GC Haze (Glitch Cloud Audio)
--
-- 6 softcut voices:
--   1,2 = L loop (independent play/record heads)
--   3,4 = R loop
--   5 = loaded vinyl/texture layer (offset 60s)
--   6 = echo mode: rhythmic subdivision
--       repeats (offset 20s)
--
-- controlled via two Launchpad Mini MK3
-- through midigrid (grid 128, 16x8)

-- note: with the midigrid mod active (SYSTEM > MODS,
-- size 128) the library is not included manually:
-- just grid.connect() as with a real monome grid,
-- the mod combines the two Launchpads into a single
-- virtual 16x8 grid

-- note: softcut is built into norns core,
-- it is not a SuperCollider engine: it must not
-- be declared with engine.name (this was causing
-- the "missing SoftCut" error)

local fileselect = require 'fileselect'

-- ------------------------------------------
-- step <-> frequency conversion on a
-- logarithmic scale (the ear perceives pitch
-- exponentially, not linearly: a linear
-- 0-20000hz mapping "wastes" half the row
-- on an almost imperceptible range)
-- ------------------------------------------
local FILTER_MIN_HZ = 80
local FILTER_MAX_HZ = 12000 -- real ceiling of the softcut filter

local function step_to_freq(step) -- step: 0..15
  local t = step / 15
  return FILTER_MIN_HZ * (FILTER_MAX_HZ / FILTER_MIN_HZ) ^ t
end

local function freq_to_step(freq)
  local t = math.log(freq / FILTER_MIN_HZ) / math.log(FILTER_MAX_HZ / FILTER_MIN_HZ)
  return t * 15
end

-- ------------------------------------------
-- Haze "virtual" state / parameters
-- ------------------------------------------
local haze = {
  mix = 0.5,       -- dry/wet
  time = 1.6,      -- loop length in seconds (range 1-10)
  intensity = 0.0, -- "Haze" knob: 0 = clean, 1 = max chaos
  filter_cutoff = 12000,
  filter_res = 0.3,
  og_mode = true,  -- true = soft overdub, false = aggressive feedback
  echo_mode = false,
}

local voices = {1, 2, 3, 4}
local current_vinyl_name = "none"
local splash_active = true
local splash_metro = metro.init()

-- state for the audio-reactive fog
local input_level = 0 -- smoothed value: rises fast,
                       -- falls slowly
local raw_amp_l, raw_amp_r = 0, 0
local fog_phase = 0 -- advances each tick, for visual drift
local amp_poll_l, amp_poll_r
local browsing_files = false -- true while fileselect has
                              -- control of the screen
local clear_everything -- forward declaration (defined further below)
local resetting = false -- debounce: avoids overlapping resets
local current_screen = 1 -- 1=fog, 2=params, 3=loop/vinyl
local k1_hold_metro
local LONG_PRESS_TIME = 0.6

-- ------------------------------------------
-- softcut setup
-- ------------------------------------------
local function setup_softcut()
  for _, v in ipairs(voices) do
    softcut.enable(v, 1)
    softcut.buffer(v, (v <= 2) and 1 or 2) -- 1=L,2=R buffer
    softcut.level(v, 1.0)
    softcut.pan(v, (v % 2 == 1) and -1 or 1)
    softcut.loop_start(v, 1)
    softcut.loop_end(v, haze.time)
    softcut.loop(v, 1)
    softcut.fade_time(v, 0.1)

    softcut.rec(v, 1)
    softcut.play(v, 1)
    softcut.rec_level(v, haze.og_mode and 0.6 or 0.9)
    softcut.pre_level(v, haze.og_mode and 0.7 or 0.3)

    softcut.rate(v, 1.0)

    softcut.post_filter_dry(v, 0.15)
    softcut.post_filter_lp(v, 1.0)
    softcut.post_filter_fc(v, haze.filter_cutoff)
    softcut.post_filter_rq(v, haze.filter_res)

    softcut.level_input_cut(1, v, 1.0)
    softcut.level_input_cut(2, v, 1.0)
  end
end

-- ------------------------------------------
-- "drift" between play and record head:
-- the heart of the Haze effect. The two
-- heads drift apart slightly over time, in a
-- non-linear way, based on intensity
-- ------------------------------------------
local drift_metro

local function apply_drift()
  for _, v in ipairs(voices) do
    -- no more rate wobble (it caused an unwanted
    -- "detuning" effect): the haze character now
    -- comes only from position jumps, with
    -- gradual probability/amplitude instead of linear
    local jump_prob = (haze.intensity ^ 2) * 0.05
    if math.random() < jump_prob then
      local jump_range = haze.time * haze.intensity
      local jump = math.random() * jump_range
      softcut.position(v, jump)
    end
  end
end

local function start_drift_engine()
  drift_metro = metro.init()
  drift_metro.time = 0.1
  drift_metro.event = apply_drift
  drift_metro:start()
end

-- ------------------------------------------
-- effective level: compensates for the
-- perceived volume loss when resonance rises
-- ------------------------------------------
local function effective_level()
  local boost = 1 + haze.filter_res * 1.5
  return math.min(haze.mix * boost, 0.9) -- anti-clip ceiling
end

-- ------------------------------------------
-- "macro" parameter application
-- ------------------------------------------
local function update_mix()
  for _, v in ipairs(voices) do
    softcut.level(v, effective_level())
  end
end

local ECHO_VOICE = 6
local ECHO_OFFSET = 20 -- seconds: free buffer zone,
                        -- between the main voices (0-10s)
                        -- and the vinyl layer (60s+)

local function update_time()
  for _, v in ipairs(voices) do
    softcut.loop_end(v, haze.time)
  end
  softcut.loop_end(ECHO_VOICE, ECHO_OFFSET + haze.time / 3)
end

local function update_filter()
  for _, v in ipairs(voices) do
    softcut.post_filter_fc(v, haze.filter_cutoff)
    softcut.post_filter_rq(v, haze.filter_res)
  end
  update_mix()
end

local function update_og_echo()
  for _, v in ipairs(voices) do
    softcut.rec_level(v, haze.og_mode and 0.6 or 0.9)
    softcut.pre_level(v, haze.og_mode and 0.7 or 0.3)
  end
end

-- voice dedicated to echo mode: records the same
-- live input but with a shorter loop (1/3 of the
-- main time), creating rhythmic subdivision
-- repeats over the main signal.
-- Mutes when the toggle is off, instead of
-- stopping rec/play, to avoid clicks.
local function setup_echo_voice()
  softcut.enable(ECHO_VOICE, 1)
  softcut.buffer(ECHO_VOICE, 1)
  softcut.level(ECHO_VOICE, 0) -- muted until activated
  softcut.pan(ECHO_VOICE, 0)
  softcut.loop_start(ECHO_VOICE, ECHO_OFFSET)
  softcut.loop_end(ECHO_VOICE, ECHO_OFFSET + haze.time / 3)
  softcut.loop(ECHO_VOICE, 1)
  softcut.fade_time(ECHO_VOICE, 0.05)
  softcut.rec(ECHO_VOICE, 1)
  softcut.play(ECHO_VOICE, 1)
  softcut.rec_level(ECHO_VOICE, 0.7)
  softcut.pre_level(ECHO_VOICE, 0.4)
  softcut.rate(ECHO_VOICE, 1.0)
  softcut.level_input_cut(1, ECHO_VOICE, 1.0)
  softcut.level_input_cut(2, ECHO_VOICE, 1.0)
end

local function update_echo_mode()
  softcut.level(ECHO_VOICE, haze.echo_mode and 0.5 or 0)
end

-- ------------------------------------------
-- navigable parameter list, used with E1
-- (select) and E2 (adjust) on the params screen
-- ------------------------------------------
local selected_param = 1
local toggle_accum = 0 -- accumulator for on/off params,
                        -- so a single encoder tick doesn't
                        -- flip them back and forth

local param_list = {
  {
    label = "mix",
    get = function() return haze.mix end,
    set = function(v) haze.mix = v; update_mix() end,
    min = 0, max = 1,
  },
  {
    label = "time",
    get = function() return haze.time end,
    set = function(v) haze.time = v; update_time() end,
    min = 1.6, max = 10,
  },
  {
    label = "haze",
    get = function() return haze.intensity end,
    set = function(v) haze.intensity = v end,
    min = 0, max = 1,
  },
  {
    label = "filter cutoff",
    get = function() return freq_to_step(haze.filter_cutoff) end,
    set = function(v) haze.filter_cutoff = step_to_freq(v); update_filter() end,
    min = 0, max = 15, -- log scale, not direct hz
  },
  {
    label = "filter res",
    get = function() return haze.filter_res end,
    set = function(v) haze.filter_res = v; update_filter() end,
    min = 0, max = 1,
  },
  {
    label = "mode",
    get = function() return haze.og_mode end,
    set = function(v) haze.og_mode = v; update_og_echo() end,
    toggle = true,
  },
  {
    label = "echo",
    get = function() return haze.echo_mode end,
    set = function(v) haze.echo_mode = v; update_echo_mode() end,
    toggle = true,
  },
}

-- ------------------------------------------
-- MIDIGRID: mapping for the two Launchpads
-- ------------------------------------------
local g = grid.connect()

local function draw_row(y, value_0_15)
  for x = 1, 16 do
    g:led(x, y, (x <= value_0_15 + 1) and 15 or 0)
  end
  -- no refresh here: batching all LED writes and
  -- refreshing once at the end avoids overwhelming
  -- real serial monome grids (they choke on repeated
  -- g:refresh() calls in quick succession — MIDI-based
  -- launchpads tolerate it, real grids don't)
end

local function redraw_grid()
  draw_row(1, math.floor(haze.mix * 15))
  draw_row(2, math.floor(((haze.time - 1.6) / 8.4) * 15))
  draw_row(3, math.floor(haze.intensity * 15))
  draw_row(4, math.floor(freq_to_step(haze.filter_cutoff)))
  draw_row(5, math.floor(haze.filter_res * 15))
  draw_row(7, math.floor(params:get("vinyl_level") * 15))
  g:led(1, 8, 1) -- clear buffer: dim when idle, flashes to 15 when pressed
  g:led(2, 8, haze.og_mode and 15 or 1)
  g:led(3, 8, haze.echo_mode and 15 or 1)
  g:refresh() -- single refresh for the whole grid update
end

g.key = function(x, y, z)
  if z ~= 1 then return end -- react only on press, not release

  if y == 1 then
    haze.mix = (x - 1) / 15
    update_mix()
  elseif y == 2 then
    haze.time = 1.6 + ((x - 1) / 15) * 8.4 -- range 1.6-10s
    update_time()
  elseif y == 3 then
    haze.intensity = (x - 1) / 15
  elseif y == 4 then
    haze.filter_cutoff = step_to_freq(x - 1)
    update_filter()
  elseif y == 5 then
    haze.filter_res = (x - 1) / 15
    update_filter()
  elseif y == 7 then
    params:set("vinyl_level", (x - 1) / 15)
  elseif y == 8 and x == 1 then
    clear_everything()
  elseif y == 8 and x == 2 then
    haze.og_mode = not haze.og_mode
    update_og_echo()
  elseif y == 8 and x == 3 then
    haze.echo_mode = not haze.echo_mode
    update_echo_mode()
  end

  redraw_grid()
end

-- ------------------------------------------
-- loaded audio layer (e.g. a worn-out vinyl
-- record) - dedicated softcut voice: 5
-- ------------------------------------------
local VINYL_VOICE = 5
local VINYL_OFFSET = 60 -- seconds: buffer zone far
                         -- from the 0-10s region used by
                         -- the main voices, so they don't overlap
                         -- (without this, the sample gets
                         -- overwritten almost immediately by
                         -- the live recording)

local function setup_vinyl_voice()
  softcut.enable(VINYL_VOICE, 1)
  softcut.buffer(VINYL_VOICE, 1)
  softcut.level(VINYL_VOICE, params:get("vinyl_level") * 0.7)
  softcut.pan(VINYL_VOICE, 0)
  softcut.loop(VINYL_VOICE, 1)
  softcut.fade_time(VINYL_VOICE, 0.2)
  softcut.rec(VINYL_VOICE, 0) -- no recording, playback only
  softcut.play(VINYL_VOICE, 1)
  softcut.rate(VINYL_VOICE, 1.0)
end

local function load_vinyl_file(path)
  if path and path ~= "" then
    local ch, samples, sr = audio.file_info(path)
    local dur = samples / sr
    softcut.buffer_read_stereo(path, 0, VINYL_OFFSET, dur)
    softcut.loop_start(VINYL_VOICE, VINYL_OFFSET)
    softcut.loop_end(VINYL_VOICE, VINYL_OFFSET + dur)
    softcut.position(VINYL_VOICE, VINYL_OFFSET)
    softcut.play(VINYL_VOICE, 1)
    current_vinyl_name = path:match("^.+/(.+)$") or path
    redraw()
  end
end

-- clear everything: wipes the buffers (main voices +
-- vinyl, which shares them) and reloads the vinyl
-- right after, so it stays audible without having to
-- reselect it. Debounce + one-shot metro for the
-- flash, to avoid multiple/rapid presses overlapping
-- heavy operations
clear_everything = function()
  if resetting then return end
  resetting = true

  -- targeted cleanup of just the 0-10s region (where
  -- the main voices live), not the entire buffer:
  -- softcut.buffer_clear() also cleared several
  -- minutes of unused memory, a heavy operation that
  -- was likely the real cause of the freeze
  softcut.buffer_clear_region_channel(1, 0, 10)
  softcut.buffer_clear_region_channel(2, 0, 10)
  for _, v in ipairs(voices) do
    softcut.position(v, 0)
  end
  -- the vinyl zone (offset 60s) is no longer
  -- touched: no need to reload it afterwards anymore

  g:led(1, 8, 15)
  g:refresh()
  local flash_metro = metro.init()
  flash_metro.time = 0.15
  flash_metro.count = 1
  flash_metro.event = function()
    g:led(1, 8, 1)
    g:refresh()
    resetting = false
    metro.free(flash_metro.id)
  end
  flash_metro:start()
end

-- opens norns' native file browser pointed at
-- the whole dust/audio folder (not just sath_haze/),
-- so a sample can be chosen from any subfolder,
-- callable with K3 directly from the main screen
local function browse_vinyl_sample()
  browsing_files = true
  fileselect.enter(_path.audio, function(path)
    browsing_files = false
    if path and path ~= "cancel" then
      params:set("vinyl_sample", path)
    end
    redraw() -- restore our own screen on close
  end)
end

-- removes the current sample: stops playback
-- and zeroes the volume, without leaving live mode
local function unload_vinyl_sample()
  softcut.play(VINYL_VOICE, 0)
  params:set("vinyl_level", 0)
  current_vinyl_name = "none"
  redraw()
  redraw_grid()
end

local function add_vinyl_params()
  params:add_file("vinyl_sample", "vinyl / layer")
  params:set_action("vinyl_sample", load_vinyl_file)

  params:add_control("vinyl_level", "vinyl volume",
    controlspec.new(0, 1, 'lin', 0, 0))
  params:set_action("vinyl_level", function(v)
    softcut.level(VINYL_VOICE, v * 0.7) -- lowered ceiling
  end)
end

-- ------------------------------------------
-- (buffer clearing now lives on the grid
-- button row 8 position 1, see clear_everything)
-- ------------------------------------------
local function add_clear_trigger()
  -- left empty: the PARAMS trigger is no longer
  -- needed, the grid button does the same job more
  -- completely (it also reloads the vinyl)
end

-- ------------------------------------------
-- SCREEN
-- ------------------------------------------

function draw_splash()
  screen.clear()

  -- "SATH" large and bold
  screen.font_size(16)
  screen.font_face(1)
  screen.level(15)
  screen.move(22, 24)
  screen.text("SATH")

  -- "HaZe" on the same line, smaller
  screen.font_size(11)
  screen.font_face(1)
  screen.level(15)
  screen.move(92, 24)
  screen.text("HaZe")

  -- thin decorative line
  screen.level(5)
  screen.move(18, 36)
  screen.line(110, 36)
  screen.stroke()

  -- subtitle
  screen.font_size(8)
  screen.font_face(1)
  screen.level(12)
  screen.move(22, 48)
  screen.text("granulator + loop player")

  screen.level(9)
  screen.move(22, 58)
  screen.text("by DesioArt")

  screen.update()
end

-- draws the fog: a number of wavy bands that
-- grow with the intensity of the input signal, with
-- continuous horizontal drift for organic motion

-- particles: dots that appear and disappear,
-- with a probability tied to the signal level
local MAX_PARTICLES = 10
local particles = {}
for i = 1, MAX_PARTICLES do
  particles[i] = {active = false, x = 0, y = 0, life = 0, max_life = 0}
end

-- random but fixed offsets per band (decided once
-- at load time, not every frame): they give the
-- fog its natural stagger instead of looking like
-- overly ordered parallel lines
local band_seed = {}
for i = 1, 8 do
  band_seed[i] = {
    y_off = (math.random() - 0.5) * 16,
    phase_off = math.random() * 200,
    freq = 0.035 + math.random() * 0.05,
    wobble_mult = 0.7 + math.random() * 0.8,
  }
end

local function draw_fog(invert)
  local base_y = 32
  local max_bands = 8
  -- continuous band count instead of a hard integer cutoff:
  -- each band fades in/out smoothly based on how close it is
  -- to the current threshold, instead of popping on/off
  local band_threshold = 1 + input_level * (max_bands - 1)

  for i = 1, max_bands do
    local activation = util.clamp(band_threshold - (i - 1), 0, 1)
    if activation > 0.02 then
      local seed = band_seed[i]
      local y = base_y + seed.y_off
      local wobble = (2 + input_level * 7) * seed.wobble_mult
      local freq = seed.freq
      local phase = fog_phase * 0.6 + seed.phase_off
      local lvl = math.floor((3 + input_level * 11) * activation)
      screen.level(invert and (15 - lvl) or lvl)

      local started = false
      for x = 0, 128, 4 do
        local yy = y + math.sin((x + phase) * freq) * wobble
        if not started then
          screen.move(x, yy)
          started = true
        else
          screen.line(x, yy)
        end
      end
      screen.stroke() -- one stroke per band, not per segment
    end
  end
end

-- updates the smoothed level: rises fast when
-- signal comes in, falls slowly when it stops (the
-- fog "thins out" instead of vanishing abruptly)
local function update_input_level()
  local avg = (raw_amp_l + raw_amp_r) / 2
  -- square root instead of linear: much more
  -- sensitive to low/medium levels, which make up
  -- most of a real signal (a linear "x4" multiplier
  -- almost always stayed at just 1 band)
  local target = math.min((avg ^ 0.5) * 2.8, 1.0)
  local coeff = (target > input_level) and 0.55 or 0.06
  input_level = input_level + (target - input_level) * coeff
  fog_phase = fog_phase + 1
  if not splash_active and not browsing_files then redraw() end
end

-- updates and draws the particles: each one is born,
-- lights up, fades and disappears; while inactive it
-- has a chance to "respawn" elsewhere, higher the
-- stronger the input signal is
local function draw_particles(invert)
  for i = 1, MAX_PARTICLES do
    local p = particles[i]
    if p.active then
      p.life = p.life - 1
      if p.life <= 0 then
        p.active = false
      else
        local frac = p.life / p.max_life
        -- rises in the first half of its life, falls in the second
        local fade = (frac > 0.5) and ((1 - frac) * 2) or (frac * 2)
        local lvl = math.max(1, math.floor(fade * 14))
        screen.level(invert and (15 - lvl) or lvl)
        screen.rect(p.x, p.y, 1, 1)
        screen.fill()
      end
    else
      if math.random() < (0.015 + input_level * 0.12) then
        p.active = true
        p.x = math.random(0, 128)
        p.y = 14 + math.random(0, 40)
        p.max_life = 8 + math.random(0, 20)
        p.life = p.max_life
      end
    end
  end
end

-- SCREEN 2: parameters + clear buffer.
-- E1 selects, E2 adjusts, K3 clears the buffer.
local function draw_params_screen()
  screen.level(15)
  screen.move(6, 8)
  screen.text("params - E1/E2  K3:clear")

  for i, p in ipairs(param_list) do
    local y = 8 + i * 7
    local is_selected = (i == selected_param)
    screen.level(is_selected and 15 or 6)
    screen.move(6, y)
    screen.text(is_selected and "> " or "  ")
    screen.text(p.label)

    local val_str
    if p.label == "mode" then
      val_str = p.get() and "og" or "echo"
    elseif p.toggle then
      val_str = p.get() and "on" or "off"
    elseif p.label == "filter cutoff" then
      val_str = math.floor(haze.filter_cutoff) .. "hz"
    elseif p.label == "time" then
      val_str = string.format("%.1f", p.get()) .. "s"
    else
      val_str = string.format("%.2f", p.get())
    end
    screen.move(100, y)
    screen.text(val_str)
  end
end

-- SCREEN 3: loop/vinyl management.
-- K2 removes the sample, K3 loads it, E1 adjusts
-- the volume directly from here.
local function draw_loop_screen()
  screen.level(15)
  screen.move(6, 8)
  screen.text("loop")

  screen.level(10)
  screen.move(6, 17)
  screen.text("K3:load")
  screen.move(6, 25)
  screen.text("K2:remove")

  screen.level(12)
  screen.move(70, 17)
  screen.text("sample:")
  screen.level(15)
  screen.move(70, 25)
  local display_name = current_vinyl_name
  if #display_name > 9 then display_name = display_name:sub(1, 8) .. "." end
  screen.text(display_name)

  local vol = params:get("vinyl_level")
  screen.level(12)
  screen.move(6, 42)
  screen.text("volume (E1)  " .. string.format("%.2f", vol))

  -- level bar
  screen.level(4)
  screen.move(6, 50)
  screen.line(122, 50)
  screen.stroke()
  screen.level(15)
  screen.move(6, 50)
  screen.line(6 + vol * 116, 50)
  screen.stroke()
end

function redraw()
  if splash_active then
    draw_splash()
    return
  end

  screen.clear()

  if current_screen == 1 then
    -- negative look: white background, inverted levels
    screen.level(15)
    screen.rect(0, 0, 128, 64)
    screen.fill()
    draw_fog(true)
    draw_particles(true)
    screen.level(0)
    screen.move(4, 62)
    if current_vinyl_name ~= "none" then
      local hint_name = current_vinyl_name
      if #hint_name > 16 then hint_name = hint_name:sub(1, 15) .. "." end
      screen.text("K2/K3: " .. hint_name)
    else
      screen.text("K2/K3: sample")
    end
  elseif current_screen == 2 then
    draw_params_screen()
  else
    draw_loop_screen()
  end

  screen.update()
end

-- E1/E2: behavior differs depending on the
-- active screen
function enc(n, d)
  if current_screen == 2 then
    if n == 1 then
      selected_param = util.clamp(selected_param + d, 1, #param_list)
      toggle_accum = 0 -- start clean when switching parameter
      redraw()
    elseif n == 2 then
      local p = param_list[selected_param]
      if p.toggle then
        toggle_accum = toggle_accum + d
        if toggle_accum >= 4 then
          p.set(true)
          toggle_accum = 0
        elseif toggle_accum <= -4 then
          p.set(false)
          toggle_accum = 0
        end
      else
        local step = (p.max - p.min) / 100 * d
        local newval = util.clamp(p.get() + step, p.min, p.max)
        p.set(newval)
      end
      redraw_grid() -- keep the grid in sync
      redraw()
    end
  elseif current_screen == 3 then
    if n == 1 then
      local newval = util.clamp(params:get("vinyl_level") + d * 0.01, 0, 1)
      params:set("vinyl_level", newval)
      redraw_grid() -- keep row 7 in sync
      redraw()
    end
  end
end

-- norns hardware keys (K1/K2/K3, not the grid)
function key(n, z)
  -- any key (on press) skips the splash
  if splash_active then
    if z == 1 then
      splash_active = false
      splash_metro:stop()
      redraw()
    end
    return
  end

  if n == 1 then
    if z == 1 then
      k1_hold_metro = metro.init()
      k1_hold_metro.time = LONG_PRESS_TIME
      k1_hold_metro.count = 1
      k1_hold_metro.event = function()
        current_screen = (current_screen % 3) + 1
        redraw()
        metro.free(k1_hold_metro.id)
        k1_hold_metro = nil
      end
      k1_hold_metro:start()
    else -- release: if it hasn't fired yet, it was a
         -- short press, does nothing
      if k1_hold_metro then
        metro.free(k1_hold_metro.id)
        k1_hold_metro = nil
      end
    end
  elseif current_screen == 2 and n == 3 and z == 1 then
    clear_everything()
  elseif (current_screen == 1 or current_screen == 3) and n == 2 and z == 1 then
    unload_vinyl_sample()
  elseif (current_screen == 1 or current_screen == 3) and n == 3 and z == 1 then
    browse_vinyl_sample()
  end
end

-- ------------------------------------------
-- init
-- ------------------------------------------
function init()
  audio.level_adc(1.0)
  audio.level_cut(1.0)
  audio.level_adc_cut(1)

  setup_softcut()
  add_vinyl_params()
  add_clear_trigger()
  setup_vinyl_voice()
  setup_echo_voice()
  start_drift_engine()
  redraw_grid()

  -- the connection to the two Launchpads (through the
  -- midigrid mod) might not be ready at the exact
  -- moment init runs: sending a second update shortly
  -- after makes sure the LEDs update without having to
  -- wait for the first key press
  local grid_ready_metro = metro.init()
  grid_ready_metro.time = 0.3
  grid_ready_metro.count = 1
  grid_ready_metro.event = function()
    redraw_grid()
    metro.free(grid_ready_metro.id)
  end
  grid_ready_metro:start()

  -- splash: 3 seconds, then switches to the main screen
  splash_metro.time = 3.0
  splash_metro.count = 1
  splash_metro.event = function()
    splash_active = false
    splash_metro:stop()
    redraw()
  end
  splash_metro:start()

  -- input amplitude polls: drive the fog
  -- animation on the main screen
  amp_poll_l = poll.set("amp_in_l")
  amp_poll_l.time = 1 / 10
  amp_poll_l.callback = function(val)
    raw_amp_l = val
    update_input_level()
  end
  amp_poll_l:start()

  amp_poll_r = poll.set("amp_in_r")
  amp_poll_r.time = 1 / 10
  amp_poll_r.callback = function(val)
    raw_amp_r = val
  end
  amp_poll_r:start()

  redraw()
end

function cleanup()
  if drift_metro then metro.free(drift_metro.id) end
  if splash_metro then metro.free(splash_metro.id) end
  if amp_poll_l then amp_poll_l:stop() end
  if amp_poll_r then amp_poll_r:stop() end
end
