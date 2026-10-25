-- spectrum_graph.tsp -- spectrum display built on the instrument's own graph object
--
-- The graph draws a whole trace from a reading buffer in one repaint, so a frame
-- is a buffer refill; per-point line objects or setpixel flood the display queue.
--
-- X IS THE READING'S EXTRA FIELD, NOT ITS TIMESTAMP, which makes this the firmware's
-- numeric x-y plot rather than a time plot: the axis takes its limits in real hertz and
-- the firmware labels them itself, SI prefix and all -- +00.00kHz, +10.00kHz.
--
-- The time form was used first and cost a whole row of the screen. The X axis of a time
-- plot is labelled in seconds with a suffix that cannot be switched off, so the bin's
-- frequency went into the timestamp divided by a decade scale and the app drew its own
-- label row underneath in real units. Masking the firmware's row was tried and cannot
-- work: a child object inside the graph's rectangle is painted over by its per-frame
-- repaint, proved with a white bar that showed only for the three pixels extending past
-- the graph's right edge. Binding the extra field instead removes the problem rather
-- than hiding it, and with it five text objects, their per-span rewrites, and the
-- scaled-timestamp arithmetic in the inner loop.
--
-- Y is dBV computed in Lua, carried in a UNIT_VOLT buffer on a fixed linear axis.
--
-- Every object and buffer here is deleted and its handle cleared by
-- fftsa.sg_destroy() before anything is created again; creating over a live handle
-- drops the only reference to the old object, which stays alive until a power cycle.

fftsa = fftsa or {}   -- the single global this app exposes

fftsa.sg_nbins   = 256
fftsa.sg_npeak   = 6       -- number of peaks reported (shown in a 2x3 grid)

-- Trace columns, and the only number that sets the graph widget's work per frame.
--
-- The plotted area is 680 px wide, measured off a panel capture: the vertical grid
-- rules land at x = 100, 168, ... 780, eleven of them 68 px apart, with the Y-axis
-- labels to the left of x = 100. So one point per pixel is 680 and one per two is 340.
--
-- One point a column carrying the column's MAXIMUM. Writing the minimum as well was
-- tried, for a noise floor that read as a band rather than its upper envelope, and
-- withdrawn: it doubled the point count as the sample count rose and made every second
-- segment span the whole band, about 45 px, where a single-valued trace moves a few px
-- between neighbours. Rasterising costs per segment length. Max alone reads the floor
-- about 6 dB high.
--
-- Fixed, not sized to the span: a frame then always writes exactly this many points and
-- the widget's load is constant and predictable whatever the sample count or span.
--
-- 255 points, with the pair ALLOCATED AT 680 and freed only when the app ends. One
-- point per pixel was tried and withdrawn on cost: it made the fill 77 ms against about
-- 28 ms here, and the frame is what the operator feels. sg_ncol is settable while the
-- app runs, up to sg_maxpts, because the buffers are FILL_ONCE and cleared -- n follows
-- the writes, so a smaller count simply draws fewer points and reallocates nothing.
fftsa.sg_ncol    = 255
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
  fftsa.sg_xunit = nil     -- axis unit legend
  fftsa.sg_stat  = nil
  fftsa.sg_handles_inited = true
end

-- Visible frequency window (Hz): fftsa.sg_update() writes only the bins inside it
-- and fftsa.sg_pin_x() pins the axis to it. fftsa.apply() narrows the defaults.
fftsa.sg_flo_hz  = 0
fftsa.sg_fhi_hz  = 1e9

-- EXPERIMENT, both settable over the socket while the app runs.
--
-- The display task keeps its own copy of the readings (FIRMWARE_API.md:246), so
-- overwriting a bound buffer in place is invisible to it and something has to make it
-- re-read. These two choose what.
--
-- sg_xmethod is the X scale method sg_pin_x() asks for. XSCALE_OFF is a fixed window --
-- the one method that needs nothing from the buffer, which may be exactly why our
-- in-place writes never appear. The instrument's own reading graph redraws live from a
-- continuously filled buffer, and on the front panel it is set to Show Group. The
-- measured internals (FIRMWARE_API.md:821): ALL reads the whole buffer decimated to 710
-- points, so our sg_ncol fit undecimated; LATEST reads a 648-point window ending at the
-- newest reading; GROUP is internal mode 7. If one of them follows the buffer by itself
-- then a frame needs no graph call at all, which is the cheapest outcome available.
-- XSCALE_OFF, the pinned window, MEASURED AS THE ONLY STABLE CHOICE. XSCALE_ALL was
-- tried first, on the reasoning that it reads the whole buffer and so has to notice new
-- writes -- it does, and the trace redrew, but it also derives the X range from the
-- buffer's own timestamps. The buffer is a ring, so startindex sweeps across it as the
-- fill advances and a paint landing mid-fill computes the range from whichever slot the
-- write position had reached. The axis then walks frame to frame, which on the glass
-- reads as the trace sliding left and right as though the point count were changing.
-- The axis does not need to follow anything: the span is known, and pinning it leaves
-- the redraw to the notify below.
fftsa.sg_xmethod = display.XSCALE_OFF
-- Notify candidates that were tried and are NOT used, so none of them is tried again
-- on the same reasoning: select, scaletrace(TRACE_ACTIVE), drawstyle and re-asserting
-- scalex all make the task re-read a buffer it is already bound to, and scalex was
-- confirmed doing it on the glass. Every one of them needs the bound buffer overwritten
-- in place, which needs FILL_CONTINUOUS, which draws the wrap line. The hand-over is
-- the only notify compatible with FILL_ONCE.


-- Geometry on the 800x480 panel, in object coordinates, which start below the
-- 49-pixel title bar: a child at y=350 lands on panel row 399.
--
-- The graph is 20 px taller than it was. It used to stop short to leave a row for the
-- app's own X labels; the firmware labels the axis itself now, so that row is free and
-- the plot has it. The peak table still starts 38 px below the graph's bottom edge.
fftsa.sg_gx      = 8
fftsa.sg_gy      = 0
fftsa.sg_gw      = 784
fftsa.sg_gh      = 312

-- -120 dBV is the floor because the DMM7510's front end sits 12 to 14 dB below the
-- DMM6500's, and at -100 its noise floor was off the bottom of the plot.
fftsa.sg_dbmin   = -120
fftsa.sg_dbmax   = 20
fftsa.sg_vfloor  = 1e-9

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

-- Delete, nil handle or not. These were wrapped in pcall to count a refusal, which
-- cannot happen: the firmware REFUSES BY POSTING AN EVENT and returning, so the wrapper
-- was never false and the counter it fed was dead state. A refused delete still shows up,
-- in the only place it can -- the live-object and live-buffer counts the suite takes
-- around a teardown, and the event log on the instrument.
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

-- Pin the X axis to the window: auto-range rounds outward to tidy tick values, so
-- the pixel of a given frequency would be unknowable and our labels misplaced.
function fftsa.sg_pin_x()
  if fftsa.sg_graph == nil then return false end
  local lo, hi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if hi > fftsa.sg_fmax_real or hi <= lo then return false end
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

function fftsa.sg_xunit_text()
  local t = "X: kHz   Y: dBV"
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

-- The two trace buffers the frame alternates between. WRITABLE_FULL carries value, extra
-- and timestamp per point: UNIT_VOLT holding dB numbers, extra UNIT_HERTZ.
--
-- MADE ONCE, WHEN THE APP STARTS, AND FREED ONLY BY fftsa.sg_destroy() WHEN IT ENDS.
-- Capacity is sg_maxpts -- the ceiling, not the current sg_ncol -- whatever the sample
-- count, so neither a size change nor a change of point count needs a new buffer: this
-- writes sg_nbins and returns. Nothing allocates or frees while frames are running.
--
-- WHY TWO, AND WHY FILL_ONCE. Both were established on the instrument, and each rules
-- out the obvious cheaper design.
--
-- One buffer, overwritten in place, is invisible. The display task keeps its own copy of
-- the readings (FIRMWARE_API.md:246): all 340 points were moved to -20 dBV with the
-- frame parked and the plot area came back byte-identical. Being handed a buffer is what
-- makes the task re-read one, so a frame has to hand one over.
--
-- FILL_CONTINUOUS removes the need to clear, and every mechanical claim about it held --
-- the mode reads back, writing past capacity wraps with no event, n pins at capacity,
-- and after exactly capacity writes startindex is 1 again. It is still unusable here:
-- the widget draws a continuous-fill buffer as a WRAPPING trace and joins its newest
-- point back to its oldest, which on the glass is a straight line across the whole plot.
-- Measured against the alternative explanation -- the bound buffer was read four times
-- while that line was on screen and was perfectly aligned every time, startindex 1,
-- endindex 680, timestamps monotonic -- so the line is the fill mode, not a rotation.
--
-- So: FILL_ONCE, and a frame clears and fills the one the graph is NOT showing before
-- handing it over. The clear is what the firmware needs and it happens where nothing can
-- see it; the bound buffer is always a complete trace and is never written at all.
function fftsa.sg_make_buffer(nbins, npoints)
  fftsa.sg_nbins = nbins
  local want = npoints or fftsa.sg_maxpts
  -- Already built at the right size: keep them, and write nothing but sg_nbins.
  --
  -- An invariant, not a fix: sg_build() is the only caller and start() the only caller
  -- of that, so today this never returns early. It is here because it is the one place
  -- the rule is expressed in code rather than left implicit in the call graph -- proved
  -- by putting an allocation into apply(), which then allocates nothing with this
  -- present and fourteen buffers with it removed.
  if fftsa.sg_buf ~= nil and fftsa.sg_back ~= nil
     and fftsa.sg_buf.capacity == want and fftsa.sg_back.capacity == want then
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
  if fftsa.sg_back ~= nil then
    fftsa.del_buf(fftsa.sg_back)
    fftsa.sg_back = nil
  end
  fftsa.sg_buf  = fftsa.sg_mkbuf(want)
  fftsa.sg_back = nil
  -- The staging arrays sg_update() fills before it clears the buffer. Made here, once,
  -- at the ceiling and never resized: a frame writes slots 1..sg_ncol and reads back the
  -- same, so growing a table mid-frame would allocate inside the window it exists to
  -- shrink. Seeded so every slot is a store rather than a rehash on the first frame.
  fftsa.sg_st_db, fftsa.sg_st_hz = {}, {}
  local j
  for j = 1, want do
    fftsa.sg_st_db[j], fftsa.sg_st_hz[j] = fftsa.sg_dbmin, 0
  end
  return fftsa.sg_buf
end

-- One trace buffer: FILL_ONCE, formatted, seeded full. Capacity is exactly the write
-- count, so a cleared buffer takes a whole frame and no more -- one past it is event
-- 4915. Seeded because an empty buffer binds no trace at all, and sg_build() binds this
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
-- THE TIMESTAMP IS NO LONGER THE X AXIS, so it carries no information -- X is bound to
-- the extra field. It still has to be supplied and still has to increase, because
-- buffer.write.reading documents chronological order, so the slot number serves. What
-- that retires is the scaled-frequency encoding and its hazard: the fractional seconds
-- field is refused above 0.9999999 with event 1131, a modal dialog per offending point,
-- and a frequency landing an ulp below an integer after the divide produced exactly
-- that. An integer count cannot.
function fftsa.sg_write_point(buf, db, f, slot)
  if slot == nil then slot = 1 end
  buffer.write.reading(buf, db, f, slot, 0)
end


-- Build the screen once, at launch: graph, tick labels, peak table, legend. The
-- frame loop only refills the buffer and updates text.
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
  display.graph.add(fftsa.sg_graph, fftsa.sg_buf, display.ELEMENT_DATA, fftsa.sg_buf, display.ELEMENT_EXTRA)
  display.graph.drawstyle(fftsa.sg_graph, display.STYLE_LINE)
  display.graph.scaley(fftsa.sg_graph, display.YSCALE_OFF, display.AXIS_NORMAL,
                       fftsa.sg_dbmin, fftsa.sg_dbmax)
  fftsa.sg_pin_x()

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
  -- Both: a buffer whose handle is dropped is stranded and still counts against the
  -- instrument's capacity.
  if fftsa.sg_buf ~= nil then
    fftsa.del_buf(fftsa.sg_buf)
  end
  if fftsa.sg_back ~= nil then
    fftsa.del_buf(fftsa.sg_back)
  end
  fftsa.sg_buf, fftsa.sg_back = nil, nil
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

-- Refill the trace from fftsa.fft_pwr into the buffer the graph is NOT showing, then
-- hand that buffer over. The clear and the whole fill therefore happen where no paint
-- can see them, and the bound buffer is replaced only by a complete one.
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
  -- modal dialog, and sg_ncol is settable while the app runs. Writing fewer than
  -- capacity is fine now that the buffers are FILL_ONCE and cleared -- n follows the
  -- writes, so the trace simply has that many points. That is what makes sg_ncol a live
  -- knob without reallocating anything: the pair stays at the 680 they were made with.
  local ncol = fftsa.sg_ncol
  local cap  = buf.capacity
  if cap ~= nil and ncol > cap then ncol = cap end
  if ncol == nil or ncol < 2 then ncol = 2 end
  local nwrote = 0
  -- STAGE EVERYTHING FIRST, THEN CLEAR AND WRITE. The buffer is at n = 0 from the clear
  -- until the last write, and a paint landing in that window draws a blank or partial
  -- trace -- that is the flicker. So the window is made as narrow as the firmware allows:
  -- every value is computed into these four preallocated arrays while the buffer still
  -- holds the PREVIOUS complete trace, and the only thing between the clear and a full
  -- buffer is a tight loop of buffer.write.reading.
  --
  -- A point costs about 109 us to produce and 51.6 of that is the write itself, so this
  -- moves rather more than half the work out of the window: about 30 ms down to about
  -- 13 at 255 points. The staging costs four table stores and four loads a point, some
  -- 11 us, so the frame as a whole gets about 3 ms longer -- paid outside the window.
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
    -- is drawn at its column rather than its bin, within 130 Hz at any size, which is
    -- 2 px of a 784 px graph; the peak table still carries the interpolated frequency.
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
  -- No graph call. The clear above is the notify, and the trace stays bound to the
  -- same buffer for the life of the app -- so nothing here can repaint the axes.
  -- The paint. The bound buffer is complete and the next fill has not begun, so this is
  -- the window in which a copy is correct by construction.
  delay(fftsa.sg_yield)
end

-- The one place a zoom touches: the tick pixels are fixed and only the numbers move.
function fftsa.sg_set_xrange(flo_hz, fhi_hz)
  fftsa.sg_flo_hz = flo_hz
  fftsa.sg_fhi_hz = fhi_hz
  if fftsa.sg_xunit ~= nil then
    display.settext(fftsa.sg_xunit, fftsa.sg_xunit_text())
  end
  fftsa.sg_pin_x()
end

-- Re-bind the trace; removeall() first, or add() stacks a duplicate trace.
function fftsa.sg_rebind()
  display.graph.removeall(fftsa.sg_graph)
  display.graph.add(fftsa.sg_graph, fftsa.sg_buf, display.ELEMENT_DATA,
                    fftsa.sg_buf, display.ELEMENT_EXTRA)
  display.graph.drawstyle(fftsa.sg_graph, display.STYLE_LINE)
  display.graph.scaley(fftsa.sg_graph, display.YSCALE_OFF, display.AXIS_NORMAL,
                       fftsa.sg_dbmin, fftsa.sg_dbmax)
  fftsa.sg_pin_x()
end

-- Detach and re-add the trace. Not called by the app; tools/test_tsp.lua exercises it.
function fftsa.sg_bind_min()
  display.graph.removeall(fftsa.sg_graph)
  display.graph.add(fftsa.sg_graph, fftsa.sg_buf, display.ELEMENT_DATA,
                    fftsa.sg_buf, display.ELEMENT_EXTRA)
end

-- Seconds the frame stays blocked after the refill so the display task can paint
-- it. 1706 events mean it is too short.
fftsa.sg_yield = 0.010

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
