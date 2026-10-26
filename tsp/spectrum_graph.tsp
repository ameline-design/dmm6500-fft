-- spectrum_graph.tsp -- spectrum display built on the instrument's own graph object
--
-- The graph draws a whole trace from a reading buffer in one repaint, so a frame
-- is a buffer refill; per-point line objects or setpixel flood the display queue.
--
-- X IS THE READING'S EXTRA FIELD, NOT ITS TIMESTAMP, which makes this the firmware's
-- numeric x-y plot rather than a time plot: the axis takes its limits in real hertz and
-- the firmware labels them itself, SI prefix and all -- +00.00kHz, +10.00kHz.
--
-- Nothing can be drawn over the firmware's axis row: a child object inside the graph's
-- rectangle is painted over by the widget's per-frame repaint, whatever the creation
-- order. docs/PERFORMANCE.md has that measurement and the dead ends it closes.
--
-- Y is dBV computed in Lua, carried on a fixed linear axis under a two-character custom
-- buffer unit, which is what gets the axis labelled in dB.
--
-- Every object and buffer here is deleted and its handle cleared by
-- fftsa.sg_destroy() before anything is created again; creating over a live handle
-- drops the only reference to the old object, which stays alive until a power cycle.

fftsa = fftsa or {}   -- the single global this app exposes

fftsa.sg_nbins   = 256
fftsa.sg_npeak   = 6       -- number of peaks reported (shown in a 2x3 grid)

-- Trace columns, and the only number that sets the graph widget's work per frame.
--
-- The plotted area is sg_plotpx wide, so one point per pixel is 680 and one per two 340.
--
-- One point a column, carrying the column's MAXIMUM. Rasterising costs per segment
-- length, and a min/max pair doubles the points and makes every second segment span the
-- noise band, about 45 px, where a single-valued trace moves a few px between
-- neighbours. The cost is that max alone reads the floor about 6 dB high.
--
-- Fixed, not sized to the span: a frame then always writes exactly this many points and
-- the widget's load is constant and predictable whatever the sample count or span.
--
-- 255 points, in a buffer ALLOCATED AT 680 and freed only when the app ends. Not one
-- point per pixel: 680 points cost 77 ms a fill against about 28 ms at 255, and the frame
-- is what the operator feels. sg_ncol is settable while the app runs, up to sg_maxpts,
-- because the buffer is FILL_ONCE and cleared -- n follows the writes, so a smaller count
-- simply draws fewer points and reallocates nothing.
fftsa.sg_ncol    = 255

-- PEAK MARKERS, off by default. A second trace of one point a peak, carrying the
-- interpolated frequency and amplitude the peak table reports -- so a marker sits where
-- the peak really is, which is up to half a bin off the column the trace draws there.
-- Switching it on rebinds the graph, which repaints the axes, so it only happens on Apply.
fftsa.sg_markers = false
-- NEEDLES, NOT DOTS. drawstyle is per GRAPH, so asking for markers on the peak trace puts
-- one on all 255 points of the spectrum as well -- line-and-points mode, which is not
-- wanted. So the peak trace is drawn as a line too, carrying three points a peak: the
-- floor, the peak, the floor again, a pixel of plot either side. That draws a vertical
-- needle from the bottom rule up to each peak, with the run between needles hidden along
-- the rule.
fftsa.sg_mk_per  = 3       -- points a needle: floor, peak, floor
-- The firmware's floor on a reading buffer: "capacity must be between 10 and 5311488
-- readings", event 4920. Six peaks is under it, and buffer.make then RETURNS NIL -- so the
-- marker buffer was never created, every call on it took a 1138, and the marker trace drew
-- nothing. A frame still writes only the peaks it found; n follows the writes.
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
-- restored instead, sg_update() re-pinning both axes every frame -- two graph calls an
-- unlocked app does not make, which is why this starts off. Not a handle, so a relaunch
-- resets it on purpose.
fftsa.sg_lock = false

-- Visible frequency window (Hz): fftsa.sg_update() writes only the bins inside it
-- and fftsa.sg_pin_x() pins the axis to it. fftsa.apply() narrows the defaults.
fftsa.sg_flo_hz  = 0
fftsa.sg_fhi_hz  = 1e9

-- The X scale method sg_pin_x() asks for, settable over the socket while the app runs.
--
-- XSCALE_OFF, the pinned window, MEASURED AS THE ONLY STABLE CHOICE. XSCALE_ALL reads
-- the whole buffer and so does notice new writes -- the trace redraws -- but it derives
-- the X range from the buffer's own timestamps, and those move while a frame refills: a
-- paint landing mid-fill computes the range from however much of the trace is there. The
-- axis then walks frame to frame, which on the glass reads as the trace sliding left and
-- right as though the point count were changing. The axis does not need to follow
-- anything: the span is known, and pinning it leaves the redraw to the notify below.
fftsa.sg_xmethod = display.XSCALE_OFF
-- Notify candidates that are NOT used, so none of them is reached for again on the same
-- reasoning: select, scaletrace(TRACE_ACTIVE), drawstyle and re-asserting scalex all make
-- the task re-read a buffer it is already bound to, and scalex was confirmed doing it on
-- the glass. Every one of them needs the bound buffer overwritten in place, which needs
-- FILL_CONTINUOUS, which draws the wrap line. The clear is the only notify compatible
-- with FILL_ONCE.


-- Geometry on the 800x480 panel, in object coordinates, which start below the
-- 49-pixel title bar: a child at y=350 lands on panel row 399.
--
-- The graph takes the full height above the peak table, which starts 38 px below its
-- bottom edge. The firmware labels the axis inside that rectangle, so no row is reserved.
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

-- Delete, nil handle or not. No pcall: the firmware refuses by posting an event and
-- returning, so a wrapper can never be false. A refused delete shows up in the only place
-- it can -- the live-object and live-buffer counts the suite takes around a teardown, and
-- the event log on the instrument.
--
-- The nil test is the part that matters. A handle is nil when display.create could not
-- give us one, and the app module deletes handles it may never have built.
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

-- The X limits the axis should hold, nil for a span that is not a plottable axis. Shared
-- by sg_pin_x() and sg_relock() so the moved-or-not test cannot disagree with the pin.
--
-- Start moves to DC where that is under one pixel of plot: the firmware steps ticks from
-- the lower limit, so a 10 Hz Start on a 50 kHz span labels them +00.01kHz. Conditional,
-- or a real zoom would lose its own limits. Against the plot width, not the bin width,
-- which holds only where Start falls inside bin one.
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

-- The settings line, under the peak rows: everything in Options that the axes do not
-- already show. The span is the X axis and the dB range is the Y axis, so neither is
-- repeated; sample count, rate, bin width, record length, window and input range are.
--
-- Written twice per Apply, by sg_set_xrange() before the capture and again after it, so
-- the rate and bin width it ends up showing are the measured ones.
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

-- The trace buffer. WRITABLE_FULL carries value, extra and timestamp per point: the value
-- is dB under a two-character custom unit, the extra is the bin's frequency in hertz.
--
-- MADE ONCE, WHEN THE APP STARTS, AND FREED ONLY BY fftsa.sg_destroy() WHEN IT ENDS.
-- Capacity is sg_maxpts -- the ceiling, not the current sg_ncol -- whatever the sample
-- count, so neither a size change nor a change of point count needs a new buffer: this
-- writes sg_nbins and returns. Nothing allocates or frees while frames are running.
--
-- FILL_ONCE, cleared and refilled by every frame from arrays it stages first, so nothing
-- but buffer.write.reading is inside the window where the buffer is short of a trace.
-- The clear is also the notify: the display task keeps its own copy of the readings
-- (serial-decode docs/FIRMWARE_API.md, "a trace is a copy in another task") and re-reads
-- a buffer only when it is handed one, so writing over a bound buffer in place changes
-- nothing on the glass. This is the one place that mechanism is stated.
function fftsa.sg_make_buffer(nbins, npoints)
  fftsa.sg_nbins = nbins
  local want = npoints or fftsa.sg_maxpts
  -- Already built at the right size: keep it, and write nothing but sg_nbins. sg_build()
  -- is the only caller and start() the only caller of that, so this is the one place the
  -- no-reallocation rule is stated in code rather than left implicit in the call graph.
  if fftsa.sg_buf ~= nil and fftsa.sg_mk ~= nil and fftsa.sg_buf.capacity == want then
    return fftsa.sg_buf
  end
  -- DETACH BEFORE DELETING. The firmware refuses to delete a buffer that is still
  -- bound to a graph, so remaking one while attached leaves the old buffer alive AND
  -- STILL BOUND: the widget then draws both, which on the glass is a second trace
  -- overlaid on the first at the old resolution. Reached only by a relaunch, where
  -- fftsa.sg_build() has already called sg_destroy(), but the graph handle survives a
  -- reload and the cost of being wrong here is a stranded buffer.
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
  -- Left at FILL_ONCE deliberately. See sg_make_buffer: FILL_CONTINUOUS works exactly
  -- as documented and still draws a line from the newest point to the oldest.
  --
  -- The Y values are decibels, and a custom unit is how the axis gets to say so. NOT
  -- buffer.UNIT_DECIBEL, which panics the instrument during build -- the custom units
  -- are a different path, and the firmware truncates their label to two characters
  -- (event 4933), which is exactly "dB". Without this the axis labels read "+020.0V" on
  -- numbers that are not volts.
  buffer.unit(buffer.UNIT_CUSTOM1, "dB")
  buffer.write.format(b, buffer.UNIT_CUSTOM1, buffer.DIGITS_4_5,
                         buffer.UNIT_HERTZ,   buffer.DIGITS_6_5)
  local k
  for k = 1, want do
    fftsa.sg_write_point(b, fftsa.sg_dbmin, (k - 1) * 1.0, k)
  end
  return b
end

-- One point: value dB, extra the bin's frequency in Hz, timestamp a plain counter.
--
-- The timestamp carries no information -- X is bound to the extra field -- but it still
-- has to be supplied and still has to increase, because buffer.write.reading documents
-- chronological order. The slot number serves, and being an integer it cannot reach the
-- fractional-seconds refusal at 0.9999999 (event 1131, a modal dialog per point).
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

-- Refill the trace from fftsa.fft_pwr: every column is staged into sg_st_db and sg_st_hz
-- first, then the buffer is cleared and written. Only the writes are inside the window
-- where the buffer holds less than a full trace, which is what keeps a paint landing
-- mid-refill from drawing a short one.
--
-- The display task shares this core with the interpreter and runs only while Lua is
-- blocked, so the delay at the end is what gets the new trace painted; too short and the
-- firmware posts 1706, "Message dropped from display queue".
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
  -- STAGE EVERYTHING FIRST, THEN CLEAR AND WRITE. The buffer is at n = 0 from the clear
  -- until the last write, and a paint landing in that window draws a blank or partial
  -- trace -- that is the flicker. So the window is made as narrow as the firmware allows:
  -- every value is computed into the two preallocated arrays while the buffer still
  -- holds the PREVIOUS complete trace, and the only thing between the clear and a full
  -- buffer is a tight loop of buffer.write.reading.
  --
  -- A point costs about 109 us to produce and 51.6 of that is the write itself, so this
  -- moves the better half of the work out of the window: measured at 255 points, 20.3 ms
  -- inside it against 30 ms interleaved, with 7.6 ms of staging outside
  -- (docs/PERFORMANCE.md).
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
    -- The COLUMN's frequency, not the winning bin's. Columns can be narrower than a
    -- bin, and several would then share one, so a column's own frequency is strictly
    -- increasing by construction where the winning bin's is not. The cost is that a peak
    -- is drawn at its column rather than its bin -- within one column, 2.7 px of the
    -- 680 px plot, whatever the size or span; the peak table still carries the
    -- interpolated frequency.
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
  -- Undo a touch pan or zoom, if there has been one. Belongs outside the write window
  -- above, where the repaint a graph call triggers would draw a half-filled trace, and
  -- ahead of the paint below.
  if fftsa.sg_lock then fftsa.sg_relock() end
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

-- Restore the axes only where a pan has moved them. Writing a limit repaints the whole
-- widget, which flickers the trace and costs the frame rate; scalex and scaley called
-- with no limits read them back instead and repaint nothing, so an untouched locked view
-- costs two reads. The tolerance sits below one pixel of pan and above any rounding in
-- the round trip. A nil read-back writes nothing: a lock that misses a drag beats a
-- frame that flickers.
fftsa.sg_notol = 10000

function fftsa.sg_relock()
  local g = fftsa.sg_graph
  if g == nil then return false end
  local moved = false
  local wlo, whi = fftsa.sg_xwant()
  if wlo ~= nil then
    local x1, x2 = display.graph.scalex(g)
    if x1 ~= nil and x2 ~= nil then
      local xtol = (whi - wlo) / fftsa.sg_notol
      if math.abs(x1 - wlo) > xtol or math.abs(x2 - whi) > xtol then
        fftsa.sg_pin_x()
        moved = true
      end
    end
  end
  local y1, y2 = display.graph.scaley(g)
  if y1 ~= nil and y2 ~= nil then
    local ytol = (fftsa.sg_dbmax - fftsa.sg_dbmin) / fftsa.sg_notol
    if math.abs(y1 - fftsa.sg_dbmin) > ytol or math.abs(y2 - fftsa.sg_dbmax) > ytol then
      fftsa.sg_pin_y(g)
      moved = true
    end
  end
  return moved
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

-- Seconds the frame stays blocked after the refill so the display task can paint it.
-- 1706 events mean it is too short. Small because the timer period already leaves 20 % of
-- every frame idle with Lua blocked on the timer, so the task is scheduled in proportion
-- to the frame; this delay only insures against a frame whose work fills its whole
-- period. Measured at 2048 samples, 10 ms and 5 ms both posted no 1706.
--
-- The one owner of this constant: the frame reads it every refill, and nothing else sets
-- it.
fftsa.sg_yield = 0.010

fftsa.sg_pk_period = 1.0        -- seconds between refreshes
fftsa.sg_pk_ftol   = 0.002      -- fractional frequency move worth a redraw
fftsa.sg_pk_vtol   = 0.01       -- fractional amplitude move worth a redraw
fftsa.sg_pk_last   = nil        -- nil means never drawn, so the first call draws
fftsa.sg_pk_lf     = {}
fftsa.sg_pk_lv     = {}

fftsa.sg_peaks_off = false      -- disables the peak table, to attribute display traffic

-- Refill the marker trace from the peak list: one point a peak, at the frequency and
-- amplitude the peak table reports rather than the column the trace drew. Nothing when
-- markers are off, so the buffer keeps its seed and the trace it is not bound to costs
-- nothing.
--
-- SORTED BY FREQUENCY. The peaks arrive strongest-first, and drawstyle is per graph, so
-- the marker trace is drawn with a line through it as well: in amplitude order that line
-- zigzags across the plot. Six points, so an insertion sort is the whole cost.
--
-- Filled BEFORE the spectrum refill. The clear is a notify, and the frame's yield comes
-- after the spectrum's writes, so the paint at the yield sees both buffers complete.
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
