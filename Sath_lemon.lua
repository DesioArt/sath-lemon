-- Sath_lemon.lua
-- Performance granular sampler
-- 4 voice live recording
-- & playback Launchpad control

engine.name = "None"

local g = grid.connect()
local redraw_metro = metro.init()
local grid_redraw_metro = metro.init()

-- Parametri globali
local BUFFER_LEN = 60  -- 60 secondi totali
local VOICE_LEN = 15  -- 15 secondi per voce (60/4)

local recording = false
local rec_time = 0
local rec_voice = 1
local rec_metro = metro.init()

-- 4 Voci
local voices = {}
for i = 1, 4 do
  voices[i] = {
    playing = false,
    muted = false,
    reversed = false,
    pitch = 1.0,
    pitch_target = 1.0,  -- pitch obiettivo per glide
    pos = 0.0,
    loop_length = VOICE_LEN,
    recorded_length = VOICE_LEN,  -- lunghezza massima registrata
    level = 1.0,
    pan = (i % 2 == 0) and 0.5 or -0.5,
    buffer_start = (i - 1) * VOICE_LEN,
    buffer_end = i * VOICE_LEN,
    has_sample = false
  }
end

local selected_voice = 1
local enc_page = 1

-- Loop selection via pad hold
local held_x     = nil
local held_voice = nil
local fn_held    = false  -- tasto funzione: riga 8 pad 16

-- Splash screen
local splash_active = true
local splash_metro = metro.init()

local pitch_glide_metro = metro.init()

------------------------------------------------
-- INIT
------------------------------------------------
function init()
  audio.level_adc(1.0)
  audio.level_cut(1.0)
  audio.level_adc_cut(1)
  
  softcut.reset()
  softcut.buffer_clear()
  
  -- Voice 1 (buffer 1, prima metà)
  setup_voice(1, 1, 0, VOICE_LEN)
  
  -- Voice 2 (buffer 1, seconda metà)
  setup_voice(2, 1, VOICE_LEN, VOICE_LEN * 2)
  
  -- Voice 3 (buffer 2, prima metà)
  setup_voice(3, 2, 0, VOICE_LEN)
  
  -- Voice 4 (buffer 2, seconda metà)
  setup_voice(4, 2, VOICE_LEN, VOICE_LEN * 2)
  
  redraw_metro.time = 1/15
  redraw_metro.event = function() redraw() end
  redraw_metro:start()
  
  grid_redraw_metro.time = 1/30
  grid_redraw_metro.event = grid_redraw
  grid_redraw_metro:start()
  
  -- Metro per contare il tempo di registrazione
  rec_metro.time = 0.1  -- aggiorna ogni 100ms
  rec_metro.event = function()
    if recording then
      rec_time = rec_time + 0.1
      if rec_time >= VOICE_LEN then
        -- Auto-stop dopo 15 secondi
        stop_recording()
      end
    end
  end
  
  -- Metro per pitch glide
  pitch_glide_metro.time = 0.02  -- 50fps per glide smooth
  pitch_glide_metro.event = function()
    for i = 1, 4 do
      local v = voices[i]
      if math.abs(v.pitch - v.pitch_target) > 0.01 then
        -- Glide graduale verso il target
        local step = (v.pitch_target - v.pitch) * 0.1  -- 10% per step
        v.pitch = v.pitch + step
        
        if v.playing then
          local rate = v.reversed and -v.pitch or v.pitch
          softcut.rate(i, rate)
        end
      else
        -- Arrivato al target
        v.pitch = v.pitch_target
      end
    end
  end
  pitch_glide_metro:start()

  -- Splash screen: mostra per 3 secondi poi passa alla UI normale
  splash_metro.time = 3.0
  splash_metro.count = 1
  splash_metro.event = function()
    splash_active = false
    splash_metro:stop()
    redraw()
  end
  splash_metro:start()
  redraw()
end

function setup_voice(voice_num, buffer, start_pos, end_pos)
  local v = voices[voice_num]
  
  softcut.enable(voice_num, 1)
  softcut.buffer(voice_num, buffer)
  softcut.level(voice_num, v.level)
  softcut.pan(voice_num, v.pan)
  softcut.rate(voice_num, 1)
  softcut.loop(voice_num, 1)
  softcut.loop_start(voice_num, start_pos)
  softcut.loop_end(voice_num, end_pos)
  softcut.position(voice_num, start_pos)
  softcut.play(voice_num, 0)
  softcut.rec(voice_num, 0)
  softcut.rec_level(voice_num, 1.0)
  softcut.pre_level(voice_num, 0)
  
  -- Input routing (tutte ricevono lo stesso input per registrazione)
  if buffer == 1 then
    softcut.level_input_cut(1, voice_num, 1.0)
    softcut.level_input_cut(2, voice_num, 0.0)
  else
    softcut.level_input_cut(1, voice_num, 0.0)
    softcut.level_input_cut(2, voice_num, 1.0)
  end
end

------------------------------------------------
-- RECORDING
------------------------------------------------
function start_recording(voice)
  -- Ferma la voce se sta suonando
  if voices[voice].playing then
    stop_voice(voice)
  end
  
  rec_voice = voice
  recording = true
  rec_time = 0
  rec_metro:start()  -- avvia il contatore
  
  local v = voices[voice]
  
  -- Determina quale buffer usa questa voce
  local buffer_num = (voice == 1 or voice == 2) and 1 or 2
  
  -- METODO 1: Prova a cancellare con un loop
  for i = 0, VOICE_LEN * 100 do
    local pos = v.buffer_start + (i / 100)
    if pos >= v.buffer_start + VOICE_LEN then break end
    softcut.position(voice, pos)
  end
  
  -- METODO 2: Resetta completamente la voce
  softcut.enable(voice, 0)
  softcut.enable(voice, 1)
  
  -- Riconfigura la voce
  if buffer_num == 1 then
    softcut.buffer(voice, 1)
    softcut.level_input_cut(1, voice, 1.0)
    softcut.level_input_cut(2, voice, 0.0)
  else
    softcut.buffer(voice, 2)
    softcut.level_input_cut(1, voice, 0.0)
    softcut.level_input_cut(2, voice, 1.0)
  end
  
  softcut.level(voice, v.level)
  softcut.pan(voice, v.pan)
  softcut.loop(voice, 1)
  softcut.loop_start(voice, v.buffer_start)
  softcut.loop_end(voice, v.buffer_start + VOICE_LEN)
  
  -- Enable recording con pre_level = 0 per sovrascrivere
  softcut.rec(voice, 1)
  softcut.rec_level(voice, 1.0)
  softcut.pre_level(voice, 0.0)  -- IMPORTANTE: azzera feedback
  softcut.position(voice, v.buffer_start)
  softcut.play(voice, 1)
  
  -- Resetta loop length a tutto il campione quando inizi a registrare
  v.loop_length = VOICE_LEN
  
  v.has_sample = false
end

function stop_recording()
  if recording then
    recording = false
    rec_metro:stop()  -- ferma il contatore
    softcut.rec(rec_voice, 0)
    voices[rec_voice].has_sample = true
    
    local v = voices[rec_voice]
    
    -- Imposta il loop alla lunghezza EFFETTIVAMENTE REGISTRATA
    -- Questa diventa anche il LIMITE MASSIMO per loop_length
    v.recorded_length = math.min(rec_time, VOICE_LEN)
    v.loop_length = v.recorded_length
    v.pos = 0.0  -- parte dall'inizio
    
    print("Stop recording voice " .. rec_voice)
    print("recorded time: " .. rec_time)
    print("recorded_length: " .. v.recorded_length)
    print("loop_length: " .. v.loop_length)
    print("pos: " .. v.pos)
    print("buffer_start: " .. v.buffer_start)
    print("buffer_end: " .. v.buffer_end)
    
    -- Resetta la posizione all'inizio del buffer della voce
    softcut.position(rec_voice, v.buffer_start)
    
    -- Avvia automaticamente il playback del loop registrato
    play_voice(rec_voice)
  end
end

------------------------------------------------
-- VOICE CONTROL
------------------------------------------------
function play_voice(voice)
  if not voices[voice].has_sample then return end
  
  local v = voices[voice]
  
  -- Calcola i punti di loop usando recorded_length invece di VOICE_LEN
  local available_space = v.recorded_length - v.loop_length
  local loop_start_abs = v.buffer_start + (v.pos * available_space)
  local loop_end_abs = loop_start_abs + v.loop_length
  
  print("Play voice " .. voice)
  print("recorded_length: " .. v.recorded_length)
  print("available_space: " .. available_space)
  print("loop_start_abs: " .. loop_start_abs)
  print("loop_end_abs: " .. loop_end_abs)
  
  -- Imposta il loop prima di partire
  softcut.loop_start(voice, loop_start_abs)
  softcut.loop_end(voice, loop_end_abs)
  softcut.position(voice, loop_start_abs)
  
  -- Rate: negativo se reversed
  local rate = v.reversed and -v.pitch or v.pitch
  softcut.rate(voice, rate)
  
  voices[voice].playing = true
  softcut.play(voice, 1)
  
  -- Applica mute se necessario
  if v.muted then
    softcut.level(voice, 0)
  else
    softcut.level(voice, v.level)
  end
end

function stop_voice(voice)
  voices[voice].playing = false
  softcut.play(voice, 0)
end

function toggle_voice(voice)
  if voices[voice].playing then
    stop_voice(voice)
  else
    play_voice(voice)
  end
end

function toggle_mute(voice)
  voices[voice].muted = not voices[voice].muted
  if voices[voice].playing then
    if voices[voice].muted then
      softcut.level(voice, 0)
    else
      softcut.level(voice, voices[voice].level)
    end
  end
end

function toggle_reverse(voice)
  voices[voice].reversed = not voices[voice].reversed
  if voices[voice].playing then
    -- Aggiorna rate in tempo reale
    local rate = voices[voice].reversed and -voices[voice].pitch or voices[voice].pitch
    softcut.rate(voice, rate)
  end
end

function update_loop(voice)
  -- Aggiorna loop in tempo reale mentre suona
  if voices[voice].playing then
    local v = voices[voice]
    
    -- Calcola available_space usando la lunghezza REGISTRATA, non VOICE_LEN
    local available_space = v.recorded_length - v.loop_length
    local loop_start_abs = v.buffer_start + (v.pos * available_space)
    local loop_end_abs = loop_start_abs + v.loop_length
    
    softcut.loop_start(voice, loop_start_abs)
    softcut.loop_end(voice, loop_end_abs)
    
    -- Rate: negativo se reversed
    local rate = v.reversed and -v.pitch or v.pitch
    softcut.rate(voice, rate)
  end
end

------------------------------------------------
-- ENCODERS
------------------------------------------------
function enc(n, d)
  if splash_active then return end
  if enc_page == 1 then
    -- Page 1: Loop Control
    if n == 1 then
      selected_voice = util.clamp(selected_voice + d, 1, 4)
    elseif n == 2 then
      -- Loop length (da 0.1s fino al massimo registrato)
      local max_length = voices[selected_voice].recorded_length
      voices[selected_voice].loop_length = util.clamp(
        voices[selected_voice].loop_length + d * 0.1,
        0.1, max_length
      )
      update_loop(selected_voice)
    elseif n == 3 then
      -- Position start nel sample (0 = inizio, 1 = fine)
      voices[selected_voice].pos = util.clamp(
        voices[selected_voice].pos + d * 0.01,
        0, 1
      )
      update_loop(selected_voice)
    end
  else
    -- Page 2: Pitch & Level
    if n == 1 then
      voices[selected_voice].pitch_target = util.clamp(
        voices[selected_voice].pitch_target + d * 0.05,
        0.25, 4.0
      )
      -- Non aggiorniamo più direttamente, il glide metro lo farà
    elseif n == 2 then
      voices[selected_voice].level = util.clamp(
        voices[selected_voice].level + d * 0.05,
        0, 2.0
      )
      softcut.level(selected_voice, voices[selected_voice].level)
    elseif n == 3 then
      voices[selected_voice].pan = util.clamp(
        voices[selected_voice].pan + d * 0.05,
        -1, 1
      )
      softcut.pan(selected_voice, voices[selected_voice].pan)
    end
  end
  redraw()
end

------------------------------------------------
-- KEYS
------------------------------------------------
function key(n, z)
  -- Qualsiasi tasto salta la splash
  if splash_active and z == 1 then
    splash_active = false
    splash_metro:stop()
    redraw()
    return
  end
  if n == 1 and z == 1 then
    enc_page = (enc_page % 2) + 1
  elseif n == 2 and z == 1 then
    -- Record selected voice
    if recording then
      stop_recording()
    else
      start_recording(selected_voice)
    end
  elseif n == 3 and z == 1 then
    -- Play/Stop selected voice
    toggle_voice(selected_voice)
  end
  redraw()
end

------------------------------------------------
-- GRID
------------------------------------------------
function g.key(x, y, z)
  if z == 1 then
    if y <= 4 then
      if fn_held then
        -- Tasto funzione: imposta loop minimo (1 pad) sulla posizione premuta
        local v          = voices[y]
        selected_voice   = y
        local new_pos_sc = ((x - 1) / 16) * v.recorded_length
        local new_length = util.clamp((1 / 16) * v.recorded_length, 0.1, v.recorded_length)
        v.pos         = util.clamp(new_pos_sc / math.max(v.recorded_length - new_length, 0.001), 0, 1)
        v.loop_length = new_length
        update_loop(y)
        redraw()
      elseif held_x == nil then
        -- Primo pad: salva posizione
        held_x     = x
        held_voice = y
      else
        -- Secondo pad sulla stessa riga: seleziona porzione loop
        if y == held_voice then
          local v          = voices[held_voice]
          local x1         = math.min(held_x, x)
          local x2         = math.max(held_x, x)
          local new_pos_sc = ((x1 - 1) / 16) * v.recorded_length
          local new_length = util.clamp(((x2 - x1 + 1) / 16) * v.recorded_length, 0.1, v.recorded_length)
          v.pos         = util.clamp(new_pos_sc / math.max(v.recorded_length - new_length, 0.001), 0, 1)
          v.loop_length = new_length
          update_loop(held_voice)
          redraw()
        end
      end
    elseif y == 5 then
      if x <= 4 then
        selected_voice = x
        redraw()
      end
    elseif y == 6 then
      if x <= 4 then
        toggle_voice(x)
        redraw()
      elseif x == 8 then
        local any_playing = false
        for i = 1, 4 do
          if voices[i].playing then any_playing = true; break end
        end
        if any_playing then
          for i = 1, 4 do
            if voices[i].playing then stop_voice(i) end
          end
        else
          for i = 1, 4 do
            if voices[i].has_sample and not voices[i].playing then
              play_voice(i)
            end
          end
        end
        redraw()
      elseif x >= 9 and x <= 12 then
        toggle_reverse(x - 8)
        redraw()
      elseif x >= 13 and x <= 16 then
        local speed_presets = {0.5, 1.0, 1.5, 2.0}
        voices[selected_voice].pitch_target = speed_presets[x - 12]
        redraw()
      end
    elseif y == 7 then
      if x <= 4 then
        toggle_mute(x)
        redraw()
      end
    elseif y == 8 then
      if x == 16 then
        fn_held = true
      end
    end
  else
    -- Release
    if y <= 4 then
      if held_x == x and held_voice == y then
        -- Click singolo: seleziona voce
        selected_voice = y
        redraw()
      end
      held_x     = nil
      held_voice = nil
    elseif y == 8 and x == 16 then
      fn_held = false
    end
  end
end

function grid_redraw()
  g:all(0)
  
  -- Righe 1-4: Visualizzazione loop per ogni voce
  for voice = 1, 4 do
    local v = voices[voice]
    
    -- Calcola quante caselle occupare (loop length rispetto a recorded_length)
    local loop_ratio = v.loop_length / v.recorded_length
    local num_leds = math.max(1, math.floor(loop_ratio * 16))
    
    -- Calcola da dove partire (start position)
    local available_space = v.recorded_length - v.loop_length
    local start_offset = 0
    if available_space > 0 then
      start_offset = math.floor((v.pos * available_space / v.recorded_length) * 16)
    end
    
    -- Accendi i LED del loop
    for x = 1, 16 do
      local led_brightness = 0
      
      if x > start_offset and x <= start_offset + num_leds then
        -- Dentro il loop
        if v.playing then
          led_brightness = 15  -- Playing = massima luminosità
        elseif v.has_sample then
          led_brightness = 8   -- Has sample = media luminosità
        else
          led_brightness = 2   -- No sample = bassa luminosità
        end
        
        -- Voce selezionata = più luminosa
        if voice == selected_voice and led_brightness > 0 then
          led_brightness = 15
        end
      else
        -- Fuori dal loop = spento o debolissimo
        if voice == selected_voice then
          led_brightness = 1  -- Voce selezionata mostra outline
        end
      end
      
      g:led(x, voice, led_brightness)
    end
  end
  
  -- Riga 5: Voice selection (solo primi 4 LED)
  for i = 1, 4 do
    g:led(i, 5, selected_voice == i and 15 or 3)
  end
  
  -- Riga 6: Play/Stop (1-4) + Play/Stop All (8) + Reverse (9-12) + Speed (13-16)
  for i = 1, 4 do
    -- Play/Stop buttons
    local play_brightness = 0
    if voices[i].playing then
      play_brightness = 15  -- Playing = acceso
    elseif voices[i].has_sample then
      play_brightness = 5   -- Has sample = medio
    else
      play_brightness = 1   -- No sample = quasi spento
    end
    g:led(i, 6, play_brightness)
    
    -- Reverse buttons (colonne 9-12)
    local reverse_brightness = 0
    if voices[i].reversed then
      reverse_brightness = 15  -- Reversed = acceso
    elseif voices[i].has_sample then
      reverse_brightness = 3   -- Not reversed ma ha sample
    else
      reverse_brightness = 1   -- No sample
    end
    g:led(i + 8, 6, reverse_brightness)
  end
  
  -- Play/Stop All toggle button (colonna 8)
  local any_playing = false
  local any_with_sample = false
  for i = 1, 4 do
    if voices[i].playing then any_playing = true end
    if voices[i].has_sample then any_with_sample = true end
  end
  
  local toggle_brightness = 3
  if any_playing then
    toggle_brightness = 15  -- Qualcosa suona = stop mode (rosso/acceso)
  elseif any_with_sample then
    toggle_brightness = 10  -- Nulla suona ma ci sono sample = play mode (verde/medio)
  end
  g:led(8, 6, toggle_brightness)
  
  -- Speed presets (colonne 13-16) per voce selezionata
  local speed_presets = {0.5, 1.0, 1.5, 2.0}
  for i = 1, 4 do
    local brightness = 3
    -- Evidenzia il preset attivo
    if math.abs(voices[selected_voice].pitch - speed_presets[i]) < 0.1 then
      brightness = 15
    end
    g:led(i + 12, 6, brightness)
  end
  
  -- Riga 7: Mute buttons (primi 4 LED)
  for i = 1, 4 do
    local brightness = 0
    if voices[i].muted then
      brightness = 15  -- Muted = acceso (rosso idealmente)
    elseif voices[i].has_sample then
      brightness = 3   -- Not muted ma ha sample = debole
    else
      brightness = 1   -- No sample = quasi spento
    end
    g:led(i, 7, brightness)
  end
  
  -- Riga 8 (ultima): Recording progress bar O Loop playback indicator
  if recording then
    -- Durante registrazione: barra progresso
    local progress = util.clamp(rec_time / VOICE_LEN, 0, 1)
    local lit_leds = math.floor(progress * 16)
    
    for x = 1, 16 do
      if x <= lit_leds then
        g:led(x, 8, 15)
      elseif x == lit_leds + 1 then
        g:led(x, 8, 8)
      else
        g:led(x, 8, 1)
      end
    end
  else
    -- Quando non registra: mostra i loop in play
    for voice = 1, 4 do
      if voices[voice].playing and not voices[voice].muted then
        local v = voices[voice]
        
        -- Calcola dove si trova nel loop usando recorded_length
        local available_space = v.recorded_length - v.loop_length
        local loop_ratio = v.loop_length / v.recorded_length
        local num_leds = math.max(1, math.floor(loop_ratio * 16))
        local start_offset = math.floor((v.pos * available_space / v.recorded_length) * 16)
        
        -- Accendi i LED corrispondenti al loop di questa voce
        for x = 1, 16 do
          if x > start_offset and x <= start_offset + num_leds then
            -- Dentro il loop - sovrapponi con luminosità variabile per voce
            local current_brightness = 3 + (voice * 3)  -- V1=6, V2=9, V3=12, V4=15
            g:led(x, 8, current_brightness)
          end
        end
      end
    end
  end

  -- Pad funzione: riga 8, pad 16 (loop minimo)
  g:led(16, 8, fn_held and 15 or 3)

  g:refresh()
end

------------------------------------------------
-- SCREEN
------------------------------------------------

function draw_splash()
  screen.clear()

  -- "SATH" grande e bold (font size 16)
  screen.font_size(16)
  screen.font_face(1)
  screen.level(15)
  screen.move(22, 22)
  screen.text("SATH")

  -- "LEM" prima parte di LEMON
  screen.font_size(10)
  screen.font_face(1)
  screen.level(15)
  screen.move(22, 38)
  screen.text("LEM")

  -- Calcola dove finisce "LEM" per posizionare il limone
  -- "LEM" a font 10 è circa 21px, partiamo da x=22 → la O inizia circa a x=44
  local ox = 51   -- centro X della O-limone
  local oy = 33   -- centro Y della O-limone
  local rw = 6    -- raggio orizzontale (più largo = limone)
  local rh = 5    -- raggio verticale

  -- Disegna la O come ellisse usando arc e linee
  -- Norns screen API: usiamo move/curve con approssimazione bezier
  -- Ellisse con 4 archi bezier
  local kx = rw * 0.5523  -- costante bezier per ellisse
  local ky = rh * 0.5523

  screen.level(15)
  screen.line_width(1)

  -- Arco superiore sinistro
  screen.move(ox - rw, oy)
  screen.curve(ox - rw, oy - ky,  ox - kx, oy - rh,  ox, oy - rh)
  -- Arco superiore destro
  screen.curve(ox + kx, oy - rh,  ox + rw, oy - ky,  ox + rw, oy)
  -- Arco inferiore destro
  screen.curve(ox + rw, oy + ky,  ox + kx, oy + rh,  ox, oy + rh)
  -- Arco inferiore sinistro
  screen.curve(ox - kx, oy + rh,  ox - rw, oy + ky,  ox - rw, oy)
  screen.stroke()

  -- Puntino superiore destro del limone (sperone)
  screen.move(ox + rw - 1, oy - 2)
  screen.line(ox + rw + 2, oy - 4)
  screen.stroke()

  -- Puntino inferiore sinistro del limone (sperone opposto)
  screen.move(ox - rw + 1, oy + 2)
  screen.line(ox - rw - 2, oy + 4)
  screen.stroke()

  -- "N" dopo il limone
  screen.font_size(10)
  screen.font_face(1)
  screen.level(15)
  screen.move(ox + rw + 4, 38)
  screen.text("N")

  -- Linea decorativa sottile sotto il titolo
  screen.level(5)
  screen.move(18, 42)
  screen.line(110, 42)
  screen.stroke()

  -- Sottotitolo piccolo
  screen.font_size(8)
  screen.font_face(1)
  screen.level(8)
  screen.move(22, 52)
  screen.text("4-voice looper")

  screen.level(4)
  screen.move(22, 61)
  screen.text("by DesioArt")

  screen.update()
end

function redraw()
  if splash_active then
    draw_splash()
    return
  end

  screen.clear()
  screen.level(15)
  
  -- Header
  screen.move(10, 10)
  local page_names = {"LOOP", "PITCH"}
  screen.text("sath lemon [" .. page_names[enc_page] .. "]")
  
  -- Voice indicator
  screen.move(112, 10)
  screen.text("V" .. selected_voice)
  
  local v = voices[selected_voice]
  
  if enc_page == 1 then
    screen.move(10, 25)
    screen.text("voice: " .. selected_voice)
    
    screen.move(10, 35)
    screen.text("loop length: " .. string.format("%.1f", v.loop_length) .. "s")
    
    screen.move(10, 45)
    screen.text("start pos: " .. string.format("%.2f", v.pos))
    
    screen.move(10, 55)
    if v.has_sample then
      screen.text(v.playing and "PLAYING" or "READY")
    else
      screen.text("NO SAMPLE")
    end
    
  else
    screen.move(10, 25)
    screen.text("pitch: " .. string.format("%.2f", v.pitch))
    
    screen.move(10, 35)
    screen.text("level: " .. string.format("%.2f", v.level))
    
    screen.move(10, 45)
    screen.text("pan: " .. string.format("%.2f", v.pan))
  end
  
  -- Recording indicator
  if recording then
    screen.move(10, 60)
    screen.level(15)
    screen.text(">> REC V" .. rec_voice .. " <<")
  end
  
  -- Voice status bar
  screen.move(10, 64)
  screen.level(8)
  for i = 1, 4 do
    local status = "."
    if voices[i].playing then
      status = "▶"
    elseif voices[i].has_sample then
      status = "■"
    end
    screen.text(status .. " ")
  end
  
  screen.update()
end