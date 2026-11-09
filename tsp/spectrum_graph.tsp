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

-- Peak markers, off by default: a second trace carrying the interpolated frequency and
-- amplitude the peak table reports, so a marker sits where the peak really is, up to half a
-- bin off the column the trace draws. Switching it on rebinds the graph, which repaints the
-- axes, so it only happens on Apply.
fftsa.sg_markers = false
-- Needles, not dots: drawstyle is per graph, so markers on the peak trace would put one
-- on all 255 spectrum points too. Three points a peak -- floor, peak, floor, a pixel
-- either side -- draws a vertical needle with the run between them along the bottom rule.
fftsa.sg_mk_per  = 3       -- points a needle: floor, peak, floor
-- Firmware floor on a reading buffer, event 4920. Ask for less and buffer.make returns
-- nil rather than refusing, so every later call on the handle is a 1138.
fftsa.sg_bufmin  = 10
fftsa.sg_maxpts  = 680

-- Firmware handles, initialised only on the first load: opening the App again re-runs this
-- body and `fftsa = fftsa or {}` keeps the table, so nil-ing a live handle here would strand
-- the previous launch's objects. fftsa.sg_destroy() reclaims them on the next start.
if fftsa.sg_handles_inited == nil then
  fftsa.sg_buf   = nil     -- WRITABLE_FULL buffer holding the spectrum
  fftsa.sg_scr   = nil     -- custom screen
  fftsa.sg_graph = nil     -- OBJ_GRAPH object
  fftsa.sg_pk_f  = nil     -- per-peak frequency text (own field, fixed x)
  fftsa.sg_pk_v  = nil     -- per-peak voltage text  (own field, fixed x)
  fftsa.sg_pk_d  = nil     -- per-peak dB text       (own field, fixed x)
  fftsa.sg_xunit = nil     -- settings line under the peak rows
  fftsa.sg_mk    = nil
  -- The two trace buffers' own global names, which the display task's subscription
  -- resolves against. sg_name_buffers() says why they exist.
  FFTSA_TRACE    = nil
  FFTSA_MARK     = nil
  -- The previous launch's pair, waiting to be released once this launch has its own.
  FFTSA_OLDTRACE = nil
  FFTSA_OLDMARK  = nil
  fftsa.sg_handles_inited = true
end

-- Touch pans and zooms the graph and the widget cannot be told not to: display.setstate
-- answers event 1717 for STATE_DISABLE and STATE_READONLY on a Graph. So a gesture is
-- settled after the fact, and this says how the frequency axis settles -- locked, back onto
-- the span in force, unlocked, the span follows the axis, dB restored either way.
fftsa.sg_lock = true

-- Visible frequency window (Hz): fftsa.dsp_window() hands it to the primitive, which plots
-- only the bins inside it, and fftsa.sg_pin_x() pins the axis to it.
fftsa.sg_flo_hz  = 0
fftsa.sg_fhi_hz  = 1e9

-- The pinned window is the only stable choice: XSCALE_ALL derives the range from the
-- buffer's own timestamps, which move while a frame refills, so a paint landing mid-fill
-- ranges on a partial trace and the axis walks. Any auto-ranging method also fights the view
-- lock, which then writes an axis a second for as long as both are on.
fftsa.sg_xmethod = display.XSCALE_OFF
-- The clear is the only notify compatible with FILL_ONCE. select, scaletrace, drawstyle and
-- re-asserting scalex do all make the task re-read a bound buffer, but each needs it
-- overwritten in place, which needs FILL_CONTINUOUS, which draws the wrap line.


-- Geometry on the 800x480 panel, in object coordinates: those start below the 49-pixel
-- title bar, so a child at y=350 lands on panel row 399. The graph takes the full height
-- above the peak table and the firmware labels the axis inside it, so no row is reserved.
fftsa.sg_gx      = 8
fftsa.sg_gy      = 0
fftsa.sg_gw      = 784
fftsa.sg_gh      = 312

-- The dB axis floor: -120 dBV, and -140 on the 1 V and 0.1 V ranges where the noise goes
-- under it. Measured floors pick both numbers -- a DMM7510 reads -134 dBV on 0.1 V and -129
-- on 1 V, a DMM6500 -123 and -121, which is a trace lying on the bottom edge, and a narrower
-- bin takes the noise down with it, 6 dB at 16384 against 2048 and 9 dB at 32768.
-- fftsa.sg_dbmin_set() is the only thing that moves the floor in force.
fftsa.sg_dbmin_std       = -120
fftsa.sg_dbmin_deep      = -140
fftsa.sg_dbmin_deep_vmax = 1     -- the largest range the deeper floor covers
fftsa.sg_dbmin_deep_n    = 16384 -- the smallest count whose bin needs it on a DMM6500
fftsa.sg_dbmin           = fftsa.sg_dbmin_std   -- the floor in force
fftsa.sg_dbmax           = 20
fftsa.sg_vfloor          = 1e-9

fftsa.model_str = nil        -- localnode.model, read once by fftsa.model_name()

-- Past this, in volts, a reading is not a voltage: the digitizer answers 9.9e+37 beyond the
-- selected range, where the panel shows "Overflow", and a handful of those makes the
-- spectrum an impulse -- flat against the ceiling at every frequency with the real tone
-- buried under its own clipped samples. 15 V clears the largest range this app offers and
-- its headroom while sitting 36 decades under the sentinel, so the test can neither catch a
-- real reading nor miss a sentinel.
fftsa.sg_vmax_real = 15
fftsa.overrange    = false   -- the frame's verdict; the peak table and the THD line read it
fftsa.sg_pk_over   = false   -- whether the dashed table is the one on screen

-- Plotted width in pixels, measured off a panel capture: the vertical grid rules land at
-- x = 100, 168 ... 780, eleven of them 68 px apart. Used to decide when an axis limit can
-- be moved without it showing.
fftsa.sg_plotpx  = 680

-- fftsa.sg_fhi_hz starts at a sentinel meaning "every bin". A span wider than this is
-- not a plottable axis, so sg_pin_x() makes no call until fftsa.apply() narrows it.
fftsa.sg_fmax_real = 1e6

-- Peak table: 6 rows as two columns of three. freq/volt/dB are separate objects at fixed x,
-- so the volt and dB columns do not jitter as the proportional-font frequency text changes
-- width.
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
-- Saturated red FF0000 for the over-range banner, against the panel's pale palette: the one
-- line that is a warning rather than a reading. Decimal, which the display API requires.
fftsa.sg_over_c  = 16711680
fftsa.sg_xunit_c_now = nil   -- the colour the line is actually carrying

-- Distortion and noise, between the graph (ends at sg_gy + sg_gh = 312) and the first
-- peak row (sg_pky = 350). Pale amber, the dB column's colour, since both are levels.
fftsa.sg_thd_x = 8
fftsa.sg_thd_y = 328
fftsa.sg_thd_c = 16769184
fftsa.sg_thd_last = nil      -- the text on screen, so an unchanged line is not rewritten

-- Decimals follow the record length, because a digit is only worth printing once the record
-- is long enough to hold a harmonic in one bin: each doubling halves the bin width and so
-- the power leaking into its neighbours. Gated on the committed sample count, so the line
-- cannot offer a precision the plan in force did not deliver.
fftsa.sg_thd_n3 = 8192     -- samples the third decimal needs
fftsa.sg_thd_n4 = 16384    -- and the fourth

-- The nil test is the point: display.create answers nil on an exhausted pool, and the app
-- module deletes handles it may never have built. No pcall, a refused delete posting an
-- event and returning, so a wrapper can never be false; the suite's live-object counts
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

-- Delete a screen: switch away, let the switch land, then delete. The single owner of that
-- rule, every part of it being necessary.
--
-- display.delete on the screen that is on show bluescreens the instrument at pc=00318FC0,
-- which takes the whole box down -- no ping, no port 80, no port 5025, and a manual power
-- cycle. Switching away is not sufficient on its own, changescreen not waiting, so the
-- delete can still reach a screen the panel is showing. The yield is what makes the switch
-- real, and it is the only part the app controls.
function fftsa.del_scr(h, showscr)
  if h == nil then return true end
  if showscr == nil then showscr = display.SCREEN_HOME end
  display.changescreen(showscr)
  delay(fftsa.sg_scr_yield)
  display.delete(h)
  return true
end

-- The X limits the axis should hold, nil for a span that is not plottable. Shared by
-- sg_pin_x and sg_restore so the moved-or-not test cannot disagree with the pin. Start moves
-- to DC where that is under one pixel, because the firmware steps ticks from the lower limit
-- and a 10 Hz Start on a 50 kHz span would label them +00.01kHz. Conditional, or a real zoom
-- loses its own limits.
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
  -- In hertz and not scaled: the trace is bound as a numeric x-y plot, X from the reading's
  -- extra field, which carries the bin's real frequency, so the limits are the real span and
  -- the firmware labels them itself with an SI prefix. No pcall, the call posting rather
  -- than raising.
  display.graph.scalex(fftsa.sg_graph, m, display.AXIS_NORMAL, lo, hi)
  return true
end

-- The settings line: what Options holds that the axes do not already show, so neither the
-- span nor the dB range is repeated. Written twice per Apply, before the capture and again
-- after, so the rate and bin width it ends up showing are the measured ones.
function fftsa.sg_xunit_text()
  -- Over-range replaces the line rather than appending to it: there is no room for both, and
  -- beside a record the range could not represent the point count and bin width are beside
  -- the point. The trace is left flat against the ceiling, which is what the capture was.
  if fftsa.overrange then return fftsa.sg_overrange_text(fftsa.range) end
  -- Total for the same reason opt_info_text is: apply() builds this line after the hardware
  -- is configured, so a nil count or an unknown range index reads as a gap rather than
  -- aborting the Apply.
  local t = string.format("%d pts   %s   %s", fftsa.n or 0,
                          tostring(fftsa.opt_info_text(fftsa.fs, fftsa.n)),
                          tostring(fftsa.range_labels[fftsa.range_to_idx(fftsa.range)]))
  -- Start 1999 / Stop 2000 is a legal pair and one plotted point at any bin width: the trace
  -- is a dot, five peak rows read ---, and this count is the only thing that says why.
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
  -- Last on the line, and always present: the selection is only useful if its absence
  -- cannot be read as FRONT.
  return t .. fftsa.sg_fps_text() .. "   " .. fftsa.terminal_text()
end

-- The measured rate, or nothing until a window has closed: absent rather than zero, because
-- 0.0 fps on a running analyser reads as a fault. Ahead of the terminal selection, which
-- stays last on the line.
function fftsa.sg_fps_text()
  local f = fftsa.fps
  if f == nil or not (f > 0) then return "" end
  if f < 10 then return string.format("  %.1f fps", f) end
  return string.format("  %.0f fps", f)
end

-- The trace buffer: WRITABLE_FULL carries value, extra and timestamp per point, the value dB
-- under a custom unit and the extra the bin's frequency in hertz. Made once at the sg_maxpts
-- ceiling rather than the current sg_ncol, so nothing reallocates while frames run, and
-- freed only by sg_destroy(). The clear is the notify: the display task holds its own copy
-- and re-reads only when handed a buffer, so overwriting one in place changes nothing.
function fftsa.sg_make_buffer(nbins, npoints)
  fftsa.sg_nbins = nbins
  local want = npoints or fftsa.sg_capacity()
  -- Already built at the right size: keep it, and write nothing but sg_nbins. This is the
  -- one place the no-reallocation rule is stated in code rather than left to the call graph.
  if fftsa.sg_buf ~= nil and fftsa.sg_mk ~= nil and fftsa.sg_buf.capacity == want then
    fftsa.sg_name_buffers()
    fftsa.sg_free_old()
    return fftsa.sg_buf
  end
  -- Allocated before the previous pair is released, and that order is the whole of this: a
  -- trace buffer freed and then reallocated at the same size comes back carrying the freed
  -- one's identity, and the dead launch's trace subscription with it. The graph then paints
  -- a ring nothing feeds -- a picture that never changes however the buffer is rewritten,
  -- with the dB axis relabelled in volts -- while every reading in it reads back correct
  -- from Lua. Measured both ways, and no rebind, clear or rewrite recovers it.
  local newbuf = fftsa.sg_mk_trace(want)
  -- The marker trace, made here with the trace buffer and freed with it whether or not
  -- markers are on: allocating it on the option would allocate while frames are running.
  local mkcap = fftsa.sg_npeak * fftsa.sg_mk_per
  if mkcap < fftsa.sg_bufmin then mkcap = fftsa.sg_bufmin end
  local newmk = fftsa.sg_mk_mark(mkcap)
  -- Detach before deleting: the firmware refuses to delete a buffer still bound to a
  -- graph, so remaking one while attached leaves the old buffer alive and still bound,
  -- and the widget draws both -- a second trace overlaid at the old resolution.
  -- Before the traces go, because their rings go with them.
  fftsa.sg_pix_stop('trace buffers reallocated')
  if fftsa.sg_graph ~= nil then
    display.graph.removeall(fftsa.sg_graph)
  end
  local oldbuf, oldmk = fftsa.sg_buf, fftsa.sg_mk
  fftsa.sg_buf, fftsa.sg_mk = newbuf, newmk
  fftsa.sg_name_buffers()
  if oldbuf ~= nil then fftsa.del_buf(oldbuf) end
  if oldmk ~= nil then fftsa.del_buf(oldmk) end
  fftsa.sg_free_old()
  -- The marker sort's own slots, one more than the peak count because the insertion
  -- writes j+1 before n has grown.
  fftsa.sg_mk_db, fftsa.sg_mk_hz = {}, {}
  local j
  for j = 1, fftsa.sg_npeak + 1 do
    fftsa.sg_mk_db[j], fftsa.sg_mk_hz[j] = fftsa.sg_dbmin, 0
  end
  return fftsa.sg_buf
end

-- A second allocation inside one launch breaks the trace, which is why there is no
-- sg_retrace(): a recovery that replaced the trace buffers on a live graph froze the trace
-- at exactly the frame it fired, on four consecutive launches. An Apply from the panel
-- allocates and rebinds through sg_make_buffer(), so it is already the repair if one is
-- ever needed. The mechanism is not established.

-- The previous launch's trace buffers, released only once this launch has allocated its own.
-- sg_make_buffer says what goes wrong when they are freed first, and this is the other half
-- of it: the launch that ends cannot allocate the next launch's buffers, so it cannot free
-- its own in the right order.
--
-- Buffers can be handed across a launch where display handles cannot -- a reading buffer
-- outlives the script that made it, and a display handle answers 1703 -- so a global is the
-- right place for them. An exit never followed by another launch costs 698 readings held
-- until a power cycle.
function fftsa.sg_free_old()
  if FFTSA_OLDTRACE ~= nil then
    fftsa.del_buf(FFTSA_OLDTRACE)
    FFTSA_OLDTRACE = nil
  end
  if FFTSA_OLDMARK ~= nil then
    fftsa.del_buf(FFTSA_OLDMARK)
    FFTSA_OLDMARK = nil
  end
  return true
end

-- A name for each trace buffer, because a table field is not one.
--
-- display.graph.add does not hand the display task a buffer, it subscribes that task to the
-- buffer by name -- graph_trace_add calls bufsub_subscribe(0x407F, graph, name, slot) with
-- two 32-byte name fields -- and a null name means defbuffer1. The axis unit comes from the
-- subscription rather than the add arguments, so a trace that resolved to the wrong buffer
-- is a blank plot with the dB axis relabelled in volts, while the buffer itself still reads
-- back the right points from Lua. A buffer reachable only through fftsa.* does not reliably
-- resolve to itself: a graph bound to a ramp held in fftsa.ZZ painted the app's own spectrum
-- instead. So these two names are part of the display contract.
function fftsa.sg_name_buffers()
  return FFTSA_TRACE == fftsa.sg_buf and FFTSA_MARK == fftsa.sg_mk
end

-- A trace buffer is created into its own bare global, which is not a style choice: a buffer
-- the display task cannot name is subscribed as defbuffer1 instead, the documented null-name
-- default. The graph then draws defbuffer1's contents on defbuffer1's units -- volts on the
-- value axis, kilovolts on an axis that should read kilohertz, nothing recognisable plotted
-- -- while the app's own buffer reads back perfectly from Lua. Two "Reading buffer
-- defbuffer1 is 0% filled" events are all the firmware says about it.
--
-- Every buffer that binds and paints on this instrument is assigned to a bare global, and
-- ones held only in fftsa.sg_buf do not. So these two functions are the only places a trace
-- buffer may be created, the globals are the authority, and fftsa.sg_buf and fftsa.sg_mk are
-- copies for the frame path. Two functions with a literal global each rather than one taking
-- a name, because assigning through _G may not be the same thing to the firmware.
function fftsa.sg_mk_trace(want)
  FFTSA_TRACE = buffer.make(want, buffer.STYLE_WRITABLE_FULL)
  return fftsa.sg_fmt_seed(FFTSA_TRACE, want)
end

function fftsa.sg_mk_mark(want)
  FFTSA_MARK = buffer.make(want, buffer.STYLE_WRITABLE_FULL)
  return fftsa.sg_fmt_seed(FFTSA_MARK, want)
end

-- The format and the seed, shared by the two above. Capacity is sg_maxpts, so a frame
-- writing sg_ncol points always fits and fftsa.dsp_live() clamps a raised sg_ncol to it --
-- one write past capacity is event 4915. Seeded because an empty buffer binds no trace at
-- all, and sg_build() binds this before the first frame has run.
function fftsa.sg_fmt_seed(b, want)
  if b == nil then return nil end
  -- FILL_ONCE unless fftsa.sg_ring is on, where the wrap line is accepted and parked under
  -- the plot by the two sentinels sg_fill writes. Set before the seed so the seed itself
  -- lays down one full lap and leaves the cursor back at slot 1.
  if fftsa.sg_ring then b.fillmode = buffer.FILL_CONTINUOUS end
  --
  -- A custom unit is how the axis gets to say decibels; without it the labels read "+020.0V"
  -- on numbers that are not volts. Not buffer.UNIT_DECIBEL, which panics the instrument
  -- during build. The firmware truncates a custom label to two characters (event 4933).
  buffer.unit(buffer.UNIT_CUSTOM1, "dB")
  buffer.write.format(b, buffer.UNIT_CUSTOM1, buffer.DIGITS_4_5,
                         buffer.UNIT_HERTZ,   buffer.DIGITS_6_5)
  -- The seed has to sit inside the axes the graph is pinned to, being the geometry the widget
  -- draws at the first paint of every launch. X across the plotted span and not 0..want-1,
  -- the X axis being bound to the frequency in the extra field: a counter puts every point
  -- in the leftmost half-percent of the plot with the first ten below the axis minimum. Y a
  -- small ramp rather than one repeated value, or the trace has a bounding box of zero
  -- height; sg_seed_spread is 2 dB, about three pixels on an axis 140 dB tall.
  local k, span = nil, want - 1
  if span < 1 then span = 1 end
  -- sg_flo_hz and sg_fhi_hz are 0 and 1e9 until the first sg_store_xrange, and those are
  -- values rather than nil, so an `or` chain never falls through them. sg_build() runs before
  -- apply() commits the span, so on the first build of a power cycle they are still the
  -- sentinels -- which seeds X across a billion hertz onto an axis pinned to 50 kHz. A stop
  -- above the fastest rate's Nyquist is the tell, no span being able to ask for one.
  local flo, fhi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if flo == nil or fhi == nil or fhi > fftsa.sg_fmax_real then
    flo, fhi = fftsa.flo, fftsa.fhi
  end
  if flo == nil or fhi == nil or not (fhi > flo) then
    flo, fhi = fftsa.flomin, fftsa.fhi_min
  end
  -- No sentinels here, however the ring is set: the seed is the geometry the widget draws
  -- at the first paint of a launch, before sg_bind pins anything, and a point 1000 dB
  -- under the floor makes that first box 1002 dB tall. The first pass writes the real
  -- sentinels a frame later, by which time both axes are pinned.
  for k = 1, want do
    local t = (k - 1) / span
    fftsa.sg_write_point(b, fftsa.sg_dbmin + fftsa.sg_seed_spread * t,
                         flo + (fhi - flo) * t, k)
  end
  return b
end

-- One point: value dB, extra the bin's frequency in Hz, timestamp a plain counter. The
-- timestamp carries nothing, X being bound to the extra field, but buffer.write.reading
-- documents chronological order so it still has to increase. The slot number serves, and as
-- an integer cannot reach the fractional-seconds refusal at 0.9999999 (event 1131, a modal
-- dialog per point).
function fftsa.sg_write_point(buf, db, f, slot)
  if slot == nil then slot = 1 end
  buffer.write.reading(buf, db, f, slot, 0)
end


-- The fill window, and the ring that removes it.
--
-- FILL_ONCE must be cleared before it is refilled, so the bound buffer holds fewer than
-- sg_ncol points for the length of the fill: 20.75 ms of a 105 ms frame at 255 points. An
-- append blocks Lua for ~80 us and that is the only time the display task runs, so the task
-- gets sg_ncol chances to paint inside the window, and a paint landing there draws a
-- truncated trace. That is the flicker, at about fps * window / period.
--
-- The ring is never partially populated, so a mid-pass paint draws this frame mixed with
-- the last -- a tear, not a dropout. Capacity equals the points a pass writes, so the
-- cursor returns to slot 1 every pass and startindex/endindex are stationary. That is the
-- difference from the ring that was tried and abandoned, which wrote 255 to 340 points into
-- a 680 ring and moved the extent every frame.
--
-- The cost would be the wrap seam: the widget joins newest to oldest, which in frequency
-- order is the two ends of the axis -- a line across the whole plot, drawn whenever the
-- cursor is mid-pass, so it flickers at exactly the rate the dropout used to. 8.40 tried
-- parking it below the axis floor and the widget CLAMPS rather than clips: it came out as a
-- green line along the bottom rule, measured on the glass.
--
-- So the pass folds back on itself instead. Ascending flo..fhi, then descending fhi..flo:
-- the join at the fold is the same point twice and so is the wrap, both zero length, and
-- every edge is drawn twice in opposite directions. There is no seam at any cursor
-- position, and the picture is exactly the spectrum. It costs twice the appends.
-- Every count, and a sample count threshold was tried and removed. The arithmetic said the
-- dropout should fade at the long counts, the fill window being 20 ms of a 420 ms frame at
-- 32768 against 20 of 105 at 2048 -- so 8.42 used the ring below 4096 only. On the glass
-- 8192, 16384 and 32768 all still flickered plainly. The rate argument counts dropouts and
-- ignores how long each one is on the glass: a truncated paint stays up until the next
-- paint, which at 1.8 fps is about half a second rather than 70 ms, so a low frame rate
-- makes a dropout more visible and not less. The ring costs 1.8 fps against 2.4 at 32768
-- and that is the price of no flicker anywhere.
--
-- The switch stays because it is the revert: FILL_ONCE is still the shipped behaviour of
-- every build before 8.41, the suite covers both branches, and no other instrument has run
-- the ring yet.
fftsa.sg_ring  = true
fftsa.sg_stamp = 0       -- ring timestamps, monotonic across passes

-- Capacity a ring needs: the spectrum plus one sentinel at each end. Capacity must equal
-- the writes a pass makes or the cursor walks, so this is the one place that decides it and
-- sg_make_buffer asks here rather than using sg_maxpts.
-- One pass writes exactly capacity, so capacity is the points a pass writes.
--
-- WHAT DRAWS A LINE IS THE JOIN BETWEEN CONSECUTIVE PASSES, not the trace closing on itself.
-- The display task keeps its own ring of 720 records and accumulates into it across frames,
-- so a pass that always runs flo -> fhi leaves a fhi -> flo step at every frame boundary
-- inside that ring and the widget draws it. setfill(g, 0) does not affect it, and an
-- unconditional closure would draw every frame rather than alternate ones.
--
-- So each pass has to END where the next one BEGINS. A fold does that by running up the band
-- and back down, at twice the appends; ALTERNATING THE DIRECTION of each pass does it at one
-- lap. A descending pass traverses the same curve backwards, so the picture and the trace
-- extent are unchanged.
--
-- ALTERNATING DIRECTION CANNOT BE USED, and the reason is the one that matters for every
-- future change here: EVERY SLOT MUST ALWAYS HOLD THE SAME FREQUENCY.
--
-- The display task paints during every append, so a paint lands part-way through a pass with
-- some slots holding this pass and the rest the previous one. That is invisible only while
-- slot i carries the same x value in both -- then the two passes differ in dB alone and the
-- picture is a blend of two spectra at the same frequencies. A fold satisfies it: slot i is
-- hz[i] going up and hz[cap+1-i] coming back, every pass alike. Alternating the direction
-- does not: slot i is hz[i] on one pass and hz[room+1-i] on the next, so a mid-pass paint
-- holds two different frequencies per slot and the curve doubles back. Measured on the glass
-- as a double curve on alternate frames, at every sample count.
--
-- This is also why the ring removed the flicker that FILL_ONCE had: not because the buffer is
-- never empty, but because a partial update is indistinguishable from a complete one.
--
-- Do not test any of this with a straight-line spectrum: a ramp's join is collinear with the
-- ramp, so it is invisible and an always-ascending pass looks clean when it is not.
fftsa.sg_fold = true

-- Which way the next one-lap pass runs. Flipped by sg_fill and read nowhere else.
fftsa.sg_up = true

-- The pixel fill, which draws a pass by writing the display task's own records instead of
-- appending to the buffer: 9.6 ms measured for a 510-record block against 39 ms of appends.
-- fftsa.nl.px_try carries all of it and says what it costs.
--
-- THE APPEND PATH STAYS AS THE FALLBACK, and that is the whole shape of this. Nothing is
-- removed: the fill below is what every build before this one shipped and what runs whenever
-- the pixel path has not engaged, has been switched off, or has refused a frame. The pixel
-- path is only ever a replacement for a fill it has already proved it can do.
--
-- Off by default. The ring the writes go into is found at runtime and the one unrecoverable
-- outcome is writing into something that is not it, so the switch exists to be turned on
-- deliberately -- from the socket, from a build that has been through the gates on the glass.
fftsa.sg_pix = false

-- The pixel path's two halves, and why they sit on opposite sides of the fill.
--
-- DRAWING replaces the fill, so it comes first and returns the points drawn. SEEKING needs the
-- ring to hold THIS frame's decibels -- the needle is db[1], and the only thing that puts it
-- into the ring is the append fill -- so it comes last. A search run before the fill would be
-- matching this frame's needle against last frame's records and would never find anything.
--
-- Both are inside pcall. A raise anywhere in the pixel path costs the fallback for the rest of
-- the session and not the frame: sg_fill carries on and appends, as it did before.
function fftsa.sg_pix_draw(db, hz, nseg, tb)
  local nl = fftsa.nl
  if nl == nil or nl.px == nil or nl.px.state ~= 'on' then return nil end
  -- One timestamp, reserved before the append that uses it, for the same reason the fill
  -- reserves its whole range first: a write below a timestamp already in the ring raises event
  -- 4924 as a modal dialog over the app, which also makes the control socket refuse every
  -- statement, so the state that caused it cannot be read back either.
  local t = (fftsa.sg_stamp or 0) + 1
  fftsa.sg_stamp = t
  local ok, n = pcall(nl.px_frame, db, hz, nseg, tb, t)
  if not ok then
    nl.px_off('px_frame raised: ' .. tostring(n))
    return nil
  end
  return n
end

function fftsa.sg_pix_arm(db, hz, nseg, tb)
  local nl = fftsa.nl
  if nl == nil or nl.px == nil then return end
  local st = nl.px.state
  if st == 'on' or st == 'off' then return end
  local t = (fftsa.sg_stamp or 0) + 1
  fftsa.sg_stamp = t
  local ok, err = pcall(nl.px_try, db, hz, nseg, tb, t)
  if not ok then nl.px_off('px_try raised: ' .. tostring(err)) end
end

-- Back to appends, and the one call that must never be missed.
--
-- The ring is the display task's allocation for a TRACE OBJECT. Freeing that object frees the
-- ring, and a frame that then writes 40 KB into it is writing into the heap's free list --
-- which is how 0x318FC0, PegRect::operator& on a freed widget, is reached. So every place that
-- removes a trace or replaces a trace buffer calls this, before it does so.
function fftsa.sg_pix_stop(why)
  local nl = fftsa.nl
  if nl == nil or nl.px == nil or nl.px_restart == nil then return end
  if nl.px.state == 'off' then return end
  nl.px_restart(why)
end

function fftsa.sg_ring_cap(ncol)
  local n = ncol or fftsa.sg_ncol
  if fftsa.sg_fold then return 2 * n end
  return n
end

-- The trace buffer's capacity, and the one thing the ring costs. FILL_ONCE takes the
-- sg_maxpts ceiling, which is what lets sg_ncol be raised and lowered while frames run
-- without reallocating. A ring cannot: capacity has to equal the points a pass writes, so
-- under the ring a changed sg_ncol needs a reallocation, and the only safe place for one
-- is Apply -- replacing the trace buffers on a live graph freezes the trace.
-- The same capacity in both modes. The ring needs capacity to equal the points a pass
-- writes; FILL_ONCE does not care that capacity exceeds what it writes. Keeping them equal
-- is what lets fftsa.sg_ring be flipped without a new buffer -- a reallocation on a live
-- graph freezes the trace at the frame it fires, which is the one thing neither mode may do.
function fftsa.sg_capacity()
  return fftsa.sg_ring_cap()
end



-- The most points a frame may plot, which is half the capacity under the ring: the pass
-- writes each point twice. fftsa.dsp_live() clamps to this, so the primitive is asked for a
-- count the fill can write without clamping it again -- a second clamp is how the trace and
-- the primitive come to disagree.
function fftsa.sg_points_max(buf)
  local b = buf or fftsa.sg_buf
  if b == nil then return fftsa.sg_maxpts end
  -- A folded pass spends half its capacity on the return lap; a one-lap pass spends none.
  if fftsa.sg_ring and fftsa.sg_fold then return math.floor(b.capacity / 2) end
  return b.capacity
end

-- The frame's trace write, both modes. Returns the points written, sentinels excluded.
--
-- THE RING NEEDS THE COMPILED PATH. fftsa.spectrum_interp writes the trace through
-- dsp.spectrum, which clears sg_buf itself before filling it, and a clear resets the ring
-- cursor -- leaving the buffer part full and the seam sweeping. That path cannot produce a
-- spectrum in this archive anyway (no dsp.spectrum, so the frame halts and says so), which
-- is what makes the ring safe here rather than a second thing to get right.
function fftsa.sg_fill(db, hz, nseg)
  local wr = buffer.write.reading
  local tb = fftsa.sg_buf
  local i
  if tb == nil or nseg == nil or nseg < 1 then return 0 end
  if not fftsa.sg_ring then
    tb.clear()
    for i = 1, nseg do
      wr(tb, db[i], hz[i], i, 0)
    end
    return nseg
  end
  -- Timestamps keep climbing across passes, because the slot being overwritten holds an
  -- older one and buffer.write.reading documents chronological order. Integers, so they
  -- cannot reach the 0.9999999 fractional refusal.
  -- Exactly capacity points, always, or the cursor walks and the fold stops landing on
  -- itself. Up the band then back down it, so both joins are a point repeated. A short
  -- spectrum repeats its last point to fill the lap -- duplicates are zero-length edges and
  -- draw nothing -- and a long one is clamped.
  -- The pixel path, when it has engaged: one memwrite and one append in place of the pass
  -- below. nil means it has not engaged, or refused this frame, and the fill runs.
  if fftsa.sg_pix then
    local n = fftsa.sg_pix_draw(db, hz, nseg, tb)
    if n ~= nil then return n end
  end
  local cap = tb.capacity
  local room = cap
  if fftsa.sg_fold then room = math.floor(cap / 2) end
  if nseg > room then nseg = room end
  local t = fftsa.sg_stamp
  -- THE RANGE IS RESERVED BEFORE THE FIRST WRITE, not recorded after the last.
  --
  -- A fill that does not finish otherwise leaves sg_stamp BEHIND timestamps that are already
  -- in the ring, and every frame after it then rewrites a lower one. The firmware answers that
  -- with event 4924, "Time in a 'writable' reading buffer cannot reverse", as a MODAL DIALOG
  -- over the running app -- which also makes the control socket refuse every statement with "a
  -- command from another interface is running", so the state that caused it cannot be read
  -- back either. Measured 2026-11-09 after a socket ABORT cut a fill in half: the app drew
  -- nothing further and needed an injected EXIT press to clear the dialog.
  --
  -- Reserving first costs a gap in the timestamps whenever a fill is cut short. A gap is
  -- harmless -- the widget reads the values, and buffer.write.reading only requires that time
  -- does not go backwards.
  local used = room
  if fftsa.sg_fold then used = 2 * room end
  fftsa.sg_stamp = t + used
  local last = nseg
  -- One lap, alternating direction, so this pass ends where the next one begins and the join
  -- between them is a repeated point rather than a step across the whole band.
  if not fftsa.sg_fold then
    local i
    if fftsa.sg_up then
      for i = 1, room do
        local j = i
        if j > last then j = last end
        wr(tb, db[j], hz[j], t + i, 0)
      end
    else
      for i = 1, room do
        local j = room + 1 - i
        if j > last then j = last end
        wr(tb, db[j], hz[j], t + i, 0)
      end
    end
    fftsa.sg_up = not fftsa.sg_up
    if fftsa.sg_pix then fftsa.sg_pix_arm(db, hz, nseg, tb) end
    return nseg
  end
  for i = 1, room do
    local j = i
    if j > last then j = last end
    wr(tb, db[j], hz[j], t + i, 0)
  end
  for i = 1, room do
    local j = room + 1 - i
    if j > last then j = last end
    wr(tb, db[j], hz[j], t + room + i, 0)
  end
  -- The search, with the records this pass has just written. See sg_pix_arm for why it is here
  -- and not above the fill.
  if fftsa.sg_pix then fftsa.sg_pix_arm(db, hz, nseg, tb) end
  return nseg
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
  -- Without this test every child is built against a nil parent, which does raise, in this
  -- code rather than the firmware's. fftsa.build() passes the reason to fftsa.start().
  if fftsa.sg_scr == nil then
    fftsa.lasterr = "OBJPOOL exhausted building the spectrum screen"
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

  fftsa.sg_thd_last = nil
  fftsa.sg_thd = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_thd_x, fftsa.sg_thd_y,
                        fftsa.sg_thd_text(nil, nil, nil), fftsa.sg_thd_c, small, display.JUST_LEFT)

  fftsa.sg_xunit = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_xunit_x, fftsa.sg_xunit_y,
                          fftsa.sg_xunit_text(), fftsa.sg_xunit_c, small, display.JUST_LEFT)

  return fftsa.sg_scr
end

-- Tear down in dependency order: detach the trace, drop the screen and its
-- children, then free the buffer the trace referenced. Nils every handle.
function fftsa.sg_destroy(release)
  fftsa.sg_pix_stop('screen destroyed')
  if fftsa.sg_graph ~= nil then
    display.graph.removeall(fftsa.sg_graph)
  end
  fftsa.del_scr(fftsa.sg_scr)
  fftsa.sg_scr, fftsa.sg_graph, fftsa.sg_pk_f, fftsa.sg_pk_v, fftsa.sg_pk_d,
    fftsa.sg_xunit, fftsa.sg_thd = nil, nil, nil, nil, nil, nil, nil
  -- Two callers want opposite things here, so release says which.
  --
  -- Releasing is what an exit does: the buffers go, and defbuffer1 is made current first,
  -- because the front panel adopts a user buffer as its current one -- an app that exits
  -- leaving FFTSA_MARK alive leaves the home screen showing a spectrum level in dB as though
  -- it were a measurement. That restore needs a yield before the delete, for the same reason
  -- fftsa.del_scr does: the panel picks up the new current buffer on its own schedule and
  -- not on the return of dmm.digitize.read, and deleting a buffer it is still reading is
  -- pc=00318FC0.
  --
  -- Not releasing is what sg_build() does on a relaunch: the pair is handed on in
  -- FFTSA_OLDTRACE and FFTSA_OLDMARK for sg_free_old() to take once the new pair exists,
  -- because freeing them first lets the new pair be allocated over them and inherit this
  -- launch's trace subscription. Handed over only when there is something to hand over,
  -- sg_destroy running twice on a relaunch.
  if release then
    fftsa.sg_restore_defbuffer()
    delay(fftsa.sg_scr_yield)
    fftsa.sg_drop_buffers()
  else
    if fftsa.sg_buf ~= nil then FFTSA_OLDTRACE = fftsa.sg_buf end
    if fftsa.sg_mk ~= nil then FFTSA_OLDMARK = fftsa.sg_mk end
    FFTSA_TRACE, FFTSA_MARK = nil, nil
  end
  fftsa.sg_buf, fftsa.sg_mk = nil, nil
  collectgarbage()
end

-- Make defbuffer1 the instrument's current buffer again. One reading into it is what names
-- it: the panel follows the buffer last used, and nothing else in the API points it. One
-- sample, this being a teardown. Guarded, and its failure must not stop the deletes below
-- it -- a panel left on the wrong buffer is untidy, a buffer left allocated is a leak.
--
-- Both guards below are events seen on the glass rather than caution. Measure and digitize
-- are exclusive -- setting the function of one sets the other's to None, and the idle one
-- reads FUNC_NONE -- and the firmware posts rather than raising when that is ignored, so a
-- pcall catches neither:
--
--   2800  the count attribute is not available for the DC voltage function
--   2801  DMM cannot measure when digitize function is set to None
--
-- Both arrive, in that order, on the first launch of a power cycle: fftsa.start() opens with
-- fftsa.stop(), which lands here before any digitize function is set, and a cold instrument
-- sits on measure DC voltage.
function fftsa.sg_restore_defbuffer()
  -- Nothing of this app's can be current if it never made any, which is that cold start.
  -- Skipping leaves the digitizer alone: a teardown on the way into a launch must not be
  -- the thing that configures the instrument.
  if FFTSA_TRACE == nil and FFTSA_MARK == nil and FFTSA_OLDTRACE == nil
     and FFTSA_OLDMARK == nil and fftsa.cap == nil then
    fftsa.sg_defbuf_ok = nil
    return false
  end
  -- Whichever side is live. The app's own exit is the digitize branch; the measure branch is
  -- for an exit after the panel has been moved to a measure function under the app.
  local ok = false
  if dmm.digitize.func ~= dmm.FUNC_NONE then
    ok = pcall(function()
      dmm.digitize.count = 1
      dmm.digitize.read(defbuffer1)
    end)
  elseif dmm.measure.func ~= dmm.FUNC_NONE then
    ok = pcall(function() dmm.measure.read(defbuffer1) end)
  end
  -- Not into fftsa.lasterr: a teardown runs inside fftsa.start_failed(), which has just put
  -- the reason the start failed there and the panel shows it, so a note about the current
  -- buffer would replace the one thing worth reading. Its own field, so a socket can ask.
  fftsa.sg_defbuf_ok = ok
  return ok
end

-- Delete both trace buffers and every global naming them, in the order that leaves nothing
-- dangling. Through the globals, because buffer.delete nils the variable it is handed:
-- deleting through a local or a table field clears that one reference and leaves the others
-- pointing at a buffer that is gone, so a second delete through one of those is a double.
function fftsa.sg_drop_buffers()
  if FFTSA_MARK ~= nil then pcall(function() buffer.delete(FFTSA_MARK) end) end
  if FFTSA_TRACE ~= nil then pcall(function() buffer.delete(FFTSA_TRACE) end) end
  if FFTSA_OLDMARK ~= nil then pcall(function() buffer.delete(FFTSA_OLDMARK) end) end
  if FFTSA_OLDTRACE ~= nil then pcall(function() buffer.delete(FFTSA_OLDTRACE) end) end
  FFTSA_TRACE, FFTSA_MARK = nil, nil
  FFTSA_OLDTRACE, FFTSA_OLDMARK = nil, nil
  return true
end


-- Bin index range covering the visible window, clamped into 1..nbins, and shared by the plot
-- and the peak search so the table describes what is on screen.
--
-- The single owner of the ceil/floor convention: the peak search, the noise pass and the
-- "only N bins in the span" line all need it, and a second copy is free to round the other
-- way -- one bin of disagreement in exactly that message. flo/fhi default to the window the
-- display has stored, and dsp.* passes its own span instead, so the primitives never write
-- a display field to make this read the right one.
function fftsa.sg_window_bins(nbins, binhz, flo, fhi)
  if binhz == nil or binhz <= 0 then return 1, nbins end
  if flo == nil then flo = fftsa.sg_flo_hz end
  if fhi == nil then fhi = fftsa.sg_fhi_hz end
  local floor, ceil = math.floor, math.ceil
  -- ceil, not floor, for the low edge: floor() maps every start below one bin
  -- width (195 Hz at 100 kS/s) back to bin 1, the DC bin.
  local kmin = ceil(flo / binhz) + 1
  local kmax = floor(fhi / binhz) + 1
  if kmin < 1 then kmin = 1 end
  if kmin > nbins then kmin = nbins end
  if kmax > nbins then kmax = nbins end
  if kmax < kmin then kmax = kmin end
  return kmin, kmax
end

-- The settings line, written so a raise cannot escape: everything it describes is committed
-- before it is built, and both writers sit inside apply() after the hardware is configured,
-- so a failure here is a stale line that says so in fftsa.lasterr rather than an Apply that
-- reports failure over cosmetics. The one place that writes the line. Not on the frame path
-- -- twice an Apply and once a gesture -- so a closure per call is affordable.
function fftsa.sg_write_xunit()
  if fftsa.sg_xunit == nil then return false end
  local ok, err = pcall(function()
    -- The colour belongs with the text, in the one place that writes the line, over-range
    -- being a warning. Written only when it changes, like the text: the over-range
    -- transition brings this here from the tick, where a setcolor a second would be waste.
    local c = fftsa.sg_xunit_c
    if fftsa.overrange then c = fftsa.sg_over_c end
    if c ~= fftsa.sg_xunit_c_now then
      fftsa.sg_xunit_c_now = c
      display.setcolor(fftsa.sg_xunit, c)
    end
    display.settext(fftsa.sg_xunit, fftsa.sg_xunit_text())
  end)
  if not ok then
    -- Every input, not just the message: a "bad argument #2 to format (string expected, got
    -- nil)" here has never been reproduced or explained, the call it names being unable to
    -- return nil for any value this records. If it recurs, the values come with it.
    fftsa.lasterr = string.format(
      "settings line: %s [n=%s fs=%s fs_acq=%s range=%s rangetxt=%s win=%s "
      .. "binhz=%s nbins=%s term=%s]", tostring(err), tostring(fftsa.n), tostring(fftsa.fs),
      tostring(fftsa.fs_acq), tostring(fftsa.range),
      tostring(fftsa.range_labels[fftsa.range_to_idx(fftsa.range)]), tostring(fftsa.win_i),
      tostring(fftsa.binhz), tostring(fftsa.sg_nbins), tostring(fftsa.terminal_text()))
  end
  return ok
end

-- The window and the settings line, without the pin. Split out for the one caller that must
-- not pin: an adopted gesture about to re-plan has fftsa.apply() pinning from the same pair
-- a moment later, and an axis write is 60 ms.
function fftsa.sg_store_xrange(flo_hz, fhi_hz)
  fftsa.sg_flo_hz = flo_hz
  fftsa.sg_fhi_hz = fhi_hz
  fftsa.sg_write_xunit()
end

-- "---", not a number, for anything unmeasured: 0.00% reads as a clean signal where no
-- harmonic in the window means no figure at all. dBV, as the peak table's dB column. n is
-- the sample count, and it chooses the THD decimal count and nothing else.
function fftsa.sg_thd_text(thd, snr, ndb, n, over)
  local t, s
  -- Over-range first, and dashed rather than named: every figure here would be arithmetic
  -- about 9.9e+37 instead of about volts, and NoSig is the opposite diagnosis. The floor
  -- goes too, being the one figure otherwise printed unclamped.
  if over then
    t, s, ndb = "THD: ---", "S/N: ---", nil
  -- Neither ratio means there is no fundamental to take them against, which is what a
  -- shorted input looks like. Named rather than dashed, and the labels stay.
  elseif thd == nil and snr == nil then
    t, s = "THD: NoSig", "S/N: NoSig"
  else
    if thd == nil then t = "THD: ---"
    -- thd == thd is the NaN test: this firmware's >= is true for a NaN, so the branches
    -- below would print "nan%" rather than the dashes that mean "not measured".
    elseif thd ~= thd then t = "THD: ---"
    -- Past 100% -- a clipped input -- any decimal is a digit of noise.
    elseif thd >= 100 then t = string.format("THD: %.0f%%", thd)
    -- Longest record first. A missing count takes the short form: it is the one that cannot
    -- overstate the plan.
    elseif n ~= nil and n >= fftsa.sg_thd_n4 then t = string.format("THD: %.4f%%", thd)
    elseif n ~= nil and n >= fftsa.sg_thd_n3 then t = string.format("THD: %.3f%%", thd)
    else t = string.format("THD: %.2f%%", thd) end
    if snr == nil or snr ~= snr then s = "S/N: --- dB"
    else s = string.format("S/N: %.1f dB", snr) end
  end
  if ndb == nil or ndb ~= ndb then return t .. "    " .. s .. "    Noise Floor: --- dBV" end
  return t .. "    " .. s .. string.format("    Noise Floor: %.1f dBV", ndb)
end

-- Written only when the text changes, like the terminal selection, and on the peak table's
-- clock rather than the frame. The figures come from the primitive that produced the
-- spectrum on screen, over the bins it reduced, and it reports thd as a fraction where this
-- line prints a percentage. Through fftsa.distortion() and fftsa.plan_n(), which pick the
-- live path: asking dsp.* directly would describe a transform the native path never ran.
function fftsa.sg_show_thd()
  if fftsa.sg_thd == nil then return false end
  local thd, snr, ndb = fftsa.distortion()
  if thd ~= nil then thd = thd * 100 end
  local t = fftsa.sg_thd_text(thd, snr, ndb, fftsa.plan_n(), fftsa.overrange)
  if t == fftsa.sg_thd_last then return false end
  fftsa.sg_thd_last = t
  display.settext(fftsa.sg_thd, t)
  return true
end

-- The one place a zoom touches: it stores the window, rewrites the settings line and
-- re-pins the axis, which is what makes the firmware relabel.
function fftsa.sg_set_xrange(flo_hz, fhi_hz)
  fftsa.sg_store_xrange(flo_hz, fhi_hz)
  fftsa.sg_pin_x()
end

-- Bind the traces: the spectrum always, the markers when they are switched on. The one
-- place that decides, so the build and a rebind cannot disagree about what is bound.
--
-- removeall() first, or add() stacks a duplicate trace.
function fftsa.sg_bind()
  local g = fftsa.sg_graph
  if g == nil then return false end
  -- removeall frees the trace objects, and the display task's record ring with them. Anything
  -- still holding that address would be writing 40 KB into the free list.
  fftsa.sg_pix_stop('traces rebound')
  display.graph.removeall(g)
  display.graph.add(g, fftsa.sg_buf, display.ELEMENT_DATA,
                    fftsa.sg_buf, display.ELEMENT_EXTRA)
  if fftsa.sg_markers and fftsa.sg_mk ~= nil then
    display.graph.add(g, fftsa.sg_mk, display.ELEMENT_DATA,
                      fftsa.sg_mk, display.ELEMENT_EXTRA)
    -- One scale for every trace. A custom graph starts at TRACE_ACTIVE, where a scale
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
  fftsa.sg_hook_scale()
  return true
end

-- Did the capture hold a reading the range cannot represent? From the statistics the firmware
-- maintains as the buffer fills, so getstats hands back an already-current table and this is
-- one call a frame rather than 16,384 comparisons in Lua. Both ends tested, because a clipped
-- sine saturates symmetrically and -9.9e+37 is as much a sentinel as +9.9e+37. n == 0 leaves
-- every other field nil, which is an empty buffer and not an over-range one.
function fftsa.cap_overrange(buf)
  if buf == nil then return false end
  -- Guarded because this runs inside the frame: a firmware without getstats would raise on
  -- every frame and the twenty-failure halt would take the app down over a warning it cannot
  -- offer. Answering false loses the detection and nothing else.
  if buffer.getstats == nil then return false end
  local st = buffer.getstats(buf)
  if st == nil or st.n == nil or st.n == 0 then return false end
  local lim = fftsa.sg_vmax_real
  if st.max ~= nil and st.max.reading ~= nil and st.max.reading > lim then return true end
  if st.min ~= nil and st.min.reading ~= nil and st.min.reading < -lim then return true end
  return false
end

-- What the settings line says instead when the capture held an unrepresentable reading. The
-- wording is deliberate: only the peaks of a signal a little past the range are clipped and
-- the rest of the record is real, so this is neither "no signal" nor "the signal is 9.9e+37".
function fftsa.sg_overrange_text(range)
  local i = fftsa.range_to_idx(range)
  local lab = tostring(fftsa.range_labels[i])
  -- The advice has to be possible: on the largest range there is nothing to raise to, and
  -- telling an operator to raise it there sends them to a form that cannot help.
  local fix = "raise the range"
  if i >= table.getn(fftsa.ranges) then fix = "reduce the input" end
  return "OVERRANGE: values in the signal exceed the " .. lab .. " range -- " .. fix
end

-- The peak table under over-range: every row dashed, written once per transition rather than
-- per frame, because every figure would be arithmetic about 9.9e+37 and a plausible-looking
-- number is worse than a dash. sg_show_peaks clears the latch on the way back.
function fftsa.sg_show_peaks_over()
  if fftsa.sg_pk_over then return false end
  if fftsa.sg_pk_f == nil then return false end
  fftsa.sg_pk_over = true
  local p
  for p = 1, table.getn(fftsa.sg_pk_f) do
    if fftsa.sg_pk_f[p] ~= nil then
      display.settext(fftsa.sg_pk_f[p], string.format("%d  ---", p))
      display.settext(fftsa.sg_pk_v[p], "")
      display.settext(fftsa.sg_pk_d[p], "")
    end
  end
  return true
end

-- The model, read once and kept: it cannot change while the app runs, and the floor rule
-- below asks on every Apply. An instrument that will not say reads as "", which matches no
-- model, so an absent attribute takes the shallower floor rather than raising.
function fftsa.model_name()
  if fftsa.model_str == nil then
    local m = nil
    if localnode ~= nil then m = localnode.model end
    if m == nil then m = "" end
    fftsa.model_str = tostring(m)
  end
  return fftsa.model_str
end

-- The digits anywhere in the string, not the whole of it, so a prefixed or suffixed form
-- answers the same. Plain find, the fourth argument, pattern metacharacters having no
-- business in a model number. string.match is the 5.1 spelling and is absent here.
function fftsa.is_7510()
  return string.find(fftsa.model_name(), "7510", 1, true) ~= nil
end

-- The floor a range and count want, in dBV. The deeper one needs the 1 V or 0.1 V range and
-- then either a DMM7510, whose floor is under -120 at every count, or a count whose bin is
-- narrow enough to take a DMM6500 under it. A range off the list, a wide-bin count and an
-- unidentified instrument all take -120, the floor that cannot hide a trace.
function fftsa.sg_dbmin_for(range, n)
  if range ~= nil and range <= fftsa.sg_dbmin_deep_vmax then
    if fftsa.is_7510() then return fftsa.sg_dbmin_deep end
    if n ~= nil and n >= fftsa.sg_dbmin_deep_n then return fftsa.sg_dbmin_deep end
  end
  return fftsa.sg_dbmin_std
end

-- Move the floor to what the range wants, answering whether it moved. One assignment is the
-- whole move, every reader taking fftsa.sg_dbmin live: the trace fill, the peak column, the
-- marker needles, the restore's span and dsp.out.dbfloor through dsp_live_push(). The answer
-- is what apply() pins the axis on, and an axis write costs 60 ms and a full repaint.
function fftsa.sg_dbmin_set(range, n)
  -- Defaulted here rather than at the call: a caller that passed only the range would
  -- silently lose the deeper floor at the two counts that need it.
  if n == nil then n = fftsa.n end
  local want = fftsa.sg_dbmin_for(range, n)
  if want == fftsa.sg_dbmin then return false end
  fftsa.sg_dbmin = want
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

-- Settling a gesture. Writing an axis limit costs 60 ms and repaints the whole widget, so
-- re-asserting both every frame is most of a short frame -- a slower, flickering trace.
-- Reading one back costs 0.0094 ms, so a settle reads before it writes.
--
-- The read-back's "return values are only valid when the objects event generation is set to
-- ALL", and non-button objects have none by default, so on a graph with no event registered
-- scalex and scaley answer nil and post nothing. sg_hook_scale is not an optimisation:
-- nothing here works without it. It reports the gesture too, which lets a tick that saw no
-- fire skip even the reads. The app's own write also fires EVENT_SCALE, asynchronously, and
-- needs no special case -- the echo reads back as the limits just written. EVENT_CURSOR
-- never fires.
--
-- A handler containing %xmin does not run, and it takes a counter in the same string down
-- with it, so the failure looks like the event never firing. Substitution is documented for
-- command strings, so why this one fails is unestablished: check that before reaching for it.
fftsa.sg_ev = 0        -- EVENT_SCALE fires since the tick last looked

-- A limit counts as moved past this fraction of sg_moved's scale, which is the larger of the
-- span and the endpoint. Taking the endpoint is what stops a narrow window far from DC
-- writing on every tick: at Start 499000, Stop 499010, reachable from the form, the span is
-- smaller than the rounding on its own endpoints. The price is a dead zone in exactly that
-- window -- about thirty pixels of drag go unrestored while the padlock reads closed --
-- accepted because the alternative is a 60 ms write every tick for ever, and a 10 Hz span at
-- 499 kHz holds no bins anyway. What would settle it is the read-back's own precision, which
-- is unmeasured: round-trip a fractional limit exactly and the scale can be the span alone.
fftsa.sg_tol = 1e-6

-- The limits the previous gesture check read, or nil when nothing is in flight. What tells
-- a finger still moving from one that has stopped, in sg_settle_x.
fftsa.sg_seen_lo = nil
fftsa.sg_seen_hi = nil

-- Turn the graph's pan-and-zoom reporting on. Unconditional rather than tied to the lock:
-- the dB axis is restored either way and an unlocked frequency gesture has to be read before
-- it can be adopted, and it costs nothing per frame. Without the report nothing settles, and
-- the symptom is a view that pans while the padlock reads closed.
function fftsa.sg_hook_scale()
  local g = fftsa.sg_graph
  if g == nil then return false end
  if display.EVENT_SCALE == nil then
    fftsa.lasterr = "no EVENT_SCALE on this firmware: the view lock cannot work"
    fftsa.say(fftsa.lasterr)
    return false
  end
  display.setevent(g, display.EVENT_SCALE,
                   "if fftsa ~= nil then fftsa.sg_ev = (fftsa.sg_ev or 0) + 1 end")
  fftsa.sg_ev = 0
  return true
end

function fftsa.sg_moved(got, want, span)
  if got == nil then return false end
  local scale = span
  local a = want
  if a < 0 then a = -a end
  if a > scale then scale = a end
  -- Nothing to measure against: an axis of no height, which only a socket can set. A zero
  -- scale makes every difference exceed the tolerance, so this would be a 60 ms write on
  -- every reported gesture for the life of the app.
  if scale <= 0 then return false end
  return (got - want) > scale * fftsa.sg_tol
      or (want - got) > scale * fftsa.sg_tol
end

-- The dB axis, put back whenever a gesture moved it, lock or no lock: its limits are
-- constants and Options does not offer them, so a dragged dB scale is only a worse view of
-- the same data.
function fftsa.sg_restore_y(g)
  if g == nil then g = fftsa.sg_graph end
  if g == nil then return false end
  local span = fftsa.sg_dbmax - fftsa.sg_dbmin
  local y1, y2 = display.graph.scaley(g)
  -- Either limit nil means the read-back told us nothing useful -- both returns are
  -- documented optional -- and a gesture was reported, so the axis is presumed moved: a
  -- pin costs a frame, a dead restore costs the feature.
  if y1 == nil or y2 == nil
     or fftsa.sg_moved(y1, fftsa.sg_dbmin, span)
     or fftsa.sg_moved(y2, fftsa.sg_dbmax, span) then
    fftsa.sg_pin_y(g)
    return true
  end
  return false
end

-- Adopt the frequency axis a gesture left behind: unlocked, a drag or a pinch retunes the
-- analyser to what it asked to see. A pan is not told from a pinch -- whatever the two limits
-- read, snapped into the legal range, is the new span -- and the pin that follows puts the
-- axis on the clamped pair, so a drag past a limit visibly stops at it.
function fftsa.sg_adopt_x(lo, hi)
  -- Refused and not repaired: a NaN limit survives every comparison in span_clamp, so it
  -- would reach the axis write, pick_fs and both Options fields. The span then stays as it
  -- is and the next gesture settles it.
  if lo ~= lo or hi ~= hi then return false end
  -- Rounded, because an axis limit is a float and an Options field is not: unrounded, the
  -- form could neither show nor re-apply the span the gesture just set. It is also what makes
  -- this a one-step fixed point, the pin writing integers that read back as themselves.
  local nlo, nhi = fftsa.span_clamp(math.floor(lo + 0.5), math.floor(hi + 0.5))
  -- Asked before fftsa.fhi moves, since the question is whether the plan in force covers
  -- the new stop.
  local replan = fftsa.plan_changed(nhi)
  fftsa.flo, fftsa.fhi = nlo, nhi
  if replan then
    -- No pin here: fftsa.apply() pins from this same pair, so one would be a second 60 ms
    -- write of identical limits, and the axis keeps the gesture's own limits until then. A
    -- new plan cannot be installed from inside a frame, so fftsa.frame() runs it between.
    fftsa.sg_store_xrange(nlo, nhi)
    fftsa.retune_pending = true
  else
    fftsa.sg_set_xrange(nlo, nhi)
  end
  return true
end

-- The frequency axis after a reported gesture, settled whichever way the lock says. Only
-- limits are compared, not the scale method the pin also re-asserts -- an axis switched to
-- auto-ranging moves its own limits, so the next tick catches it and the pin restores
-- XSCALE_OFF along with them.
function fftsa.sg_settle_x(g)
  if g == nil then g = fftsa.sg_graph end
  if g == nil then return false end
  local wlo, whi = fftsa.sg_xwant()
  if wlo == nil then return false end      -- span not plottable: nothing to compare
  local x1, x2 = display.graph.scalex(g)
  -- A nil read-back names no range, so there is nothing to adopt and the only coherent
  -- move is back onto the span. Guarding the lower limit alone would leave a left-anchored
  -- zoom -- which moves the upper one by itself -- invisible.
  if x1 == nil or x2 == nil then
    fftsa.sg_pin_x()
    return true
  end
  if not (fftsa.sg_moved(x1, wlo, whi - wlo)
          or fftsa.sg_moved(x2, whi, whi - wlo)) then
    fftsa.sg_seen_lo, fftsa.sg_seen_hi = nil, nil
    return false
  end
  if fftsa.sg_lock then
    fftsa.sg_seen_lo, fftsa.sg_seen_hi = nil, nil
    fftsa.sg_pin_x()
    return true
  end
  -- Unlocked, adopt only once the gesture has stopped moving: a pair that differs from the
  -- last check is a finger still on the glass, so it is remembered and left alone, and the
  -- next check with the same pair adopts it. One drag then costs one retune, which is a
  -- whole capture, rather than one per check.
  if fftsa.sg_seen_lo == nil
     or fftsa.sg_moved(x1, fftsa.sg_seen_lo, whi - wlo)
     or fftsa.sg_moved(x2, fftsa.sg_seen_hi, whi - wlo) then
    fftsa.sg_seen_lo, fftsa.sg_seen_hi = x1, x2
    return false
  end
  fftsa.sg_seen_lo, fftsa.sg_seen_hi = nil, nil
  return fftsa.sg_adopt_x(x1, x2)
end

-- Both axes, each touched only if it moved, because every write repaints the widget.
function fftsa.sg_settle()
  local g = fftsa.sg_graph
  if g == nil then return false end
  -- Cleared before the writes, not after. A write takes 60 ms an axis and fires
  -- EVENT_SCALE itself, so clearing afterwards discards every fire from that window --
  -- including a finger still dragging through it.
  fftsa.sg_ev = 0
  -- dB first, because it is the half that cannot raise: the X half reaches into the app
  -- module for the clamp and the plan, and a frame carries that on a pcall.
  local wy = fftsa.sg_restore_y(g)
  local wx = fftsa.sg_settle_x(g)
  return wy or wx
end

function fftsa.sg_scale_check()
  if (fftsa.sg_ev or 0) == 0 then return false end
  return fftsa.sg_settle()
end

-- Two jobs on two clocks. The icons need re-asserting only often enough that a focus repaint
-- does not sit there, which is the peak table's period, but a gesture has to be answered
-- while the finger is still near where it stopped. A check with no gesture reported costs one
-- os.clock() and no graph call, so the shorter period is free whenever nothing is moving.
-- Driven from the frame, so the frame period is the floor, and a halted app settles only on
-- a Lock press.
fftsa.sg_scale_period = 0.15    -- seconds between gesture checks
fftsa.sg_tick_last  = nil
fftsa.sg_scale_last = nil
fftsa.sg_term_last  = nil       -- the terminal selection the line currently names

-- The HELP key is the firmware's own: nothing delivers it to a script. display.setevent
-- refuses a disp_key outright, and display.setkeyenable takes only ON and OFF, where OFF
-- substitutes a "help key is disabled" dialog rather than silence. The dialog it raises is
-- invisible to every event path -- no EVENT_HIDE on the screen it covers, nothing in
-- ki.display.dump, no posted event -- so a press leaves that dialog on the glass until EXIT
-- is pressed, and the app neither sees it nor clears it.

function fftsa.sg_slow_tick()
  local now = os.clock()
  local did = false
  local heavy = false
  if fftsa.sg_scale_last == nil
     or (now - fftsa.sg_scale_last) >= fftsa.sg_scale_period then
    fftsa.sg_scale_last = now
    fftsa.sg_scale_check()
    did = true
  end
  if fftsa.sg_tick_last == nil
     or (now - fftsa.sg_tick_last) >= fftsa.sg_pk_period then
    fftsa.sg_tick_last = now
    if fftsa.icons_reassert ~= nil then fftsa.icons_reassert() end
    -- The FRONT/REAR button is pressed on the panel and not through Options, so nothing
    -- else rewrites the line when it moves, and the pair not selected is an open input. On
    -- this clock rather than the gesture one, a human press affording a second of latency,
    -- and the text is written only when the answer changes.
    local term = fftsa.terminal_text()
    if term ~= fftsa.sg_term_last then
      fftsa.sg_term_last = term
      fftsa.sg_write_xunit()
    end
    -- The over-range banner replaces this same line, so it is written on the transition and
    -- on the way back, by the same rule: only when the answer changes.
    if fftsa.overrange ~= fftsa.sg_over_shown then
      fftsa.sg_over_shown = fftsa.overrange
      fftsa.sg_write_xunit()
    end
    -- Distortion and noise: the noise mean is a pass over every plotted bin at 4.3 us a bin,
    -- so 35 ms at 16384, which is why it is on this clock and not the frame's.
    fftsa.sg_show_thd()
    did = true
    heavy = true
  end
  -- Two answers, because the callers want different questions: did says any of this ran, and
  -- the gesture clock sets it every 0.15 s, while heavy says the one-a-second block ran --
  -- the one carrying the noise pass and the icon re-assert. The period rule needs heavy, or
  -- every frame from 4096 up reads as a block frame and the worst plain frame is never
  -- recorded.
  return did, heavy
end

-- The recovery path after a failed frame, and the same binding as the build.
function fftsa.sg_rebind()
  return fftsa.sg_bind()
end


-- Seconds the frame stays blocked after the refill so the display task can paint it; too
-- short and the firmware posts 1706. That task runs only while Lua is blocked, so this and
-- the timer's idle are the whole of its budget.
--
-- Measured at 2048 samples this is neutral from 5 to 20 ms and costs a whole tick at 30. At
-- 5 ms the frame grows by about 50 ms at 16,384, the task not finishing inside the shorter
-- slice and the remainder contending with the next frame's work -- ten times what the yield
-- saved -- and docs/PERFORMANCE.md measures that case at 35.6 Hz in Lua with 194
-- dropped-message events and a trace updating three times a second. Nothing in the app can
-- see it: fftsa.fps counts completed Lua frames against the wall clock, so it reads 35.6
-- while the glass shows 3. Not a figure to shave.
fftsa.sg_yield = 0.010
-- Given to the widget's first draw of a freshly bound trace, before any frame can clear the
-- buffer under it. Paid once a launch, behind a load that already takes seconds.
fftsa.sg_first_paint = 0.25
-- Height, in dB, of the seeded trace: see fftsa.sg_fmt_seed for why it may not be flat.
fftsa.sg_seed_spread = 2
-- Given to the panel between switching away from a screen and deleting it: see
-- fftsa.del_scr for what deleting a screen still on show costs.
fftsa.sg_scr_yield = 0.15

fftsa.sg_pk_period = 1.0        -- seconds between refreshes
fftsa.sg_pk_ftol   = 0.002      -- fractional frequency move worth a redraw
fftsa.sg_pk_vtol   = 0.01       -- fractional amplitude move worth a redraw
fftsa.sg_pk_last   = nil        -- nil means never drawn, so the first call draws
fftsa.sg_pk_lf     = {}
fftsa.sg_pk_lv     = {}

fftsa.sg_peaks_off = false      -- disables the peak table, to attribute display traffic

-- One peak as (frequency in hertz, volts), or nil where there is none.
--
-- pk_hz/pk_v are what the primitive already resolved, sub-bin corrected in both axes once a
-- frame rather than once per display user, and it is the only form the app passes. Without
-- them it falls back to the bin index and interpolates here, which is the form
-- tools/test_tsp.lua drives. fftsa.peak_interp is in tsp/fft_interp.tsp, which the archive
-- leaves out, so on the instrument that fallback answers nil rather than indexing a nil.
function fftsa.sg_peak_at(p, bi, bv, binhz, pk_hz, pk_v)
  if pk_hz ~= nil then
    local f = pk_hz[p]
    if f == nil then return nil end
    return f, pk_v[p]
  end
  if bi == nil or bv == nil or fftsa.peak_interp == nil then return nil end
  local k = bi[p]
  if k == nil or k <= 0 or not (bv[p] > 0) then return nil end
  local dk, iv = fftsa.peak_interp(k, fftsa.sg_nbins)
  if iv == nil then dk, iv = 0, math.sqrt(bv[p]) end
  return (k - 1 + dk) * binhz, iv
end

-- Refill the marker trace: one point a peak, at the frequency the peak table reports rather
-- than the column the trace drew. Sorted by frequency, because the peaks arrive
-- strongest-first and a line through them in amplitude order zigzags across the plot. Filled
-- before the spectrum refill, so the paint at the frame's yield sees both buffers complete.
function fftsa.sg_update_markers(bi, bv, count, binhz, pk_hz, pk_v)
  local mk = fftsa.sg_mk
  if mk == nil or not fftsa.sg_markers then return 0 end
  local log10 = math.log10
  local hz, db = fftsa.sg_mk_hz, fftsa.sg_mk_db
  local n = 0
  local p
  for p = 1, count do
    local f, iv = fftsa.sg_peak_at(p, bi, bv, binhz, pk_hz, pk_v)
    if f ~= nil then
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
  -- A needle a peak: the floor a pixel below the peak frequency, the peak, the floor a pixel
  -- above. The x values have to stay increasing or the line doubles back, so each foot is
  -- held at or above the previous needle's and two peaks within two pixels read as one.
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
function fftsa.sg_show_peaks(bi, bv, count, binhz, pk_hz, pk_v)
  if fftsa.sg_peaks_off then return false end
  -- Coming back from over-range the dashed block is on screen and the move gate has no
  -- memory of it, so the gate would hold the dashes until a peak happened to move. Clearing
  -- sg_pk_last forces one redraw of the real figures.
  if fftsa.sg_pk_over then
    fftsa.sg_pk_over, fftsa.sg_pk_last = false, nil
  end
  local now = os.clock()
  if fftsa.sg_pk_last ~= nil
     and (now - fftsa.sg_pk_last) < fftsa.sg_pk_period then
    return false
  end
  local abs = math.abs
  local moved = false
  for p = 1, count do
    local f, v = fftsa.sg_peak_at(p, bi, bv, binhz, pk_hz, pk_v)
    if f == nil then f, v = -1, -1 end
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
  return fftsa.sg_show_peaks_now(bi, bv, count, binhz, pk_hz, pk_v)
end

-- The microvolt format the peak table's volt column uses: one decimal on the 1 V and 0.1 V
-- ranges, where a whole-microvolt step throws away resolution, and whole microvolts on 10 V.
-- One decimal and not two, because the digitizer is 4.5 digits -- an LSB of about 2 uV on
-- 0.1 V -- and the measured per-bin noise floor is 2.95 uV. The widest result is "999.9 uV",
-- inside what "%.2f mV" and "%.4f V" already print in the same 82 px field.
fftsa.sg_uv_fmt_std  = "%0.0f uV"
fftsa.sg_uv_fmt_fine = "%0.1f uV"
fftsa.sg_uv_fine_vmax = 1        -- the largest range that gets the decimal

function fftsa.sg_uv_fmt(range)
  if range ~= nil and range <= fftsa.sg_uv_fine_vmax then return fftsa.sg_uv_fmt_fine end
  return fftsa.sg_uv_fmt_std
end

-- The unconditional draw; the gate above is the only thing deciding when it runs.
function fftsa.sg_show_peaks_now(bi, bv, count, binhz, pk_hz, pk_v)
  local log10, settext = math.log10, display.settext
  for p = 1, count do
    local f, v = fftsa.sg_peak_at(p, bi, bv, binhz, pk_hz, pk_v)
    if f ~= nil then
      local ftxt
      if f ~= f then ftxt = string.format("%d  ---", p)
      elseif f >= 1000 then ftxt = string.format("%d  %.3f kHz", p, f / 1000)
      else ftxt = string.format("%d  %.1f Hz", p, f) end
      -- An amplitude past the largest range is not a voltage, so both columns dash rather
      -- than one of them stating a figure. It is also a width matter: %.4f of the 9.9e+37
      -- sentinel is 45 characters where the column holds 8, and at a fixed x that overwrites
      -- the dB column and the whole second column with it.
      local vtxt, dtxt
      if v ~= v then vtxt, dtxt = "", ""
      elseif v > fftsa.sg_vmax_real then vtxt, dtxt = "---", "--- dBV"
      else
        if v >= 1 then vtxt = string.format("%.4f V", v)
        elseif v >= 1e-3 then vtxt = string.format("%.2f mV", v * 1e3)
        else vtxt = string.format(fftsa.sg_uv_fmt(fftsa.range), v * 1e6) end
        -- Floored at the plot's own floor: a 1e-26 power bin reads -260 dBV against an axis
        -- that stops at -120, which the trace cannot show and the column has no room for.
        local dbv = 20 * log10(v)
        if not (dbv > fftsa.sg_dbmin) then dbv = fftsa.sg_dbmin end
        dtxt = string.format("%.1f dBV", dbv)
      end
      settext(fftsa.sg_pk_f[p], ftxt)
      settext(fftsa.sg_pk_v[p], vtxt)
      settext(fftsa.sg_pk_d[p], dtxt)
    else
      settext(fftsa.sg_pk_f[p], string.format("%d  ---", p))
      settext(fftsa.sg_pk_v[p], "")
      settext(fftsa.sg_pk_d[p], "")
    end
  end
  return true
end
