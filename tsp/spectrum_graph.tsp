-- spectrum_graph.tsp -- spectrum-analyser UI built on the instrument's own graph
--
-- WHY THIS DESIGN (all figures measured, host wall-clock unless noted):
--
-- The built-in graph draws the whole trace as ONE object fed from a reading
-- buffer, so a frame is a buffer refill plus a single repaint (256 points in
-- ~20 ms). That beats N line objects or setpixel, which flood the display
-- processor's message queue and eventually panic the firmware.
--
-- FREQUENCY ON THE X AXIS (the "seconds trick"):
-- The DMM graph's X axis is hardwired to TIME formatting -- it renders the
-- timestamp as clock time and cannot print "Hz", so each bin's frequency is
-- written into the timestamp (seconds field) divided by fftsa.sg_fscale.
--
-- The scale is the largest decade that keeps the span under 59 label-seconds,
-- because the firmware's own axis row rolls into base-60 "MM:SS" above that.
-- A 50 kHz span therefore reads 0 to 50 s and the label is kHz directly.
--
-- Fixing the scale at 1e6 so that 1 Hz is 1 us was tried and reverted; see
-- fftsa.sg_pick_fscale for why it made the firmware's axis row flicker.
--
-- The tick labels worth reading are our own (fftsa.sg_axis_update), drawn in
-- real frequency units and refreshed only when the span changes. The firmware's
-- row above them says "s" and there is no way to stop it.
--
-- Y axis: amplitude in dBV on a LINEAR axis (the log is done in Lua). A LOG axis
-- mis-scales the fixed dB range, and buffer.UNIT_DECIBEL panics the firmware, so
-- the buffer is UNIT_VOLT carrying dB numbers on a fixed normal axis.
--
-- OBJECT LIFETIME: every display object and buffer this module creates is
-- deleted and its handle set to nil by fftsa.sg_destroy() BEFORE anything is
-- created again (fftsa.sg_build() calls it unconditionally). Creating over a live
-- handle would overwrite the only reference to the old object, leaving it alive
-- in the firmware with no way to delete it -- and accumulated display objects are
-- what walk this instrument toward a panic.

fftsa = fftsa or {}   -- the single global this app exposes

fftsa.sg_nbins   = 256
fftsa.sg_npeak   = 6       -- number of peaks reported (shown in a 2x3 grid)

-- FIRMWARE HANDLES -- initialised ONLY on the first load of this script.
--
-- Opening the App a second time in one power session re-runs this whole body.
-- `fftsa = fftsa or {}` keeps the table, so a plain `fftsa.sg_scr = nil` here
-- would CLEAR the only reference to the previous launch's screen, graph, text
-- objects and buffer -- stranding them in the firmware, alive and undeletable
-- until the next power cycle. That is precisely the accumulated display churn
-- that walks this instrument toward a panic. Letting the handles survive instead
-- means fftsa.stop() / fftsa.sg_destroy() can reclaim them on the next start.
if fftsa.sg_handles_inited == nil then
  fftsa.sg_buf   = nil     -- WRITABLE_FULL buffer holding the spectrum
  fftsa.sg_scr   = nil     -- custom screen
  fftsa.sg_graph = nil     -- OBJ_GRAPH object
  fftsa.sg_pk_f  = nil     -- per-peak frequency text (own field, fixed x)
  fftsa.sg_pk_v  = nil     -- per-peak voltage text  (own field, fixed x)
  fftsa.sg_pk_d  = nil     -- per-peak dB text       (own field, fixed x)
  fftsa.sg_xunit = nil     -- axis unit legend
  fftsa.sg_stat  = nil
  fftsa.sg_xlab  = nil     -- our own X tick labels, in kHz (table)
  fftsa.sg_handles_inited = true
end

-- Count of deletions the firmware REFUSED (see fftsa.del_obj). Preserved across a
-- reload: a non-zero value means objects may have been stranded, which is the one
-- number worth carrying between launches. Reported by tools/run_app.py.
fftsa.delfails = fftsa.delfails or 0
-- Visible frequency window (Hz). fftsa.sg_update() writes ONLY the FFT bins inside this
-- window, so the graph's own auto-range shows exactly [flo, fhi]; this is how the
-- start/stop zoom is done -- by windowing the data, not by the graph's X scale
-- (which the per-frame re-add resets). Defaults span everything until fftsa.apply()
-- narrows them.
fftsa.sg_flo_hz  = 0
fftsa.sg_fhi_hz  = 1e9
-- Hz per label-"second" for the seconds trick. 1000 => the label IS kHz;
-- fftsa.sg_pick_fscale steps it by decades for a wider span.
fftsa.sg_fscale  = 1000

-- Geometry on the 800x480 panel. Y is limited to 0..420 on a custom screen.
-- The graph is made TALL: tight under the title bar and stretched down to just
-- above the peak table, which is a compact 2-columns-of-3 block at the bottom.
-- (The firmware draws the graph's own X-axis labels ~40 px below the plot box,
--  so the peak table starts below that.)
fftsa.sg_gx      = 8
fftsa.sg_gy      = 24
fftsa.sg_gw      = 784
fftsa.sg_gh      = 272

fftsa.sg_dbmin   = -100
fftsa.sg_dbmax   = 20
fftsa.sg_vfloor  = 1e-9

-- PLOT-AREA GEOMETRY -- calibration constants. The firmware offers no way to ask
-- where it drew the plot box, so these were MEASURED from hardware captures: with
-- X pinned by display.XSCALE_OFF and Y by display.YSCALE_OFF, the tick positions
-- solve to x 105..785 for the X range and y 265..44 for the Y range (axis
-- minimum..maximum). Only these four numbers need revisiting if a firmware update
-- moves the plot box.
--
-- ALL Y VALUES HERE ARE OBJECT COORDINATES, which start BELOW the 49-pixel title
-- bar: a child at y=350 lands on panel row 399. X needs no such correction. Mixing
-- the two frames puts every label 49 pixels low, which is exactly what a screenshot
-- measured naively will tell you to do.
fftsa.sg_px0     = 105     -- x of the X axis minimum
fftsa.sg_px1     = 785     -- x of the X axis maximum
--
-- WHY THE X TICKS SIT BELOW THE PLOT RATHER THAN ON THE FIRMWARE'S OWN LABEL ROW.
-- The graph object's rectangle is x 8..792, y 24..296, and the firmware writes its
-- labels inside that, in its own margins. Two things were measured on hardware:
--
--   * An object placed inside that rectangle is painted over by the graph's
--     per-frame repaint and never appears. Creation order does not help, and a
--     cover rectangle there does not hide the firmware's labels either.
--   * Re-issuing our objects after every repaint does make them appear, but it
--     flickers badly and saturates the display processor enough that the
--     instrument looks hung.
--
-- So our labels live BELOW y=296, outside the graph, drawn once and never touched
-- by a repaint -- which also means they cost nothing per frame. The firmware's own
-- row stays visible above ours; it cannot be hidden, and with the axis pinned it is
-- at least our window expressed in scaled seconds.
--
-- Only the X axis gets our labels. The firmware's Y numbers are already the correct
-- dBV values -- only the "V" suffix is wrong, which the legend states -- and a Y
-- tick has to sit on its gridline, which is inside the graph rectangle and so
-- unreachable.
fftsa.sg_xlab_y  = 314     -- baseline of our X ticks: below the graph, above the peaks
-- Every label is JUST_LEFT, the one justification this app has proven on hardware,
-- so an X tick is nudged left by roughly half the width of a label like "12.5 kHz"
-- to sit centred on its gridline. The end ticks are pulled further in, which keeps
-- the first against the axis and the last clear of the right edge of the panel.
fftsa.sg_xlab_hw = 26
fftsa.sg_nxlab   = 5       -- X ticks, endpoints included
fftsa.sg_axc     = 12632256    -- axis label colour
-- fftsa.sg_fhi_hz starts at a sentinel meaning "every bin" until fftsa.apply()
-- sets a real window. A span that wide is not a plottable axis, so the pin and
-- the labels stay out of the way until it is narrowed.
fftsa.sg_fmax_real = 1e6

-- Peak table: 6 rows as TWO COLUMNS OF THREE. freq/volt/dB are each their OWN
-- text object at a FIXED x, which is what stops the volt and dB columns from
-- jittering left-right as the (variable-width, proportional-font) frequency
-- string changes width. The far bottom-right is left free for the Options button.
fftsa.sg_pky     = 350     -- first peak row baseline
fftsa.sg_pkdy    = 20      -- row pitch
fftsa.sg_pk_colx_f = {8,   360}   -- frequency field x, per column
fftsa.sg_pk_colx_v = {118, 470}   -- voltage field x,   per column
fftsa.sg_pk_colx_d = {200, 552}   -- dB field x,        per column
fftsa.sg_pk_cf   = 14745568  -- freq colour (pale green)
fftsa.sg_pk_cv   = 13166335  -- volt colour (pale blue)
fftsa.sg_pk_cd   = 16769184  -- dB colour   (pale amber)
-- X-axis legend: clear of the three peak rows (350/370/390) and of the Options
-- button, so it never collides with the firmware's own axis labels.
fftsa.sg_xunit_x = 8
fftsa.sg_xunit_y = 410
fftsa.sg_xunit_c = 9474192   -- 0x909090

-- Delete a display object / a buffer, and do NOT hide a refusal.
--
-- A bare pcall around a delete conflates the harmless failure (the handle is
-- already dead -- a child that went with its parent screen) with the dangerous
-- one (the firmware refused and the object is still alive and unreachable). The
-- handle is cleared either way, since nothing else could ever free it, but a
-- refusal is COUNTED in fftsa.delfails and recorded rather than swallowed.
--
-- Defined here because this is the first module that deletes anything; the app
-- module loads after it and uses them too.
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

-- Pin the X axis to the visible window instead of letting the graph auto-range.
--
-- Auto-range rounds OUTWARD to tidy tick values, so the data never reaches the
-- plot edges and the pixel position of a given frequency is unknowable -- which
-- would make our own labels point at the wrong places. Pinning makes the mapping
-- exact and linear between fftsa.sg_px0 and fftsa.sg_px1.
--
-- Measured on hardware: a PINNED scale survives the per-frame removeall+add,
-- while an auto scale does not (the re-add resets it). Re-asserting it per frame
-- is therefore not required for correctness -- it is one message that makes the
-- axis self-healing if anything else ever moves it.
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

-- Text for one X tick. The SPAN sets the precision: a 200 Hz zoom needs digits a
-- 50 kHz span does not, and two adjacent ticks reading the same number are worse
-- than no ticks at all.
-- Each tick carries its own unit, so the row reads correctly on its own -- the
-- firmware's row above it says "s" and there is no way to stop it.
function fftsa.sg_flabel(f, span)
  if span >= 1000 then return string.format("%.1f kHz", f / 1000) end
  return string.format("%.0f Hz", f)
end

-- Refresh the X tick text, and ONLY when it would actually change.
--
-- The tick PIXELS never move: the axis is pinned and the ticks sit at fixed
-- fractions of it, so a zoom changes the numbers and nothing else. That makes
-- display.settext the whole update -- no object is recreated or repositioned for
-- a new span. The span that is currently on screen is remembered so the frame
-- loop costs zero display messages here in the steady state; per-frame text
-- churn is exactly what floods this instrument's display processor.
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

-- Hz per label-"second": the largest decade that keeps the whole span inside
-- the graph's own decimal label format, which rolls into base-60 "MM:SS" above
-- 59 s. The walk is what guarantees the span never reaches that rollover.
--
-- Do NOT fix this at 1e6. That was tried on 2026-10-23, on the reasonable
-- theory that one label-second per MHz keeps the axis decimal for every span
-- the instrument can reach. It does -- and it also compresses the firmware's
-- own axis row into a range where its label-count choice is unstable. A 50 kHz
-- span becomes 50 ms, the row renders "00.01ms 10.01ms 20.01ms", and on some
-- frames it renders eleven labels instead of six, adding "05.01ms 15.01ms" for
-- a single frame. The operator saw that as a distracting flicker once or twice
-- a second, and it was entirely self-inflicted: at a decade scale the same span
-- is 0 to 50 s with six wide, distinct labels and the choice does not waver.
function fftsa.sg_pick_fscale(fhi_hz)
  local s = 1000                      -- the label then reads directly as kHz
  if fhi_hz == nil or fhi_hz <= 0 then return s end
  while fhi_hz / s >= 59 do s = s * 10 end
  return s
end

-- Legend naming the units our own tick labels are in. The graph's internal X
-- axis is in scaled seconds, so the legend states the multiplier whenever it is
-- not the expected 1e6 -- the one clue left if the label covers fail to paint.
function fftsa.sg_xunit_text()
  local s = fftsa.sg_fscale
  if s == 1000 then return "X: kHz   Y: dBV" end
  return string.format("X: kHz   Y: dBV   (graph x%g)", s / 1000)
end

-- Create the buffer that backs the trace. WRITABLE_FULL carries value + extra +
-- timestamp per point. Value unit VOLT (holds dB numbers), extra unit HERTZ.
--
-- Deletes any previous buffer first: buffer.make() into a live handle would
-- orphan the old buffer with no reference left to free it. The caller must
-- already have detached the graph (fftsa.sg_destroy() does), because deleting a
-- buffer a graph still references is asking for trouble.
function fftsa.sg_make_buffer(nbins)
  fftsa.sg_nbins = nbins
  if fftsa.sg_buf ~= nil then
    fftsa.del_buf(fftsa.sg_buf)
    fftsa.sg_buf = nil
  end
  fftsa.sg_buf = buffer.make(nbins + 16, buffer.STYLE_WRITABLE_FULL)
  -- DO NOT use buffer.UNIT_DECIBEL here: it panics the instrument during build.
  buffer.write.format(fftsa.sg_buf, buffer.UNIT_VOLT,  buffer.DIGITS_4_5,
                              buffer.UNIT_HERTZ, buffer.DIGITS_6_5)
  return fftsa.sg_buf
end

-- One point: value=dB, extra=Hz, timestamp=scaled frequency (the seconds trick).
function fftsa.sg_write_point(buf, db, f)
  local t = f / fftsa.sg_fscale
  buffer.write.reading(buf, db, f, math.floor(t), t - math.floor(t))
end

-- Create our own X tick labels, in real frequency units.
--
-- The graph's own labels cannot be relabelled or switched off: the X axis is
-- hardwired to TIME formatting, so it prints "12.00s" for what is really 12 kHz.
-- display.setabbrv() is no help -- it applies to option fields, not axes -- and
-- neither is covering them up (see the geometry notes above). So a second row of
-- ticks is written below the plot, stating the frequencies the trace actually
-- spans, and the axis is pinned so those numbers are exact.
function fftsa.sg_axis_build(create, small)
  -- X ticks, nudged so each reads as centred on its gridline and neither end one
  -- runs off the panel. Text is filled in by fftsa.sg_axis_update() once a real
  -- span exists.
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

-- Build the screen: graph + split peak table. Created once; the frame loop only
-- refills the buffer and updates text.
function fftsa.sg_build(title, nbins)
  -- Destroy first, ALWAYS: guarantees no old screen/graph/text/buffer survives
  -- unreachable behind an overwritten handle. Safe when nothing exists yet.
  fftsa.sg_destroy()

  fftsa.sg_make_buffer(nbins)
  local create = display.create
  local small  = display.FONT_SMALL
  fftsa.sg_scr = create(display.ROOT, display.OBJ_SCREEN, title)
  display.changescreen(fftsa.sg_scr)

  -- Prime the buffer BEFORE attaching it: graph.add() on an EMPTY buffer binds
  -- nothing and later writes never draw. Fill a flat line at the dB floor first.
  fftsa.sg_buf.clear()
  for k = 1, nbins do
    fftsa.sg_write_point(fftsa.sg_buf, fftsa.sg_dbmin, (k - 1) * 1.0)
  end

  fftsa.sg_graph = create(fftsa.sg_scr, display.OBJ_GRAPH, fftsa.sg_gx, fftsa.sg_gy, fftsa.sg_gw, fftsa.sg_gh)
  -- X axis = TIME element (our scaled-frequency timestamps); Y = DATA (dB).
  display.graph.add(fftsa.sg_graph, fftsa.sg_buf, display.ELEMENT_DATA, fftsa.sg_buf, display.ELEMENT_TIME)
  display.graph.drawstyle(fftsa.sg_graph, display.STYLE_LINE)
  pcall(function()
    display.graph.scaley(fftsa.sg_graph, display.YSCALE_OFF, display.AXIS_NORMAL,
                         fftsa.sg_dbmin, fftsa.sg_dbmax)
  end)
  fftsa.sg_pin_x()
  fftsa.sg_axis_build(create, small)
  fftsa.sg_axis_update(true)

  -- Split peak table, 2 columns of 3: each field is its own fixed-x object so
  -- volt/dB never jitter. Peaks 1-3 fill the left column, 4-6 the right.
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

  -- X-axis unit legend: the graph's own labels carry an "s" suffix, so say what
  -- they mean. Updated by fftsa.sg_set_xrange() whenever the scale changes.
  fftsa.sg_xunit = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_xunit_x, fftsa.sg_xunit_y,
                          fftsa.sg_xunit_text(), fftsa.sg_xunit_c, small, display.JUST_LEFT)

  fftsa.sg_stat = nil     -- no on-screen status object (kept off to preserve room)
  return fftsa.sg_scr
end

-- Tear everything down before any rebuild so objects never accumulate. Deletes
-- in dependency order -- detach the trace, then drop the screen (its children go
-- with it), then free the buffer -- and nils EVERY handle, including the child
-- text objects, so nothing is left pointing at a deleted object.
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
  -- The cached span and label text belong to objects that no longer exist.
  fftsa.sg_lab_lo, fftsa.sg_lab_hi, fftsa.sg_xlab_txt = nil, nil, nil
  -- The buffer goes last: the graph referencing it is gone by now.
  if fftsa.sg_buf ~= nil then
    fftsa.del_buf(fftsa.sg_buf)
  end
  fftsa.sg_buf = nil
  collectgarbage()
end

-- Bin index range covering the visible window, clamped into 1..nbins. Shared by
-- fftsa.sg_update() (what to plot) and the peak search (what to report), so the
-- table always describes what is on screen.
--
-- BOTH ends must be clamped. An inconsistent window -- flo above fhi, or a start
-- beyond Nyquist -- otherwise yields kmin past the end of fftsa.fft_pwr, and the
-- resulting nil comparison raises an error that kills every single frame.
function fftsa.sg_window_bins(nbins, binhz)
  if binhz == nil or binhz <= 0 then return 1, nbins end
  local floor, ceil = math.floor, math.ceil
  -- The low edge rounds UP to the first bin centred at or above flo. Rounding
  -- down would silently re-admit the DC bin: at a 195 Hz bin width, floor() maps
  -- every start below one bin width -- including the 10 Hz floor -- back to bin 1.
  local kmin = ceil(fftsa.sg_flo_hz / binhz) + 1
  local kmax = floor(fftsa.sg_fhi_hz / binhz) + 1
  if kmin < 1 then kmin = 1 end
  if kmin > nbins then kmin = nbins end
  if kmax > nbins then kmax = nbins end
  if kmax < kmin then kmax = kmin end
  return kmin, kmax
end

-- Refill the trace from fftsa.fft_pwr. One buffer pass, repainted once.
-- `binhz` is the true bin width (from the measured sample rate).
--
-- REFILL IN PLACE: do not detach the trace, do not hide the graph, and then
-- yield so the display task can paint. The trace holds the buffer by reference
-- and the display side is fed by a subscription, so clearing and refilling
-- streams the new readings to the trace that is already attached.
--
-- Three orders were tried on hardware, 2026-10-23, on a standalone 256-point
-- sine at this graph's geometry with the event log read after every run:
--
--   refill in place, yield 40 ms     15.8 Hz   0 events   no flicker
--   refill in place, yield 10 ms     30.1 Hz   0 events   visibly jumpy
--   refill in place, yield 5 ms      35.6 Hz   194 events, trace jumped 3-4 Hz
--   detach-first removeall+add       25.9 Hz   0 events   AXIS TEXT FLICKER
--   hide / refill / show             35.6 Hz   events     axis flicker, jumpy
--
-- Every one of those 194 events was 1706, "Message dropped from display queue".
-- The display task is not scheduled while Lua runs -- it only gets the core when
-- the Lua task blocks -- so a loop that never blocks builds a backlog every
-- frame until the queue overruns, which shows as a high Lua frame rate with the
-- glass falling further behind.
--
-- Both of the other two orders fix that by blocking, and both repaint the WHOLE
-- widget: the operator sees the graph object's own axis label text redrawn on
-- every frame, at the frame rate, independent of anything else on screen.
-- Refill in place is the only order that leaves the axes alone, because the
-- subscription repaints the trace and nothing else. So the block has to come
-- from an explicit yield instead, which is what the delay at the end is.
--
-- The cost of refilling while attached is 76 us a point against 54 us detached,
-- since every reading is forwarded as it is written. That ~5.6 ms is the price
-- of not flickering, and it is cheaper than the paint a rebind forces.
--
-- An earlier version of this function hid the graph for the refill. It looked
-- faster -- 81 ms a frame against 164 -- but the saving was an illusion: the
-- 43 ms attributed to removeall was the paint happening, and hiding the widget
-- only moved the backlog out of the frame being timed.
function fftsa.sg_update(nbins, binhz)
  if binhz == nil or binhz <= 0 then return end   -- no usable frequency scale yet
  local g     = fftsa.sg_graph
  local buf   = fftsa.sg_buf
  local pwr   = fftsa.fft_pwr
  local wr    = buffer.write.reading
  local floor = math.floor
  local log10 = math.log10
  -- The floor is squared because the bins are now power, not magnitude.
  local vfl   = fftsa.sg_vfloor * fftsa.sg_vfloor
  local dbmin = fftsa.sg_dbmin
  local dbmax = fftsa.sg_dbmax
  local fscl  = fftsa.sg_fscale
  -- Write only the bins inside the visible window so the graph auto-ranges to it.
  local kmin, kmax = fftsa.sg_window_bins(nbins, binhz)
  -- Whether the seconds field can ever be non-zero, decided ONCE rather than
  -- rediscovered per point. Whether it pays depends on the scale in force: at a
  -- decade scale a 50 kHz span runs to 50 label-seconds so the floor is needed,
  -- but a narrow zoom stays under 1 s and the call is pure waste. Decided from
  -- the span rather than hardcoded, so either case is correct.
  local subsecond = ((kmax - 1) * binhz / fscl) < 1
  buf.clear()
  for k = kmin, kmax do
    local v = pwr[k]
    local db
    -- nil (sparse power array) and anything at or below the floor both plot at
    -- the floor; log10 is never handed a zero. 10*log10 of power is the same
    -- number as 20*log10 of magnitude, without the square root.
    if v == nil or v <= vfl then db = dbmin else db = 10 * log10(v) end
    if db < dbmin then db = dbmin end
    if db > dbmax then db = dbmax end
    local f = (k - 1) * binhz
    local t = f / fscl                       -- scaled frequency into the seconds field
    if subsecond then
      wr(buf, db, f, 0, t)
    else
      local w = floor(t)
      wr(buf, db, f, w, t - w)
    end
  end
  -- Yield, so the display task can paint what was just written. Nothing else in
  -- the frame blocks for it, and it is not scheduled while Lua runs, so without
  -- this the backlog grows every frame: a fast Lua loop and a trace that jumps.
  --
  -- The yield is genuinely idle time on this core and cannot be filled -- any
  -- Lua work put here would starve the task it exists to feed.
  delay(fftsa.sg_yield)
end

-- Set the visible frequency window (Hz). fftsa.sg_update() writes only the bins inside
-- it, so the graph's auto-range becomes exactly this window (see fftsa.sg_flo_hz note).
-- Also picks the X-axis scale that keeps the graph's own labels readable as a
-- frequency, and refreshes the legend that states it.
function fftsa.sg_set_xrange(flo_hz, fhi_hz)
  fftsa.sg_flo_hz = flo_hz
  fftsa.sg_fhi_hz = fhi_hz
  fftsa.sg_fscale = fftsa.sg_pick_fscale(fhi_hz)
  if fftsa.sg_xunit ~= nil then
    pcall(function() display.settext(fftsa.sg_xunit, fftsa.sg_xunit_text()) end)
  end
  -- Pin the graph to the new window and relabel it. This is the ONE place a zoom
  -- has to touch, because the tick pixels are fixed and only the numbers move.
  fftsa.sg_pin_x()
  fftsa.sg_axis_update()
end

-- Re-bind the trace to our buffer (X=TIME). Call ONCE after acquisition is
-- configured; removeall() first, or add() stacks duplicate traces.
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

-- Per-frame re-add. fftsa.sg_update() clears then refills the buffer; the clear alone
-- would async-repaint an empty graph (a visible flicker), so the atomic
-- removeall+add repaints the complete buffer in one step. X = TIME (see header).
function fftsa.sg_bind_min()
  pcall(function() display.graph.removeall(fftsa.sg_graph) end)
  pcall(function() display.graph.add(fftsa.sg_graph, fftsa.sg_buf, display.ELEMENT_DATA,
                                     fftsa.sg_buf, display.ELEMENT_TIME) end)
  -- NOTHING ELSE HAPPENS HERE, deliberately. Two things were tried and both cost
  -- more than they were worth, measured on hardware:
  --
  --   * Re-issuing our labels after each repaint. It does make objects inside the
  --     graph's rectangle visible, but it flickers heavily and saturates the
  --     display processor until the instrument looks hung. Our labels live outside
  --     that rectangle instead, so a repaint cannot touch them.
  --   * Re-asserting the X pin. A pinned scale already SURVIVES this removeall+add
  --     (two captures either side of one were pixel-identical), so the only effect
  --     of re-pinning was to make the firmware redraw its own axis labels every
  --     frame, which showed as an intermittent flicker in them.
  --
  -- The pin is set where the span is set -- fftsa.sg_set_xrange() -- which is the
  -- only thing that can invalidate it.
end

-- Update the split peak fields. Each field is set independently at its fixed x,
-- left-justified, so its origin never moves as the value's width changes.
--
-- The reported frequency and amplitude come from fftsa.peak_interp(), which
-- recovers the sub-bin position from the peak's two neighbours. Without it a
-- tone between bins reads up to half a bin off in frequency and up to 1.42 dB
-- low in amplitude, both of which are large next to this instrument's accuracy.
-- Gated at 1 Hz, and skipped entirely when no peak has moved.
--
-- Not a frame-cost measure: display.settext is about 19 us on this instrument
-- (measured), so all 18 fields together cost well under a millisecond and
-- removing the block outright bought only ~5 ms of a 127 ms frame. The reasons
-- are that six peaks rewritten ten times a second cannot be read, and that a
-- once-a-second burst of 18 messages is visible as a hitch in an otherwise
-- even cadence. The tolerance is what stops a dithering last digit from
-- redrawing the block on a signal that is not actually changing.
-- Seconds of yield per frame, for the display task to paint the refill. ~25 ms
-- is the measured paint cost of a 256-point refill less the ~6 ms already spent
-- blocked in digitize.read. Too small and the trace jumps while 1706 events
-- accumulate; too large and frames are simply slower than they need to be.
fftsa.sg_yield = 0.025

fftsa.sg_pk_period = 1.0        -- seconds between refreshes
fftsa.sg_pk_ftol   = 0.002      -- fractional frequency move worth a redraw
fftsa.sg_pk_vtol   = 0.01       -- fractional amplitude move worth a redraw
fftsa.sg_pk_last   = nil        -- nil means never drawn, so the first call draws
fftsa.sg_pk_lf     = {}
fftsa.sg_pk_lv     = {}

-- Switch for isolating the peak table when something on the glass needs to be
-- attributed. Added 2026-10-23 while chasing an axis-text flicker that turned
-- out to be the axis scale, not this block.
fftsa.sg_peaks_off = false

function fftsa.sg_show_peaks(bi, bv, count, binhz)
  if fftsa.sg_peaks_off then return false end
  local now = os.clock()
  if fftsa.sg_pk_last ~= nil
     and (now - fftsa.sg_pk_last) < fftsa.sg_pk_period then
    return false
  end
  -- Past the clock gate, still spend nothing unless something moved. A steady
  -- tone therefore draws the block once and then leaves it alone.
  local abs, sqrt = math.abs, math.sqrt
  local moved = false
  for p = 1, count do
    local k = bi[p]
    local f, v = -1, -1
    if k ~= nil and k > 0 and bv[p] > 0 then
      local dk, iv = fftsa.peak_interp(k, fftsa.sg_nbins)
      -- bv is POWER now, so the fallback has to take the root that
      -- peak_interp would have taken; iv is volts either way.
      if iv == nil then dk, iv = 0, sqrt(bv[p]) end
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

-- The unconditional draw. Kept separate so the gate above is the only thing
-- deciding when it runs, and so a caller that must refresh (a new span, a
-- rebuilt screen) can reach it directly.
function fftsa.sg_show_peaks_now(bi, bv, count, binhz)
  local log10, settext, sqrt = math.log10, display.settext, math.sqrt
  local nb = fftsa.sg_nbins
  for p = 1, count do
    local k = bi[p]
    if k ~= nil and k > 0 and bv[p] > 0 then
      local dk, iv = fftsa.peak_interp(k, nb)
      -- bv is POWER now, so the fallback has to take the root that
      -- peak_interp would have taken; iv is volts either way.
      if iv == nil then dk, iv = 0, sqrt(bv[p]) end     -- edge bin or sparse spectrum
      local f, v = (k - 1 + dk) * binhz, iv
      local ftxt
      if f >= 1000 then ftxt = string.format("%d  %.3f kHz", p, f / 1000)
      else ftxt = string.format("%d  %.1f Hz", p, f) end
      local vtxt
      if v >= 1 then vtxt = string.format("%.4f V", v)
      elseif v >= 1e-3 then vtxt = string.format("%.2f mV", v * 1e3)
      else vtxt = string.format("%.0f uV", v * 1e6) end
      settext(fftsa.sg_pk_f[p], ftxt)
      settext(fftsa.sg_pk_v[p], vtxt)
      settext(fftsa.sg_pk_d[p], string.format("%.1f dBV", 20 * log10(v)))
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
