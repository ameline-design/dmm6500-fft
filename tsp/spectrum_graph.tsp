-- spectrum_graph.tsp -- spectrum display built on the instrument's own graph object
--
-- X binds to the reading's extra field rather than its timestamp, which makes this the
-- firmware's numeric x-y plot: the axis takes real hertz and labels itself. Y is dBV
-- under a two-character custom buffer unit, which is what labels that axis in dB. A child
-- inside the graph's rectangle is painted over by the repaint, so nothing can be drawn
-- over the firmware's axis row.

fftsa = fftsa or {}   -- the single global this app exposes

fftsa.sg_nbins   = 256
fftsa.sg_npeak   = 6       -- number of peaks reported (shown in a 2x3 grid)

-- Points a frame writes: the only number that sets the widget's work, so it is fixed
-- rather than sized to the span. One per pixel would be 680 and costs 77 ms a fill
-- against 28 ms here. Each carries its column's maximum, which reads the noise floor 6 dB
-- high. Settable up to sg_maxpts while running: FILL_ONCE and cleared, so n follows.
fftsa.sg_ncol    = 255

-- PEAK MARKERS, off by default. A second trace of one point a peak, carrying the
-- interpolated frequency and amplitude the peak table reports -- so a marker sits where
-- the peak really is, which is up to half a bin off the column the trace draws there.
-- Switching it on rebinds the graph, which repaints the axes, so it only happens on Apply.
fftsa.sg_markers = false
-- Needles, not dots: drawstyle is per graph, so markers on the peak trace would put one
-- on all 255 spectrum points too. Three points a peak -- floor, peak, floor, a pixel
-- either side -- draws a vertical needle with the run between them along the bottom rule.
fftsa.sg_mk_per  = 3       -- points a needle: floor, peak, floor
-- Firmware floor on a reading buffer, event 4920. Ask for less and buffer.make returns
-- nil rather than refusing, so every later call on the handle is a 1138.
fftsa.sg_bufmin  = 10
fftsa.sg_maxpts  = 680

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
  fftsa.sg_xunit = nil     -- settings line under the peak rows
  fftsa.sg_stat  = nil
  fftsa.sg_mk    = nil
  fftsa.sg_handles_inited = true
end

-- Touch pans and zooms the graph, and the widget cannot be told not to: display.setstate
-- answers event 1717 for STATE_DISABLE and STATE_READONLY on a Graph. So a locked view is
-- restored after the fact. At rest that is no graph call at all -- sg_lock_check returns
-- on its own gate -- and 121 ms once per gesture. Not a handle, so a relaunch resets it.
fftsa.sg_lock = true

-- Visible frequency window (Hz): fftsa.sg_update() writes only the bins inside it
-- and fftsa.sg_pin_x() pins the axis to it. fftsa.apply() narrows the defaults.
fftsa.sg_flo_hz  = 0
fftsa.sg_fhi_hz  = 1e9

-- The pinned window is the only stable choice. XSCALE_ALL derives the range from the
-- buffer's own timestamps, which move while a frame refills, so a paint landing mid-fill
-- ranges on a partial trace and the axis walks -- on the glass, the trace sliding about as
-- though the point count were changing. Any auto-ranging method also fights the view lock,
-- which then writes an axis a second for as long as both are on.
fftsa.sg_xmethod = display.XSCALE_OFF
-- The clear is the only notify compatible with FILL_ONCE. select, scaletrace, drawstyle
-- and re-asserting scalex all do make the task re-read a bound buffer, but each needs it
-- overwritten in place, which needs FILL_CONTINUOUS, which draws the wrap line.


-- Geometry on the 800x480 panel, in object coordinates: those start below the 49-pixel
-- title bar, so a child at y=350 lands on panel row 399. The graph takes the full height
-- above the peak table and the firmware labels the axis inside it, so no row is reserved.
fftsa.sg_gx      = 8
fftsa.sg_gy      = 0
fftsa.sg_gw      = 784
fftsa.sg_gh      = 312

-- -120 dBV is the floor because the DMM7510's front end sits 12 to 14 dB below the
-- DMM6500's, and at -100 its noise floor was off the bottom of the plot.
fftsa.sg_dbmin   = -120
fftsa.sg_dbmax   = 20
fftsa.sg_vfloor  = 1e-9

-- Plotted width in pixels, measured off a panel capture: the vertical grid rules land at
-- x = 100, 168 ... 780, eleven of them 68 px apart. Used to decide when an axis limit can
-- be moved without it showing.
fftsa.sg_plotpx  = 680

-- fftsa.sg_fhi_hz starts at a sentinel meaning "every bin". A span wider than this is
-- not a plottable axis, so sg_pin_x() makes no call until fftsa.apply() narrows it.
fftsa.sg_fmax_real = 1e6

-- Peak table: 6 rows as two columns of three. freq/volt/dB are separate objects at
-- fixed x, so the volt and dB columns do not jitter as the proportional-font
-- frequency text changes width. The Options button sits in the right margin beside the
-- first row.
fftsa.sg_pky     = 350     -- first peak row baseline
fftsa.sg_pkdy    = 20      -- row pitch
fftsa.sg_pk_colx_f = {8,   360}   -- frequency field x, per column
fftsa.sg_pk_colx_v = {118, 470}   -- voltage field x,   per column
fftsa.sg_pk_colx_d = {200, 552}   -- dB field x,        per column
fftsa.sg_pk_cf   = 14745568  -- freq colour (pale green)
fftsa.sg_pk_cv   = 13166335  -- volt colour (pale blue)
fftsa.sg_pk_cd   = 16769184  -- dB colour   (pale amber)
fftsa.sg_xunit_x = 8
fftsa.sg_xunit_y = 410       -- settings line, below the peak rows
fftsa.sg_xunit_c = 56575     -- cyan 00DCFF, the colour of the Options preview line

-- The nil test is the point: display.create answers nil on an exhausted pool, and the app
-- module deletes handles it may never have built. No pcall -- a refused delete posts an
-- event and returns, so a wrapper can never be false; the suite's live-object counts
-- around a teardown are what catch one.
function fftsa.del_obj(h)
  if h == nil then return true end
  display.delete(h)
  return true
end

function fftsa.del_buf(b)
  if b == nil then return true end
  buffer.delete(b)
  return true
end

-- The X limits the axis should hold, nil for a span that is not plottable. Shared by
-- sg_pin_x and sg_restore so the moved-or-not test cannot disagree with the pin. Start
-- moves to DC where that is under one pixel, because the firmware steps ticks from the
-- lower limit and a 10 Hz Start on a 50 kHz span would label them +00.01kHz; conditional,
-- or a real zoom loses its own limits.
function fftsa.sg_xwant()
  local lo, hi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if hi > fftsa.sg_fmax_real or hi <= lo then return nil, nil end
  if lo > 0 and lo * fftsa.sg_plotpx < (hi - lo) then lo = 0 end
  return lo, hi
end

-- Pin the X axis to the window: auto-range rounds outward to tidy tick values, so
-- the pixel of a given frequency would be unknowable and the firmware's labels would not
-- describe the span.
function fftsa.sg_pin_x()
  if fftsa.sg_graph == nil then return false end
  local lo, hi = fftsa.sg_xwant()
  if lo == nil then return false end
  local m = fftsa.sg_xmethod
  if m == nil then m = display.XSCALE_OFF end
  -- IN HERTZ, not scaled. The trace is bound as a numeric x-y plot, X from the reading's
  -- extra field, which carries the bin's real frequency -- so the axis limits are the
  -- real span and the firmware labels them itself, with an SI prefix: +00.00kHz and so
  -- on. No pcall: the call does not raise, it posts an event, so a wrapper buys nothing
  -- and costs a closure and a frame per call.
  display.graph.scalex(fftsa.sg_graph, m, display.AXIS_NORMAL, lo, hi)
  return true
end

-- The settings line: what Options holds that the axes do not already show, so neither the
-- span nor the dB range is repeated. Written twice per Apply, before the capture and again
-- after, so the rate and bin width it ends up showing are the measured ones.
function fftsa.sg_xunit_text()
   local t = string.format("%d pts   %s   %s", fftsa.n,
                          fftsa.opt_info_text(fftsa.fs, fftsa.n),
                          fftsa.range_labels[fftsa.range_to_idx(fftsa.range)])
  local bptxt = fftsa.bp_text()
  if bptxt ~= "" then t = t .. "   " .. bptxt end
  -- Start 1999 / Stop 2000 is a legal pair and one plotted point at 195.3 Hz bins: the
  -- trace is a dot, five peak rows read ---, and this count is the only thing that says
  -- why. The width is already in the line, so the count alone is enough.
  local b = fftsa.binhz
  if b ~= nil and b > 0 then
    local k0, k1 = fftsa.sg_window_bins(fftsa.sg_nbins, b)
    local n = k1 - k0 + 1
    if n < 3 then
      local plural = "s"
      if n == 1 then plural = "" end
      t = t .. string.format("   only %d bin%s in the span", n, plural)
    end
  end
  return t
end

-- The trace buffer: WRITABLE_FULL carries value, extra and timestamp per point, the value
-- dB under a custom unit and the extra the bin's frequency in hertz. Made once at the
-- sg_maxpts ceiling rather than the current sg_ncol, so nothing reallocates while frames
-- run, and freed only by sg_destroy().
--
-- The clear is the notify: the display task holds its own copy of the readings and
-- re-reads only when handed a buffer, so overwriting one in place changes nothing.
function fftsa.sg_make_buffer(nbins, npoints)
  fftsa.sg_nbins = nbins
  local want = npoints or fftsa.sg_maxpts
  -- Already built at the right size: keep it, and write nothing but sg_nbins. sg_build()
  -- is the only caller and start() the only caller of that, so this is the one place the
  -- no-reallocation rule is stated in code rather than left implicit in the call graph.
  if fftsa.sg_buf ~= nil and fftsa.sg_mk ~= nil and fftsa.sg_buf.capacity == want then
    return fftsa.sg_buf
  end
  -- Detach before deleting: the firmware refuses to delete a buffer still bound to a
  -- graph, so remaking one while attached leaves the old buffer alive and still bound,
  -- and the widget draws both -- a second trace overlaid at the old resolution.
  if fftsa.sg_graph ~= nil then
    display.graph.removeall(fftsa.sg_graph)
  end
  if fftsa.sg_buf ~= nil then
    fftsa.del_buf(fftsa.sg_buf)
    fftsa.sg_buf = nil
  end
  fftsa.sg_buf = fftsa.sg_mkbuf(want)
  -- The marker trace, one point a peak. Made here with the trace buffer and freed with it,
  -- whether or not markers are switched on: allocating it when the option is set would be
  -- an allocation while frames are running.
  if fftsa.sg_mk ~= nil then
    fftsa.del_buf(fftsa.sg_mk)
    fftsa.sg_mk = nil
  end
  local mkcap = fftsa.sg_npeak * fftsa.sg_mk_per
  if mkcap < fftsa.sg_bufmin then mkcap = fftsa.sg_bufmin end
  fftsa.sg_mk = fftsa.sg_mkbuf(mkcap)
  -- The staging arrays sg_update() fills before it clears the buffer. Made here, once,
  -- at the ceiling and never resized: a frame writes slots 1..sg_ncol and reads back the
  -- same, so growing a table mid-frame would allocate inside the window it exists to
  -- shrink. Seeded so every slot is a store rather than a rehash on the first frame.
  fftsa.sg_st_db, fftsa.sg_st_hz = {}, {}
  local j
  for j = 1, want do
    fftsa.sg_st_db[j], fftsa.sg_st_hz[j] = fftsa.sg_dbmin, 0
  end
  -- The marker sort's own slots, one more than the peak count because the insertion
  -- writes j+1 before n has grown.
  fftsa.sg_mk_db, fftsa.sg_mk_hz = {}, {}
  for j = 1, fftsa.sg_npeak + 1 do
    fftsa.sg_mk_db[j], fftsa.sg_mk_hz[j] = fftsa.sg_dbmin, 0
  end
  return fftsa.sg_buf
end

-- One trace buffer: FILL_ONCE, formatted, seeded full. Capacity is sg_maxpts, so a frame
-- writing sg_ncol points always fits and sg_update's clamp is what keeps a raised sg_ncol
-- from writing past it -- one write past capacity is event 4915. Seeded because an empty buffer binds no trace at all, and sg_build() binds this
-- before the first frame has run.
function fftsa.sg_mkbuf(want)
  local b = buffer.make(want, buffer.STYLE_WRITABLE_FULL)
  -- FILL_ONCE: FILL_CONTINUOUS works as documented and still draws a line from the
  -- newest point to the oldest.
  --
  -- A custom unit is how the axis gets to say decibels; without it the labels read
  -- "+020.0V" on numbers that are not volts. Not buffer.UNIT_DECIBEL, which panics the
  -- instrument during build. The firmware truncates a custom label to two characters
  -- (event 4933), which is exactly "dB".
  buffer.unit(buffer.UNIT_CUSTOM1, "dB")
  buffer.write.format(b, buffer.UNIT_CUSTOM1, buffer.DIGITS_4_5,
                         buffer.UNIT_HERTZ,   buffer.DIGITS_6_5)
  local k
  for k = 1, want do
    fftsa.sg_write_point(b, fftsa.sg_dbmin, (k - 1) * 1.0, k)
  end
  return b
end

-- One point: value dB, extra the bin's frequency in Hz, timestamp a plain counter. The
-- timestamp carries nothing -- X is bound to the extra field -- but buffer.write.reading
-- documents chronological order, so it still has to be supplied and to increase. The slot
-- number serves, and as an integer cannot reach the fractional-seconds refusal at
-- 0.9999999 (event 1131, a modal dialog per point).
function fftsa.sg_write_point(buf, db, f, slot)
  if slot == nil then slot = 1 end
  buffer.write.reading(buf, db, f, slot, 0)
end


-- Build the screen once, at launch: graph, peak table, settings line. The frame loop only
-- refills the buffer and updates text.
function fftsa.sg_build(title, nbins, npoints)
  fftsa.sg_destroy()

  fftsa.sg_make_buffer(nbins, npoints)
  local create = display.create
  local small  = display.FONT_SMALL
  fftsa.sg_scr = create(display.ROOT, display.OBJ_SCREEN, title)
  -- create() returns nil when the pool is exhausted, posting one event and not raising.
  -- Without this test every child is built against a nil parent, which DOES raise -- in
  -- our code, not the firmware's. Answering nil and a reason is the same protection
  -- without raising: fftsa.build() passes it to fftsa.start(), which reports it.
  if fftsa.sg_scr == nil then
    fftsa.lasterr = "display object pool exhausted building the spectrum screen -- "
                    .. "power cycle the instrument."
    return nil, fftsa.lasterr
  end
  -- Creating a screen makes it active, so the cover goes back in front before the
  -- first child: otherwise the operator watches the screen assemble itself.
  fftsa.loading_front()

  fftsa.sg_graph = create(fftsa.sg_scr, display.OBJ_GRAPH, fftsa.sg_gx, fftsa.sg_gy, fftsa.sg_gw, fftsa.sg_gh)
  -- X is ELEMENT_EXTRA (the bin's frequency in Hz); Y is ELEMENT_DATA (dB).
  fftsa.sg_bind()

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
    display.graph.removeall(fftsa.sg_graph)
  end
  if fftsa.sg_scr ~= nil then
    display.changescreen(display.SCREEN_HOME)
    fftsa.del_obj(fftsa.sg_scr)
  end
  fftsa.sg_scr, fftsa.sg_graph, fftsa.sg_pk_f, fftsa.sg_pk_v, fftsa.sg_pk_d,
    fftsa.sg_xunit, fftsa.sg_stat = nil, nil, nil, nil, nil, nil, nil
  -- Deleted, not just dropped: a buffer whose handle is dropped is stranded and still
  -- counts against the instrument's capacity.
  if fftsa.sg_buf ~= nil then
    fftsa.del_buf(fftsa.sg_buf)
  end
  if fftsa.sg_mk ~= nil then
    fftsa.del_buf(fftsa.sg_mk)
  end
  fftsa.sg_buf, fftsa.sg_mk = nil, nil
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

-- Refill the trace from fftsa.fft_pwr. Columns are staged into sg_st_db and sg_st_hz
-- first, so only the writes sit inside the window where the buffer holds less than a full
-- trace. The display task shares this core with the interpreter and runs only while Lua
-- is blocked, so the delay at the end is what gets the trace painted.
function fftsa.sg_update(nbins, binhz)
  if binhz == nil or binhz <= 0 then return end   -- no usable frequency scale yet
  local g     = fftsa.sg_graph
  local pwr   = fftsa.fft_pwr
  local wr    = buffer.write.reading
  local log10 = math.log10
  local vfl   = fftsa.sg_vfloor * fftsa.sg_vfloor   -- squared: the bins are power
  local dbmin = fftsa.sg_dbmin
  local dbmax = fftsa.sg_dbmax
  local floor = math.floor
  local kmin, kmax = fftsa.sg_window_bins(nbins, binhz)
  local npts = kmax - kmin + 1
  local buf = fftsa.sg_buf
  if buf == nil then return end
  -- Points this frame writes, CLAMPED TO CAPACITY: one write past it is event 4915, a
  -- modal dialog, and sg_ncol is settable while the app runs. Writing fewer than capacity
  -- is fine because the buffer is FILL_ONCE and cleared -- n follows the writes, so the
  -- trace simply has that many points. That is what makes sg_ncol a live knob without
  -- reallocating anything: the buffer stays at the 680 it was made with.
  local ncol = fftsa.sg_ncol
  local cap  = buf.capacity
  if cap ~= nil and ncol > cap then ncol = cap end
  if ncol == nil or ncol < 2 then ncol = 2 end
  local nwrote = 0
  -- Stage everything, then clear and write. The buffer is empty from the clear until the
  -- last write and a paint landing in there draws a blank or partial trace, so the window
  -- holds nothing but a tight loop of buffer.write.reading. At 255 points that is 20.3 ms
  -- inside the window against 30 ms interleaved, with 7.6 ms of staging outside.
  local st_db, st_hz = fftsa.sg_st_db, fftsa.sg_st_hz
  -- Hoisted out of the loop: the column's frequency advances by a constant, so the
  -- per-point divide and two multiplies become one add.
  local fstep = (npts / ncol) * binhz
  local f0    = (kmin - 1) * binhz
  local c
  for c = 0, ncol - 1 do
    -- The column's bin range. One bin wide at the default, where capacity equals the
    -- bins in the span; wider when the span holds more bins than the cap allows.
    local a = kmin + floor(c * npts / ncol)
    local b = kmin + floor((c + 1) * npts / ncol) - 1
    if b < a then b = a end
    if b > kmax then b = kmax end
    local hi, hik = nil, a
    local k
    for k = a, b do
      local v = pwr[k]
      if v ~= nil and (hi == nil or v > hi) then hi = v; hik = k end
    end
    -- nil (sparse power array) and anything at or below the floor plot at the floor,
    -- so log10 is never handed a zero. The range tests are positives because every
    -- comparison with a NaN is false, so `db < dbmin` would pass one through to
    -- buffer.write.reading and a refused parameter is event 1131 again.
    local db = dbmin
    if hi ~= nil and hi > vfl then
      db = 10 * log10(hi)
      if not (db > dbmin) then db = dbmin
      elseif not (db < dbmax) then db = dbmax end
    end
    -- The column's frequency, not the winning bin's: columns can be narrower than a bin
    -- and several would then share one, so only the column's own frequency is strictly
    -- increasing. A peak is then drawn within one column of its bin, 2.7 px of 680.
    nwrote = nwrote + 1
    st_db[nwrote], st_hz[nwrote] = db, f0 + c * fstep
  end
  fftsa.sg_nwrote = nwrote                   -- segments the widget was actually handed
  -- THE WINDOW. Everything above this line ran against the previous frame's trace, which
  -- was complete and on screen the whole time. From here the buffer is empty until the
  -- loop ends, so there is nothing in it but the writes.
  -- Declared out here on purpose: nothing but the clear and the writes belongs inside
  -- the window, not even a local slot.
  local i
  buf.clear()
  for i = 1, nwrote do
    wr(buf, st_db[i], st_hz[i], i, 0)
  end
  -- No notify call. The clear above is the notify, and the trace stays bound to the
  -- same buffer for the life of the app.
  -- Outside the write window above, where the repaint a graph call triggers would draw a
  -- half-filled trace, and ahead of the paint below.
  fftsa.sg_slow_tick()
  -- The paint. The bound buffer is complete and the next fill has not begun, so this is
  -- the window in which a copy is correct by construction.
  delay(fftsa.sg_yield)
end

-- The one place a zoom touches: it stores the window, rewrites the settings line and
-- re-pins the axis, which is what makes the firmware relabel.
function fftsa.sg_set_xrange(flo_hz, fhi_hz)
  fftsa.sg_flo_hz = flo_hz
  fftsa.sg_fhi_hz = fhi_hz
  if fftsa.sg_xunit ~= nil then
    display.settext(fftsa.sg_xunit, fftsa.sg_xunit_text())
  end
  fftsa.sg_pin_x()
end

-- Bind the traces: the spectrum always, the markers when they are switched on. The one
-- place that decides, so the build and a rebind cannot disagree about what is bound.
--
-- removeall() first, or add() stacks a duplicate trace.
function fftsa.sg_bind()
  local g = fftsa.sg_graph
  if g == nil then return false end
  display.graph.removeall(g)
  display.graph.add(g, fftsa.sg_buf, display.ELEMENT_DATA,
                    fftsa.sg_buf, display.ELEMENT_EXTRA)
  if fftsa.sg_markers and fftsa.sg_mk ~= nil then
    display.graph.add(g, fftsa.sg_mk, display.ELEMENT_DATA,
                      fftsa.sg_mk, display.ELEMENT_EXTRA)
    -- ONE SCALE FOR EVERY TRACE. A custom graph starts at TRACE_ACTIVE, where a scale
    -- call reaches only the selected trace -- so the second trace keeps auto-scaling and
    -- its points are stretched across the whole plot, landing nowhere near the spectrum.
    -- TRACE_ALL syncs them: "as scale settings for X and Y change they will get applied
    -- to all traces". Documented to work only on a custom-created graph, which this is.
    display.graph.scaletrace(g, display.TRACE_ALL)
  end
  -- Always a line. See sg_mk_per: markers are per graph, so the peak trace draws needles
  -- rather than asking for a marker the spectrum would get too.
  display.graph.drawstyle(g, display.STYLE_LINE)
  fftsa.sg_pin_y(g)
  fftsa.sg_pin_x()
  -- Re-asserted for the same reason as the pins above: removeall and add may reset what
  -- the object carries, and the read-back needs the registration to answer at all.
  -- sg_rebind() reaches here from the failed-frame path, so without this one raised frame
  -- could leave a closed padlock over a view that still pans. Idempotent.
  fftsa.sg_lock_hook(fftsa.sg_lock)
  return true
end

-- The dB axis, pinned. Its own function because sg_bind() has to call it once per trace.
function fftsa.sg_pin_y(g)
  if g == nil then g = fftsa.sg_graph end
  if g == nil then return false end
  display.graph.scaley(g, display.YSCALE_OFF, display.AXIS_NORMAL,
                       fftsa.sg_dbmin, fftsa.sg_dbmax)
  return true
end

-- The view lock. Writing an axis limit costs 60 ms and repaints the whole widget, so
-- re-asserting both every frame is most of an 81 ms frame at 512 samples -- a slower,
-- flickering trace. Reading one back costs 0.0094 ms, so the lock reads before it writes.
--
-- The read-back's "return values are only valid when the objects event generation is set
-- to ALL", and non-button objects have none by default -- so on a graph with no event
-- registered, scalex and scaley answer nil and post nothing. sg_lock_hook is therefore
-- not an optimisation: the read-back does not work without it. It reports the gesture
-- too, which lets a tick that saw no fire skip even the reads.
--
-- Our own write also fires EVENT_SCALE, asynchronously, and needs no special case: the
-- echo reads back as the limits just written. EVENT_CURSOR never fires.
--
-- A handler containing %xmin does not run -- measured, and it takes a counter in the same
-- string down with it, so the failure looks like the event never firing. Substitution is
-- documented for command strings and icon_button relies on none of it, so why this one
-- fails is unestablished; do not re-reach for it without checking that first.
fftsa.sg_ev = 0        -- EVENT_SCALE fires since the tick last looked

-- A limit counts as moved past this fraction of sg_moved's scale, which is the larger of
-- the span and the endpoint. Taking the endpoint is what keeps a narrow window far from
-- DC from writing on every tick: at Start 499000, Stop 499010 -- reachable from the form
-- -- the span is smaller than the rounding on its own endpoints.
--
-- The price is a dead zone in exactly that window. Scaled to the endpoint, the tolerance
-- there is 0.499 Hz against a pixel of pan at 0.0147, so about thirty pixels of drag go
-- unrestored while the padlock still reads closed. Accepted because the alternative is a
-- 60 ms write every tick for ever, and because a 10 Hz span at 499 kHz holds no bins at
-- all -- the trace is empty before the lock is the problem. What would settle it is the
-- read-back's actual precision, which is unmeasured: if it round-trips a fractional limit
-- exactly, the scale can be the span alone and the dead zone goes.
fftsa.sg_tol = 1e-6

-- Turn the graph's pan-and-zoom reporting on and off with the lock. Measured at 512
-- samples, the registration costs nothing per frame: frame work was 74.7 ms minimum
-- either way.
--
-- Without the report there is no lock at all, and the symptom is a closed padlock over a
-- view that still pans -- which is invisible unless it says so, hence the message.
function fftsa.sg_lock_hook(on)
  local g = fftsa.sg_graph
  if g == nil then return false end
  if display.EVENT_SCALE == nil then
    fftsa.lasterr = "no EVENT_SCALE on this firmware: the view lock cannot work"
    fftsa.say(fftsa.lasterr)
    return false
  end
  if on then
    display.setevent(g, display.EVENT_SCALE,
                     "if fftsa ~= nil then fftsa.sg_ev = (fftsa.sg_ev or 0) + 1 end")
  else
    display.setevent(g, display.EVENT_SCALE, 0)
  end
  fftsa.sg_ev = 0
  return true
end

function fftsa.sg_moved(got, want, span)
  if got == nil then return false end
  local scale = span
  local a = want
  if a < 0 then a = -a end
  if a > scale then scale = a end
  -- Nothing to measure against: an axis of no height, which only a socket can set. A
  -- zero scale makes every difference exceed the tolerance, so this would otherwise be a
  -- 60 ms write on every reported gesture for the life of the app.
  if scale <= 0 then return false end
  return (got - want) > scale * fftsa.sg_tol
      or (want - got) > scale * fftsa.sg_tol
end

-- Put back whichever axis a gesture moved, and only that one: each write repaints the
-- widget. Only limits are compared, not the scale method the pins also re-assert -- an
-- axis switched to auto-ranging moves its own limits, so the next tick catches it and the
-- pin restores XSCALE_OFF along with them.
function fftsa.sg_restore()
  local g = fftsa.sg_graph
  if g == nil then return false end
  -- Cleared before the writes, not after. A write takes 60 ms an axis and fires
  -- EVENT_SCALE itself, so clearing afterwards discards every fire from that window --
  -- including a finger still dragging through it.
  fftsa.sg_ev = 0
  local wrote = false
  local wlo, whi = fftsa.sg_xwant()
  if wlo ~= nil then
    local x1, x2 = display.graph.scalex(g)
    -- Either limit nil means the read-back told us nothing useful -- both returns are
    -- documented optional. A gesture was reported, so the axis is presumed moved: a pin
    -- costs a frame, a dead lock costs the feature. Guarding only the lower limit would
    -- leave a left-anchored zoom, which moves the upper one alone, invisible.
    if x1 == nil or x2 == nil
       or fftsa.sg_moved(x1, wlo, whi - wlo)
       or fftsa.sg_moved(x2, whi, whi - wlo) then
      fftsa.sg_pin_x()
      wrote = true
    end
  end
  local yspan = fftsa.sg_dbmax - fftsa.sg_dbmin
  local y1, y2 = display.graph.scaley(g)
  if y1 == nil or y2 == nil
     or fftsa.sg_moved(y1, fftsa.sg_dbmin, yspan)
     or fftsa.sg_moved(y2, fftsa.sg_dbmax, yspan) then
    fftsa.sg_pin_y(g)
    wrote = true
  end
  return wrote
end

function fftsa.sg_lock_check()
  if (fftsa.sg_ev or 0) == 0 then return false end
  return fftsa.sg_restore()
end

-- The press path: restores at once rather than at the next tick, and writes both axes
-- without checking, so a lock press costs 121 ms and visibly flickers the trace once.
function fftsa.sg_relock()
  if fftsa.sg_graph == nil then return false end
  fftsa.sg_pin_x()
  fftsa.sg_pin_y()
  fftsa.sg_ev = 0
  return true
end

-- Both repairs, on their own gate at the same period as the peak table -- the constant is
-- shared, the clock is not, since sg_show_peaks re-stamps only when a peak moves. Each
-- undoes something a touch did, so neither needs the frame rate, and at 60 ms a write the
-- lock must not have it. A tick with nothing to do costs one os.clock() and the five
-- setstate calls the icons take. Driven from the frame, so nothing is repaired while the
-- app is halted; the press path covers the lock there.
fftsa.sg_tick_last = nil

function fftsa.sg_slow_tick()
  local now = os.clock()
  if fftsa.sg_tick_last ~= nil
     and (now - fftsa.sg_tick_last) < fftsa.sg_pk_period then
    return false
  end
  fftsa.sg_tick_last = now
  if fftsa.sg_lock then fftsa.sg_lock_check() end
  if fftsa.icons_reassert ~= nil then fftsa.icons_reassert() end
  return true
end

-- The recovery path after a failed frame, and the same binding as the build.
function fftsa.sg_rebind()
  return fftsa.sg_bind()
end

-- Detach and re-add the trace. Not called by the app; tools/test_tsp.lua exercises it.
function fftsa.sg_bind_min()
  display.graph.removeall(fftsa.sg_graph)
  display.graph.add(fftsa.sg_graph, fftsa.sg_buf, display.ELEMENT_DATA,
                    fftsa.sg_buf, display.ELEMENT_EXTRA)
end

-- Seconds the frame stays blocked after the refill so the display task can paint it; too
-- short and the firmware posts 1706. Small because the timer period already leaves a fifth
-- of every frame idle with Lua blocked, so this only insures against a frame whose work
-- fills its whole period.
fftsa.sg_yield = 0.010

fftsa.sg_pk_period = 1.0        -- seconds between refreshes
fftsa.sg_pk_ftol   = 0.002      -- fractional frequency move worth a redraw
fftsa.sg_pk_vtol   = 0.01       -- fractional amplitude move worth a redraw
fftsa.sg_pk_last   = nil        -- nil means never drawn, so the first call draws
fftsa.sg_pk_lf     = {}
fftsa.sg_pk_lv     = {}

fftsa.sg_peaks_off = false      -- disables the peak table, to attribute display traffic

-- Refill the marker trace: one point a peak, at the frequency the peak table reports
-- rather than the column the trace drew. Sorted by frequency, because the peaks arrive
-- strongest-first and the trace is drawn with a line through it -- in amplitude order that
-- line zigzags across the plot. Filled before the spectrum refill, so the paint at the
-- frame's yield sees both buffers complete.
function fftsa.sg_update_markers(bi, bv, count, binhz)
  local mk = fftsa.sg_mk
  if mk == nil or not fftsa.sg_markers then return 0 end
  local log10, sqrt = math.log10, math.sqrt
  local hz, db = fftsa.sg_mk_hz, fftsa.sg_mk_db
  local n = 0
  local p
  for p = 1, count do
    local k = bi[p]
    if k ~= nil and k > 0 and bv[p] > 0 then
      local dk, iv = fftsa.peak_interp(k, fftsa.sg_nbins)
      if iv == nil then dk, iv = 0, sqrt(bv[p]) end
      local f = (k - 1 + dk) * binhz
      local d = 20 * log10(iv)
      if not (d > fftsa.sg_dbmin) then d = fftsa.sg_dbmin end
      if not (d < fftsa.sg_dbmax) then d = fftsa.sg_dbmax end
      -- Insertion by frequency, so the slots come out increasing in x.
      local j = n
      while j > 0 and hz[j] > f do
        hz[j + 1], db[j + 1] = hz[j], db[j]
        j = j - 1
      end
      hz[j + 1], db[j + 1] = f, d
      n = n + 1
    end
  end
  if n == 0 then return 0 end
  -- A needle a peak: the floor a pixel below the peak frequency, the peak, the floor a
  -- pixel above. The x values have to stay increasing or the line doubles back, so each
  -- foot is held at or above the previous needle's -- two peaks within two pixels then
  -- read as one slightly wider needle, which is what they look like anyway.
  local span = fftsa.sg_fhi_hz - fftsa.sg_flo_hz
  local dx = span / fftsa.sg_plotpx
  if not (dx > 0) then dx = binhz end
  local floordb = fftsa.sg_dbmin
  local wr = buffer.write.reading
  local cap = mk.capacity
  local i, slot, prev = nil, 0, nil
  mk.clear()
  for i = 1, n do
    local f = hz[i]
    local l, r = f - dx, f + dx
    if prev ~= nil and l < prev then l = prev end
    if f < l then f = l end
    if r < f then r = f end
    if slot + fftsa.sg_mk_per <= cap then
      slot = slot + 1; wr(mk, floordb, l, slot, 0)
      slot = slot + 1; wr(mk, db[i],   f, slot, 0)
      slot = slot + 1; wr(mk, floordb, r, slot, 0)
      prev = r
    end
  end
  return slot
end

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
