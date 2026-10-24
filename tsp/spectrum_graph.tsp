-- spectrum_graph.tsp -- spectrum display built on the instrument's own graph object
--
-- The graph draws a whole trace from a reading buffer in one repaint, so a frame
-- is a buffer refill; per-point line objects or setpixel flood the display queue.
--
-- The graph's X axis is hardwired to time, so each bin's frequency is written into
-- its reading's timestamp, divided by fftsa.sg_fscale, and the time axis reads as
-- frequency: at 1000 a 50 kHz span is 0..50 label-seconds and the firmware's labels
-- read as kHz, with an "s" suffix that cannot be switched off. Our own tick labels
-- in real units sit below the plot (fftsa.sg_axis_update). The scale is the largest
-- decade that keeps the span under 59 label-seconds, above which the firmware's
-- axis rolls into base-60 MM:SS.
--
-- Y is dBV computed in Lua, carried in a UNIT_VOLT buffer on a fixed linear axis.
--
-- Every object and buffer here is deleted and its handle cleared by
-- fftsa.sg_destroy() before anything is created again; creating over a live handle
-- drops the only reference to the old object, which stays alive until a power cycle.

fftsa = fftsa or {}   -- the single global this app exposes

fftsa.sg_nbins   = 256
fftsa.sg_npeak   = 6       -- number of peaks reported (shown in a 2x3 grid)

-- Firmware handles, initialised only on the first load: opening the App again
-- re-runs this body and `fftsa = fftsa or {}` keeps the table, so nil-ing a live
-- handle here would strand the previous launch's objects. fftsa.sg_destroy()
-- reclaims them on the next start.
if fftsa.sg_handles_inited == nil then
  fftsa.sg_buf   = nil     -- WRITABLE_FULL buffer holding the spectrum
  fftsa.sg_scr   = nil     -- custom screen
  fftsa.sg_graph = nil     -- OBJ_GRAPH object
  fftsa.sg_pk_f  = nil     -- per-peak frequency text (own field, fixed x)
  fftsa.sg_pk_v  = nil     -- per-peak voltage text  (own field, fixed x)
  fftsa.sg_pk_d  = nil     -- per-peak dB text       (own field, fixed x)
  fftsa.sg_xunit = nil     -- axis unit legend
  fftsa.sg_stat  = nil
  fftsa.sg_xlab  = nil     -- our own X tick labels, in Hz or kHz (table)
  fftsa.sg_handles_inited = true
end

-- Deletions the firmware refused (fftsa.del_obj), kept across a reload: non-zero
-- means objects may be stranded.
fftsa.delfails = fftsa.delfails or 0
-- Visible frequency window (Hz): fftsa.sg_update() writes only the bins inside it
-- and fftsa.sg_pin_x() pins the axis to it. fftsa.apply() narrows the defaults.
fftsa.sg_flo_hz  = 0
fftsa.sg_fhi_hz  = 1e9
fftsa.sg_fscale  = 1000    -- Hz per label-second; fftsa.sg_pick_fscale() steps it by decades

-- Geometry on the 800x480 panel, in object coordinates, which start below the
-- 49-pixel title bar: a child at y=350 lands on panel row 399.
fftsa.sg_gx      = 8
fftsa.sg_gy      = 0
fftsa.sg_gw      = 784
fftsa.sg_gh      = 292

-- -120 dBV is the floor because the DMM7510's front end sits 12 to 14 dB below the
-- DMM6500's, and at -100 its noise floor was off the bottom of the plot.
fftsa.sg_dbmin   = -120
fftsa.sg_dbmax   = 20
fftsa.sg_vfloor  = 1e-9

-- Plot-box calibration: the firmware cannot be asked where it drew the box, so the
-- X-axis end pixels come from hardware captures with the axis pinned
-- (display.XSCALE_OFF). Revisit if a firmware update moves the plot box.
fftsa.sg_px0     = 105     -- x of the X axis minimum
fftsa.sg_px1     = 785     -- x of the X axis maximum

-- Our X ticks sit below the graph rectangle: an object inside it is painted over by
-- the per-frame repaint and never appears. Derived, so moving the graph moves them
-- with it. Only X gets our labels; the firmware's Y numbers are the dB values
-- themselves, with a "V" suffix.
fftsa.sg_xlab_y  = fftsa.sg_gy + fftsa.sg_gh + 18
-- Labels are JUST_LEFT, so a tick is nudged left by about half a label's width to
-- sit centred on its gridline; the end ticks are pulled in to stay on the panel.
fftsa.sg_xlab_hw = 26
fftsa.sg_nxlab   = 5       -- X ticks, endpoints included
fftsa.sg_axc     = 12632256    -- axis label colour
-- fftsa.sg_fhi_hz starts at a sentinel meaning "every bin". A span wider than this
-- is not a plottable axis, so the pin and the labels stay blank until fftsa.apply()
-- narrows it.
fftsa.sg_fmax_real = 1e6

-- Peak table: 6 rows as two columns of three. freq/volt/dB are separate objects at
-- fixed x, so the volt and dB columns do not jitter as the proportional-font
-- frequency text changes width. The bottom-right is left free for the Options button.
fftsa.sg_pky     = 350     -- first peak row baseline
fftsa.sg_pkdy    = 20      -- row pitch
fftsa.sg_pk_colx_f = {8,   360}   -- frequency field x, per column
fftsa.sg_pk_colx_v = {118, 470}   -- voltage field x,   per column
fftsa.sg_pk_colx_d = {200, 552}   -- dB field x,        per column
fftsa.sg_pk_cf   = 14745568  -- freq colour (pale green)
fftsa.sg_pk_cv   = 13166335  -- volt colour (pale blue)
fftsa.sg_pk_cd   = 16769184  -- dB colour   (pale amber)
fftsa.sg_xunit_x = 8
fftsa.sg_xunit_y = 410       -- X-axis legend, below the peak rows
fftsa.sg_xunit_c = 9474192   -- grey 909090

-- Delete without hiding a refusal: a bare pcall conflates a dead handle (harmless,
-- a child that went with its screen) with the firmware refusing (the object is
-- alive and unreachable). Callers clear the handle either way; a refusal is
-- counted in fftsa.delfails and recorded in fftsa.lasterr. The app module uses
-- these too.
function fftsa.del_obj(h)
  if h == nil then return true end
  local ok, err = pcall(function() display.delete(h) end)
  if not ok then
    fftsa.delfails = (fftsa.delfails or 0) + 1
    fftsa.lasterr = "display.delete refused: " .. tostring(err)
  end
  return ok
end

function fftsa.del_buf(b)
  if b == nil then return true end
  local ok, err = pcall(function() buffer.delete(b) end)
  if not ok then
    fftsa.delfails = (fftsa.delfails or 0) + 1
    fftsa.lasterr = "buffer.delete refused: " .. tostring(err)
  end
  return ok
end

-- Pin the X axis to the window: auto-range rounds outward to tidy tick values, so
-- the pixel of a given frequency would be unknowable and our labels misplaced.
function fftsa.sg_pin_x()
  if fftsa.sg_graph == nil then return false end
  local lo, hi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if hi > fftsa.sg_fmax_real or hi <= lo then return false end
  local s = fftsa.sg_fscale
  pcall(function()
    display.graph.scalex(fftsa.sg_graph, display.XSCALE_OFF, display.AXIS_NORMAL,
                         lo / s, hi / s)
  end)
  return true
end

-- The span sets the precision: two adjacent ticks reading the same number are
-- worse than none. Each tick carries its own unit, since the firmware's row says "s".
function fftsa.sg_flabel(f, span)
  if span >= 1000 then return string.format("%.1f kHz", f / 1000) end
  return string.format("%.0f Hz", f)
end

-- Refresh the tick text only when the span changes. The tick pixels are fixed (the
-- axis is pinned), so a zoom changes the numbers and nothing else.
function fftsa.sg_axis_update(force)
  if fftsa.sg_xlab == nil then return false end
  local lo, hi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if not force and fftsa.sg_lab_lo == lo and fftsa.sg_lab_hi == hi then return false end
  fftsa.sg_lab_lo, fftsa.sg_lab_hi = lo, hi
  local n = fftsa.sg_nxlab
  local blank = (hi > fftsa.sg_fmax_real or hi <= lo)
  fftsa.sg_xlab_txt = {}
  for i = 1, n do
    local txt = ""
    if not blank then
      txt = fftsa.sg_flabel(lo + (hi - lo) * (i - 1) / (n - 1), hi - lo)
    end
    fftsa.sg_xlab_txt[i] = txt
    local h = fftsa.sg_xlab[i]
    pcall(function() display.settext(h, txt) end)
  end
  return true
end

-- Largest decade that keeps the span under 59 label-seconds; above that the
-- firmware's time axis rolls into base-60 MM:SS.
function fftsa.sg_pick_fscale(fhi_hz)
  local s = 1000                      -- the label then reads directly as kHz
  if fhi_hz == nil or fhi_hz <= 0 then return s end
  while fhi_hz / s >= 59 do s = s * 10 end
  return s
end

function fftsa.sg_xunit_text()
  local s = fftsa.sg_fscale
  local t = "X: kHz   Y: dBV"
  if s ~= 1000 then
    t = string.format("X: kHz   Y: dBV   (graph x%g)", s / 1000)
  end
  -- Start 1999 / Stop 2000 is a legal pair and one plotted point at 195.3 Hz bins:
  -- the trace is a dot, five peak rows read ---, and nothing else says why.
  local b = fftsa.binhz
  if b ~= nil and b > 0 then
    local k0, k1 = fftsa.sg_window_bins(fftsa.sg_nbins, b)
    local n = k1 - k0 + 1
    if n < 3 then
      local plural = "s"
      if n == 1 then plural = "" end
      t = t .. string.format("   %d bin%s in this span of %.0f Hz", n, plural, b)
    end
  end
  return t
end

-- WRITABLE_FULL carries value, extra and timestamp per point: UNIT_VOLT holding dB
-- numbers, extra UNIT_HERTZ. The caller must have detached the graph first
-- (fftsa.sg_destroy() does).
function fftsa.sg_make_buffer(nbins, capacity)
  fftsa.sg_nbins = nbins
  if fftsa.sg_buf ~= nil then
    fftsa.del_buf(fftsa.sg_buf)
    fftsa.sg_buf = nil
  end
  fftsa.sg_buf = buffer.make(math.max(nbins, capacity or nbins) + 16,
                            buffer.STYLE_WRITABLE_FULL)
  -- Not buffer.UNIT_DECIBEL: it panics the instrument during build.
  buffer.write.format(fftsa.sg_buf, buffer.UNIT_VOLT,  buffer.DIGITS_4_5,
                              buffer.UNIT_HERTZ, buffer.DIGITS_6_5)
  -- An empty buffer binds no trace, and later writes never draw. Seed here so
  -- the initial graph binding has data to attach.
  for k = 1, nbins do
    fftsa.sg_write_point(fftsa.sg_buf, fftsa.sg_dbmin, (k - 1) * 1.0)
  end
  return fftsa.sg_buf
end

-- Split a scaled frequency into the (seconds, fraction) pair buffer.write.reading
-- takes. The fraction must be 0 to 0.9999999; past that the firmware refuses the
-- write with event 1131, which is a modal dialog on this instrument -- and one
-- dialog per frame at 10 fps is as impossible to exit as one per point.
--
-- math.floor() leaves exactly that when the scaled frequency sits a rounding error
-- below an integer. That is rare, not normal: binhz/sg_fscale has to land within an
-- ulp below a simple rational, not merely be inexact. Swept over every reachable
-- configuration the naive floor refuses at most 3 points of 256 in one frame, and
-- nothing at all in 514691 of 515052 -- worst at a measured 199999.99999999997 S/s,
-- where 390.62499999999994 Hz bins put bins 64, 128 and 192 a hair under 25, 50 and
-- 75 label-seconds. So this is cheap insurance, and the bench symptom it was written
-- for is still unexplained: tools/test_tsp.lua carries the query that settles it.
function fftsa.sg_split_t(t)
  local w = math.floor(t)
  local fr = t - w
  if fr >= 0.9999999 then return w + 1, 0 end
  return w, fr
end

-- One point: value dB, extra Hz, timestamp the scaled frequency (the seconds trick).
function fftsa.sg_write_point(buf, db, f)
  local w, fr = fftsa.sg_split_t(f / fftsa.sg_fscale)
  buffer.write.reading(buf, db, f, w, fr)
end

-- Our own X tick labels in real frequency units. The graph's cannot be relabelled
-- or switched off (display.setabbrv() applies to option fields, not axes). Text is
-- filled in by fftsa.sg_axis_update() once a real span exists.
function fftsa.sg_axis_build(create, small)
  fftsa.sg_xlab = {}
  local nx, hw = fftsa.sg_nxlab, fftsa.sg_xlab_hw
  for i = 1, nx do
    local x = fftsa.sg_px0 + (fftsa.sg_px1 - fftsa.sg_px0) * (i - 1) / (nx - 1) - hw
    if i == 1  then x = x + hw end            -- first: start at the axis
    if i == nx then x = x - hw end            -- last: keep it fully on screen
    if x < 2 then x = 2 end
    fftsa.sg_xlab[i] = create(fftsa.sg_scr, display.OBJ_TEXT, math.floor(x),
                              fftsa.sg_xlab_y, "", fftsa.sg_axc, small, display.JUST_LEFT)
  end
  fftsa.sg_lab_lo, fftsa.sg_lab_hi = nil, nil   -- force the first text update
end

-- Build the screen once, at launch: graph, tick labels, peak table, legend. The
-- frame loop only refills the buffer and updates text.
function fftsa.sg_build(title, nbins, capacity)
  fftsa.sg_destroy()

  fftsa.sg_make_buffer(nbins, capacity)
  local create = display.create
  local small  = display.FONT_SMALL
  fftsa.sg_scr = create(display.ROOT, display.OBJ_SCREEN, title)
  -- create() returns nil when the pool is exhausted, posting one event and not
  -- raising, so without this every child is built against a nil parent and
  -- fftsa.start()'s pcall reports success.
  if fftsa.sg_scr == nil then
    error("display object pool exhausted building the spectrum screen -- power "
          .. "cycle the instrument.", 0)
  end
  -- Creating a screen makes it active, so the cover goes back in front before the
  -- first child: otherwise the operator watches the screen assemble itself.
  fftsa.loading_front()

  fftsa.sg_graph = create(fftsa.sg_scr, display.OBJ_GRAPH, fftsa.sg_gx, fftsa.sg_gy, fftsa.sg_gw, fftsa.sg_gh)
  -- X is ELEMENT_TIME (our scaled-frequency timestamps); Y is ELEMENT_DATA (dB).
  display.graph.add(fftsa.sg_graph, fftsa.sg_buf, display.ELEMENT_DATA, fftsa.sg_buf, display.ELEMENT_TIME)
  display.graph.drawstyle(fftsa.sg_graph, display.STYLE_LINE)
  pcall(function()
    display.graph.scaley(fftsa.sg_graph, display.YSCALE_OFF, display.AXIS_NORMAL,
                         fftsa.sg_dbmin, fftsa.sg_dbmax)
  end)
  fftsa.sg_pin_x()
  fftsa.sg_axis_build(create, small)
  fftsa.sg_axis_update(true)

  fftsa.sg_pk_f, fftsa.sg_pk_v, fftsa.sg_pk_d = {}, {}, {}
  for p = 1, fftsa.sg_npeak do
    local col, row = 1, p - 1
    if p > 3 then col = 2; row = p - 4 end
    local y = fftsa.sg_pky + row * fftsa.sg_pkdy
    if y > 418 then y = 418 end
    fftsa.sg_pk_f[p] = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_pk_colx_f[col], y,
                        string.format("%d  ---", p), fftsa.sg_pk_cf, small, display.JUST_LEFT)
    fftsa.sg_pk_v[p] = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_pk_colx_v[col], y, "", fftsa.sg_pk_cv, small, display.JUST_LEFT)
    fftsa.sg_pk_d[p] = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_pk_colx_d[col], y, "", fftsa.sg_pk_cd, small, display.JUST_LEFT)
  end

  fftsa.sg_xunit = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_xunit_x, fftsa.sg_xunit_y,
                          fftsa.sg_xunit_text(), fftsa.sg_xunit_c, small, display.JUST_LEFT)

  fftsa.sg_stat = nil     -- no on-screen status object
  return fftsa.sg_scr
end

-- Tear down in dependency order: detach the trace, drop the screen and its
-- children, then free the buffer the trace referenced. Nils every handle.
function fftsa.sg_destroy()
  if fftsa.sg_graph ~= nil then
    pcall(function() display.graph.removeall(fftsa.sg_graph) end)
  end
  if fftsa.sg_scr ~= nil then
    pcall(function() display.changescreen(display.SCREEN_HOME) end)
    fftsa.del_obj(fftsa.sg_scr)
  end
  fftsa.sg_scr, fftsa.sg_graph, fftsa.sg_pk_f, fftsa.sg_pk_v, fftsa.sg_pk_d,
    fftsa.sg_xunit, fftsa.sg_stat = nil, nil, nil, nil, nil, nil, nil
  fftsa.sg_xlab = nil
  fftsa.sg_lab_lo, fftsa.sg_lab_hi, fftsa.sg_xlab_txt = nil, nil, nil
  if fftsa.sg_buf ~= nil then
    fftsa.del_buf(fftsa.sg_buf)
  end
  fftsa.sg_buf = nil
  collectgarbage()
end

-- Bin index range covering the visible window, clamped into 1..nbins. Shared by
-- the plot and the peak search, so the table describes what is on screen.
function fftsa.sg_window_bins(nbins, binhz)
  if binhz == nil or binhz <= 0 then return 1, nbins end
  local floor, ceil = math.floor, math.ceil
  -- ceil, not floor, for the low edge: floor() maps every start below one bin
  -- width (195 Hz at 100 kS/s) back to bin 1, the DC bin.
  local kmin = ceil(fftsa.sg_flo_hz / binhz) + 1
  local kmax = floor(fftsa.sg_fhi_hz / binhz) + 1
  if kmin < 1 then kmin = 1 end
  if kmin > nbins then kmin = nbins end
  if kmax > nbins then kmax = nbins end
  if kmax < kmin then kmax = kmin end
  return kmin, kmax
end

-- Refill the trace from fftsa.fft_pwr in place, with the trace attached: a detach
-- and re-add (removeall+add) repaints the whole widget, an attached refill does
-- not. The display task shares this core with the interpreter and runs only while
-- Lua is blocked, so the delay at the end is what gets the refill painted; too
-- short and the firmware posts 1706, "Message dropped from display queue".
function fftsa.sg_update(nbins, binhz)
  if binhz == nil or binhz <= 0 then return end   -- no usable frequency scale yet
  local g     = fftsa.sg_graph
  local buf   = fftsa.sg_buf
  local pwr   = fftsa.fft_pwr
  local wr    = buffer.write.reading
  local log10 = math.log10
  local vfl   = fftsa.sg_vfloor * fftsa.sg_vfloor   -- squared: the bins are power
  local dbmin = fftsa.sg_dbmin
  local dbmax = fftsa.sg_dbmax
  local fscl  = fftsa.sg_fscale
  local split = fftsa.sg_split_t
  local kmin, kmax = fftsa.sg_window_bins(nbins, binhz)
  buf.clear()
  for k = kmin, kmax do
    local v = pwr[k]
    local db
    -- nil (sparse power array) and anything at or below the floor plot at the
    -- floor, so log10 is never handed a zero. The range tests are positives because
    -- every comparison with a NaN is false, so `db < dbmin` would pass one through
    -- to buffer.write.reading and a refused parameter is event 1131 again. No
    -- reachable NaN was found, so that half is hardening.
    if v == nil or v <= vfl then
      db = dbmin
    else
      db = 10 * log10(v)
      if not (db > dbmin) then db = dbmin
      elseif not (db < dbmax) then db = dbmax end
    end
    local f = (k - 1) * binhz
    -- Scaled frequency into the seconds field, split so the fraction cannot reach
    -- the 0.9999999 the firmware refuses with event 1131.
    local w, fr = split(f / fscl)
    wr(buf, db, f, w, fr)
  end
  delay(fftsa.sg_yield)                      -- lets the display task paint the refill
end

-- The one place a zoom touches: the tick pixels are fixed and only the numbers move.
function fftsa.sg_set_xrange(flo_hz, fhi_hz)
  fftsa.sg_flo_hz = flo_hz
  fftsa.sg_fhi_hz = fhi_hz
  fftsa.sg_fscale = fftsa.sg_pick_fscale(fhi_hz)
  if fftsa.sg_xunit ~= nil then
    pcall(function() display.settext(fftsa.sg_xunit, fftsa.sg_xunit_text()) end)
  end
  fftsa.sg_pin_x()
  fftsa.sg_axis_update()
end

-- Re-bind the trace; removeall() first, or add() stacks a duplicate trace.
function fftsa.sg_rebind()
  pcall(function() display.graph.removeall(fftsa.sg_graph) end)
  pcall(function() display.graph.add(fftsa.sg_graph, fftsa.sg_buf, display.ELEMENT_DATA,
                                     fftsa.sg_buf, display.ELEMENT_TIME) end)
  pcall(function() display.graph.drawstyle(fftsa.sg_graph, display.STYLE_LINE) end)
  pcall(function()
    display.graph.scaley(fftsa.sg_graph, display.YSCALE_OFF, display.AXIS_NORMAL,
                         fftsa.sg_dbmin, fftsa.sg_dbmax)
  end)
  fftsa.sg_pin_x()
end

-- Detach and re-add the trace. Not called by the app; tools/test_tsp.lua exercises it.
function fftsa.sg_bind_min()
  pcall(function() display.graph.removeall(fftsa.sg_graph) end)
  pcall(function() display.graph.add(fftsa.sg_graph, fftsa.sg_buf, display.ELEMENT_DATA,
                                     fftsa.sg_buf, display.ELEMENT_TIME) end)
end

-- Seconds the frame stays blocked after the refill so the display task can paint
-- it. 1706 events mean it is too short.
fftsa.sg_yield = 0.025

fftsa.sg_pk_period = 1.0        -- seconds between refreshes
fftsa.sg_pk_ftol   = 0.002      -- fractional frequency move worth a redraw
fftsa.sg_pk_vtol   = 0.01       -- fractional amplitude move worth a redraw
fftsa.sg_pk_last   = nil        -- nil means never drawn, so the first call draws
fftsa.sg_pk_lf     = {}
fftsa.sg_pk_lv     = {}

fftsa.sg_peaks_off = false      -- disables the peak table, to attribute display traffic

-- Gated at fftsa.sg_pk_period and skipped when no peak moved beyond the tolerances,
-- so a dithering last digit does not redraw the block on a steady signal.
function fftsa.sg_show_peaks(bi, bv, count, binhz)
  if fftsa.sg_peaks_off then return false end
  local now = os.clock()
  if fftsa.sg_pk_last ~= nil
     and (now - fftsa.sg_pk_last) < fftsa.sg_pk_period then
    return false
  end
  local abs, sqrt = math.abs, math.sqrt
  local moved = false
  for p = 1, count do
    local k = bi[p]
    local f, v = -1, -1
    if k ~= nil and k > 0 and bv[p] > 0 then
      local dk, iv = fftsa.peak_interp(k, fftsa.sg_nbins)
      if iv == nil then dk, iv = 0, sqrt(bv[p]) end     -- bv is power; iv is volts either way
      f, v = (k - 1 + dk) * binhz, iv
    end
    local lf, lv = fftsa.sg_pk_lf[p], fftsa.sg_pk_lv[p]
    if lf == nil then
      moved = true
    elseif (f < 0) ~= (lf < 0) then
      moved = true                      -- a peak appeared or went away
    elseif f >= 0 then
      local df = fftsa.sg_pk_ftol * lf
      if df <= 0 then df = 1 end
      local dv = fftsa.sg_pk_vtol * lv
      if dv <= 0 then dv = 1e-12 end
      if abs(f - lf) > df or abs(v - lv) > dv then moved = true end
    end
    fftsa.sg_pk_lf[p], fftsa.sg_pk_lv[p] = f, v
  end
  if not moved then return false end
  fftsa.sg_pk_last = now
  return fftsa.sg_show_peaks_now(bi, bv, count, binhz)
end

-- The unconditional draw; the gate above is the only thing deciding when it runs.
function fftsa.sg_show_peaks_now(bi, bv, count, binhz)
  local log10, settext, sqrt = math.log10, display.settext, math.sqrt
  local nb = fftsa.sg_nbins
  for p = 1, count do
    local k = bi[p]
    if k ~= nil and k > 0 and bv[p] > 0 then
      local dk, iv = fftsa.peak_interp(k, nb)
      if iv == nil then dk, iv = 0, sqrt(bv[p]) end     -- no estimate: root of the power bin
      local f, v = (k - 1 + dk) * binhz, iv
      local ftxt
      if f >= 1000 then ftxt = string.format("%d  %.3f kHz", p, f / 1000)
      else ftxt = string.format("%d  %.1f Hz", p, f) end
      local vtxt
      if v >= 1 then vtxt = string.format("%.4f V", v)
      elseif v >= 1e-3 then vtxt = string.format("%.2f mV", v * 1e3)
      else vtxt = string.format("%.0f uV", v * 1e6) end
      -- Floored at the plot's own floor: a 1e-26 power bin reads -260 dBV against
      -- a -120 dBV axis, which the trace cannot show and the column has no room for.
      local dbv = 20 * log10(v)
      if not (dbv > fftsa.sg_dbmin) then dbv = fftsa.sg_dbmin end
      settext(fftsa.sg_pk_f[p], ftxt)
      settext(fftsa.sg_pk_v[p], vtxt)
      settext(fftsa.sg_pk_d[p], string.format("%.1f dBV", dbv))
    else
      settext(fftsa.sg_pk_f[p], string.format("%d  ---", p))
      settext(fftsa.sg_pk_v[p], "")
      settext(fftsa.sg_pk_d[p], "")
    end
  end
  return true
end

function fftsa.sg_status(txt)
  if fftsa.sg_stat ~= nil then display.settext(fftsa.sg_stat, txt) end
end
