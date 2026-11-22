-- Spectrum graph and peak table. The firmware plots dBV against frequency from the reading's extra field.

fftsa = fftsa or {}

fftsa.sg_nbins   = 256
fftsa.sg_npeak   = 6

-- Fixed trace width bounds display work independently of FFT length.
fftsa.sg_ncol    = 255

-- Optional marker trace uses interpolated peak frequencies.
-- The line style applies to every trace, so each marker is a floor–peak–floor needle.
fftsa.sg_markers = false
fftsa.sg_mk_per  = 3       -- points a needle: floor, peak, floor
-- Firmware requires at least this many readings in a buffer allocation.
fftsa.sg_bufmin  = 10
fftsa.sg_maxpts  = 680

-- Keep live handles if the script is loaded again during the same boot.
if fftsa.sg_handles_inited == nil then
  fftsa.sg_buf   = nil
  fftsa.sg_scr   = nil
  fftsa.sg_graph = nil
  fftsa.sg_pk_f  = nil
  fftsa.sg_pk_v  = nil
  fftsa.sg_pk_d  = nil
  fftsa.sg_xunit = nil
  fftsa.sg_mk    = nil
  -- Bare global names let the display task identify the trace buffers.
  FFTSA_TRACE    = nil
  FFTSA_MARK     = nil
  FFTSA_OLDTRACE = nil
  FFTSA_OLDMARK  = nil
  fftsa.sg_handles_inited = true
end

-- The lock controls how X gestures settle, not whether the widget accepts them.
fftsa.sg_lock = true

fftsa.sg_flo_hz  = 0
fftsa.sg_fhi_hz  = 1e9

-- Pin X explicitly: autoscale uses the previous or partially filled trace's extent.
fftsa.sg_xmethod = display.XSCALE_OFF
-- Do not notify the graph during a FILL_ONCE refill while the buffer is incomplete.

-- Object coordinates exclude the firmware header.
fftsa.sg_gx      = 8
fftsa.sg_gy      = 0
fftsa.sg_gw      = 784
fftsa.sg_gh      = 312

-- The 1 V and 0.1 V ranges use the deeper floor on DMM7510, or at long FFT lengths on DMM6500.
fftsa.sg_dbmin_std       = -120
fftsa.sg_dbmin_deep      = -140
fftsa.sg_dbmin_deep_vmax = 1     -- the largest range the deeper floor covers
fftsa.sg_dbmin_deep_n    = 16384 -- the smallest count whose bin needs it on a DMM6500
fftsa.sg_dbmin           = fftsa.sg_dbmin_std
fftsa.sg_dbmax           = 20
fftsa.sg_vfloor          = 1e-9

fftsa.model_str = nil

-- The firmware's over-range sentinel is not a voltage; suppress derived readouts.
fftsa.sg_vmax_real = 15
fftsa.overrange    = false   -- the frame's verdict; the peak table and the THD line read it
fftsa.sg_pk_over   = false   -- whether the dashed table is the one on screen

-- Width between plot grid edges, not the width of the graph object.
fftsa.sg_plotpx  = 680

fftsa.sg_fmax_real = 1e6

-- Fixed field positions keep frequency, voltage and dB aligned as text widths change.
fftsa.sg_pky     = 350
fftsa.sg_pkdy    = 20
fftsa.sg_pk_colx_f = {8,   334}
fftsa.sg_pk_colx_v = {123, 444}
fftsa.sg_pk_colx_d = {235, 547}
fftsa.sg_pk_cf   = 14745568  -- freq colour (pale green)
fftsa.sg_pk_cv   = 13166335  -- volt colour (pale blue)
fftsa.sg_pk_cd   = 16769184  -- dB colour   (pale amber)
fftsa.sg_xunit_x = 8
fftsa.sg_xunit_y = 410
fftsa.sg_xunit_c = 56575     -- cyan 00DCFF, the colour of the Options preview line
fftsa.sg_over_c  = 16711680
fftsa.sg_xunit_c_now = nil

fftsa.sg_thd_x = 8
fftsa.sg_thd_y = 328
fftsa.sg_thd_c = 16769184
fftsa.sg_thd_last = nil

-- Gate THD precision by the sample count of the actual transform.
fftsa.sg_thd_n3 = 8192     -- samples the third decimal needs
fftsa.sg_thd_n4 = 16384    -- and the fourth

-- A failed display allocation can leave a nil handle during partial teardown.
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

-- Switch away and let the display task settle before deleting a screen.
function fftsa.del_scr(h, showscr)
  if h == nil then return true end
  if showscr == nil then showscr = display.SCREEN_HOME end
  display.changescreen(showscr)
  delay(fftsa.sg_scr_yield)
  display.delete(h)
  return true
end

function fftsa.sg_xwant()
  local lo, hi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if hi > fftsa.sg_fmax_real or hi <= lo then return nil, nil end
  if lo > 0 and lo * fftsa.sg_plotpx < (hi - lo) then lo = 0 end
  return lo, hi
end

function fftsa.sg_pin_x()
  if fftsa.sg_graph == nil then return false end
  local lo, hi = fftsa.sg_xwant()
  if lo == nil then return false end
  local m = fftsa.sg_xmethod
  if m == nil then m = display.XSCALE_OFF end
  -- X is bound to the reading's numeric extra field in Hz, not its timestamp.
  display.graph.scalex(fftsa.sg_graph, m, display.AXIS_NORMAL, lo, hi)
  return true
end

-- Settings line: fast-path state, span, bin width, sample count, acquisition rate and FPS.
function fftsa.sg_fast_text()
  local nl = fftsa.nl
  if nl == nil or nl.px == nil then return "" end
  local re = nl.px.restarts or 0
  local was = fftsa.sg_fast_re
  fftsa.sg_fast_re = re
  if nl.px.state ~= 'on' then return "" end
  if was ~= nil and re > was then
    return string.format("F%d ", re - was)
  end
  return "F "
end

function fftsa.sg_xunit_text()
  if fftsa.overrange then return fftsa.sg_overrange_text(fftsa.range) end
  -- The settings line must tolerate unset values during startup and reconfiguration.
  local t = string.format("%s%d pts   %s   %s", fftsa.sg_fast_text(), fftsa.n or 0,
                          tostring(fftsa.opt_info_text(fftsa.fs, fftsa.n)),
                          tostring(fftsa.range_labels[fftsa.range_to_idx(fftsa.range)]))
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
  return t .. fftsa.sg_fps_text() .. "   " .. fftsa.terminal_text()
end

function fftsa.sg_fps_text()
  local f = fftsa.fps
  if f == nil or not (f > 0) then return "" end
  if f < 10 then return string.format("  %.1f fps", f) end
  return string.format("  %.0f fps", f)
end

function fftsa.sg_make_buffer(nbins, npoints)
  fftsa.sg_nbins = nbins
  local want = npoints or fftsa.sg_capacity()
  if fftsa.sg_buf ~= nil and fftsa.sg_mk ~= nil and fftsa.sg_buf.capacity == want then
    fftsa.sg_name_buffers()
    fftsa.sg_free_old()
    return fftsa.sg_buf
  end
  -- Allocate the new trace pair before freeing the old one so its storage can't be reused.
  local newbuf = fftsa.sg_mk_trace(want)
  local mkcap = fftsa.sg_npeak * fftsa.sg_mk_per
  if mkcap < fftsa.sg_bufmin then mkcap = fftsa.sg_bufmin end
  local newmk = fftsa.sg_mk_mark(mkcap)
  -- Detach traces first: firmware won't delete a buffer that is still bound.
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
  fftsa.sg_mk_db, fftsa.sg_mk_hz = {}, {}
  local j
  for j = 1, fftsa.sg_npeak + 1 do
    fftsa.sg_mk_db[j], fftsa.sg_mk_hz[j] = fftsa.sg_dbmin, 0
  end
  return fftsa.sg_buf
end

-- Keep ring capacity fixed within a launch; reallocating invalidates trace geometry.

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

-- Firmware derives buffer names from the bare global assignment, not a table field.
function fftsa.sg_name_buffers()
  return FFTSA_TRACE == fftsa.sg_buf and FFTSA_MARK == fftsa.sg_mk
end

function fftsa.sg_mk_trace(want)
  FFTSA_TRACE = buffer.make(want, buffer.STYLE_WRITABLE_FULL)
  return fftsa.sg_fmt_seed(FFTSA_TRACE, want)
end

function fftsa.sg_mk_mark(want)
  FFTSA_MARK = buffer.make(want, buffer.STYLE_WRITABLE_FULL)
  return fftsa.sg_fmt_seed(FFTSA_MARK, want)
end

-- Seed the full trace once so the widget has geometry before the first frame.
function fftsa.sg_fmt_seed(b, want)
  if b == nil then return nil end
  if fftsa.sg_ring then b.fillmode = buffer.FILL_CONTINUOUS end
  -- Custom units keep the firmware from formatting dB values as voltages.
  buffer.unit(buffer.UNIT_CUSTOM1, "dB")
  buffer.write.format(b, buffer.UNIT_CUSTOM1, buffer.DIGITS_4_5,
                         buffer.UNIT_HERTZ,   buffer.DIGITS_6_5)
  -- Seed inside the pinned axes; the widget initializes its geometry from this trace.
  local k, span = nil, want - 1
  if span < 1 then span = 1 end
  local flo, fhi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if flo == nil or fhi == nil or fhi > fftsa.sg_fmax_real then
    flo, fhi = fftsa.flo, fftsa.fhi
  end
  if flo == nil or fhi == nil or not (fhi > flo) then
    flo, fhi = fftsa.flomin, fftsa.fhi_min
  end
  for k = 1, want do
    local t = (k - 1) / span
    fftsa.sg_write_point(b, fftsa.sg_dbmin + fftsa.sg_seed_spread * t,
                         flo + (fhi - flo) * t, k)
  end
  return b
end

-- Store frequency in extra and a monotonic counter in timestamp.
function fftsa.sg_write_point(buf, db, f, slot)
  if slot == nil then slot = 1 end
  buffer.write.reading(buf, db, f, slot, 0)
end

-- A ring keeps a full trace while appends are in flight; FILL_ONCE clears before refill.
fftsa.sg_ring  = true
fftsa.sg_stamp = 0       -- ring timestamps, monotonic across passes

-- Fill exactly one capacity per pass to hold the cursor steady. The folded trace
-- keeps each slot's X fixed across passes and joins neighboring frames at the same X.
fftsa.sg_fold = true

fftsa.sg_up = true

-- The fast path writes validated display records in place. Any refusal falls back to appends.
fftsa.sg_pix = true

fftsa.sg_pix_any = false

function fftsa.sg_pix_armed()
  if not fftsa.sg_pix then return false end
  return true
end

-- The cursor command provokes a repaint without advancing the ring.
-- The diagnostic append mode moves the oldest cursor and can expose the wrap seam.
fftsa.sg_pix_repaint = 'cursor'

-- Limit repaint requests, not ring writes: the GUI acknowledges a request before drawing.
fftsa.sg_repaint_min = 0

-- Draw before appending; seek after appending so discovery sees this frame's records.
-- A pixel-path exception disables it for the session without dropping the append fallback.
function fftsa.sg_pix_draw(db, hz, nseg, tb)
  local nl = fftsa.nl
  if nl == nil or nl.px == nil or nl.px.state ~= 'on' then return nil end
  -- Reserve the timestamp before writing; the firmware rejects timestamps that go backwards.
  local t = (fftsa.sg_stamp or 0) + 1
  fftsa.sg_stamp = t
  local ok, n = pcall(nl.px_frame, db, hz, nseg, tb, t)
  -- Only the draw path runs while engaged. Keep the diagnostic hunt out of its error path.
  if nl.PX_PTRHUNT then pcall(nl.px_ptrhunt) end
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
  -- Pass the graph handle to the pointer lookup alongside the named trace buffer.
  local ok, err = pcall(nl.px_try, db, hz, nseg, tb, t, fftsa.sg_graph)
  if not ok then nl.px_off('px_try raised: ' .. tostring(err)) end
end

-- Clear native ring state before returning to appends.
function fftsa.sg_pix_stop(why)
  local nl = fftsa.nl
  if nl == nil or nl.px == nil or nl.px_restart == nil then return end
  if nl.px.state == 'off' then return end
  nl.px_restart(why)
end

-- Axis changes invalidate the pixel map, not the ring geometry.
-- Let an in-progress search continue; only an engaged map needs to be dropped.
function fftsa.sg_pix_stale(why)
  local nl = fftsa.nl
  if nl == nil or nl.px == nil or nl.px_restart == nil then return end
  if nl.px.state ~= 'on' then return end
  nl.px_restart(why)
end

function fftsa.sg_ring_cap(ncol)
  local n = ncol or fftsa.sg_ncol
  if fftsa.sg_fold then return 2 * n end
  return n
end

-- Match capacity to the writes per pass so the append cursor returns to the same slot.
function fftsa.sg_capacity()
  return fftsa.sg_ring_cap()
end

-- A folded ring uses half its slots for the return lap.
function fftsa.sg_points_max(buf)
  local b = buf or fftsa.sg_buf
  if b == nil then return fftsa.sg_maxpts end
  if fftsa.sg_ring and fftsa.sg_fold then return math.floor(b.capacity / 2) end
  return b.capacity
end

-- Return the number of plotted frequency columns, excluding sentinels.
function fftsa.sg_db(db)
  if db ~= nil and db[1] ~= nil then return db end
  local nl = fftsa.nl
  if nl == nil or type(nl.db_now) ~= 'function' then return db end
  return nl.db_now(db)
end

function fftsa.sg_fill(db, hz, nseg)
  local wr = buffer.write.reading
  local tb = fftsa.sg_buf
  local i
  if tb == nil or nseg == nil or nseg < 1 then return 0 end
  if not fftsa.sg_ring then
    -- Decode before clearing so a failed reduction leaves the previous trace visible.
    db = fftsa.sg_db(db)
    if db == nil then return 0 end
    tb.clear()
    for i = 1, nseg do
      wr(tb, db[i], hz[i], i, 0)
    end
    return nseg
  end
  -- Timestamps must increase even when a pass overwrites the same slots.
  if fftsa.sg_pix_armed() then
    local n = fftsa.sg_pix_draw(db, hz, nseg, tb)
    if n ~= nil then return n end
  end
  db = fftsa.sg_db(db)
  if db == nil then return 0 end
  local cap = tb.capacity
  local room = cap
  if fftsa.sg_fold then room = math.floor(cap / 2) end
  if nseg > room then nseg = room end
  local t = fftsa.sg_stamp
  -- Reserve the full timestamp range before writing: even a failed pass may have used part of it.
  local used = room
  if fftsa.sg_fold then used = 2 * room end
  fftsa.sg_stamp = t + used
  local last = nseg
  -- In one-lap mode reverse each pass so it starts where the last one ended.
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
    if fftsa.sg_pix_armed() then fftsa.sg_pix_arm(db, hz, nseg, tb) end
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
  if fftsa.sg_pix_armed() then fftsa.sg_pix_arm(db, hz, nseg, tb) end
  return nseg
end

function fftsa.sg_build(title, nbins, npoints)
  fftsa.sg_destroy()

  fftsa.sg_make_buffer(nbins, npoints)
  local create = display.create
  local small  = display.FONT_SMALL
  fftsa.sg_scr = create(display.ROOT, display.OBJ_SCREEN, title)
  -- Firmware returns nil after posting an event when the display object pool is exhausted.
  if fftsa.sg_scr == nil then
    fftsa.lasterr = "OBJPOOL exhausted building the spectrum screen"
    return nil, fftsa.lasterr
  end
  -- Screen creation makes it active; raise the cover before creating children.
  fftsa.loading_front()

  fftsa.sg_graph = create(fftsa.sg_scr, display.OBJ_GRAPH, fftsa.sg_gx, fftsa.sg_gy, fftsa.sg_gw, fftsa.sg_gh)
  -- X is reading extra (Hz); Y is reading value (dBV).
  fftsa.sg_bind()

  fftsa.sg_pk_f, fftsa.sg_pk_v, fftsa.sg_pk_d = {}, {}, {}
  for p = 1, fftsa.sg_npeak do
    local col, row = 1, p - 1
    if p > 3 then col = 2; row = p - 4 end
    local y = fftsa.sg_pky + row * fftsa.sg_pkdy
    if y > 418 then y = 418 end
    fftsa.sg_pk_f[p] = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_pk_colx_f[col], y,
                        string.format("%d  ---", p), fftsa.sg_pk_cf, small, display.JUST_LEFT)
    fftsa.sg_pk_v[p] = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_pk_colx_v[col], y, "", fftsa.sg_pk_cv, display.FONT_1, display.JUST_LEFT)
    fftsa.sg_pk_d[p] = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_pk_colx_d[col], y, "", fftsa.sg_pk_cd, display.FONT_1, display.JUST_LEFT)
  end

  fftsa.sg_thd_last = nil
  fftsa.sg_thd = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_thd_x, fftsa.sg_thd_y,
                        fftsa.sg_thd_text(nil, nil, nil), fftsa.sg_thd_c, small, display.JUST_LEFT)

  fftsa.sg_xunit = create(fftsa.sg_scr, display.OBJ_TEXT, fftsa.sg_xunit_x, fftsa.sg_xunit_y,
                          fftsa.sg_xunit_text(), fftsa.sg_xunit_c, small, display.JUST_LEFT)

  return fftsa.sg_scr
end

-- Detach before deleting the graph and release buffers only after unbinding them.
function fftsa.sg_destroy(release)
  fftsa.sg_pix_stop('screen destroyed')
  if fftsa.sg_graph ~= nil then
    display.graph.removeall(fftsa.sg_graph)
  end
  fftsa.del_scr(fftsa.sg_scr)
  fftsa.sg_scr, fftsa.sg_graph, fftsa.sg_pk_f, fftsa.sg_pk_v, fftsa.sg_pk_d,
    fftsa.sg_xunit, fftsa.sg_thd = nil, nil, nil, nil, nil, nil, nil
  -- Keep the outgoing trace buffers across a rebuild until replacements exist;
  -- final teardown restores the default buffer and releases the trace pair.
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

-- Select defbuffer1 by taking one reading into it; preserve the active function's count.
function fftsa.sg_restore_defbuffer()
  if FFTSA_TRACE == nil and FFTSA_MARK == nil and FFTSA_OLDTRACE == nil
     and FFTSA_OLDMARK == nil and fftsa.cap == nil then
    fftsa.sg_defbuf_ok = nil
    return false
  end
  local ok = false
  local func = dmm.digitize.func
  if func ~= dmm.FUNC_NONE then
    local count
    if func ~= dmm.FUNC_DIGITIZE_VOLTAGE then count = dmm.digitize.count end
    ok = pcall(function()
      dmm.digitize.count = 1
      dmm.digitize.read(defbuffer1)
    end)
    if count ~= nil and dmm.digitize.func == func then dmm.digitize.count = count end
  elseif dmm.measure.func ~= dmm.FUNC_NONE then
    ok = pcall(function() dmm.measure.read(defbuffer1) end)
  end
  -- Teardown diagnostics must not overwrite the error that triggered teardown.
  fftsa.sg_defbuf_ok = ok
  return ok
end

function fftsa.sg_drop_buffers()
  if FFTSA_MARK ~= nil then pcall(function() buffer.delete(FFTSA_MARK) end) end
  if FFTSA_TRACE ~= nil then pcall(function() buffer.delete(FFTSA_TRACE) end) end
  if FFTSA_OLDMARK ~= nil then pcall(function() buffer.delete(FFTSA_OLDMARK) end) end
  if FFTSA_OLDTRACE ~= nil then pcall(function() buffer.delete(FFTSA_OLDTRACE) end) end
  FFTSA_TRACE, FFTSA_MARK = nil, nil
  FFTSA_OLDTRACE, FFTSA_OLDMARK = nil, nil
  return true
end

-- Shared inclusive bin bounds for the plot, peaks and distortion; indices are one-based.
function fftsa.sg_window_bins(nbins, binhz, flo, fhi)
  if binhz == nil or binhz <= 0 then return 1, nbins end
  if flo == nil then flo = fftsa.sg_flo_hz end
  if fhi == nil then fhi = fftsa.sg_fhi_hz end
  local floor, ceil = math.floor, math.ceil
  -- Round the low edge up so frequencies below the requested span are excluded.
  local kmin = ceil(flo / binhz) + 1
  local kmax = floor(fhi / binhz) + 1
  if kmin < 1 then kmin = 1 end
  if kmin > nbins then kmin = nbins end
  if kmax > nbins then kmax = nbins end
  if kmax < kmin then kmax = kmin end
  return kmin, kmax
end

function fftsa.sg_write_xunit()
  if fftsa.sg_xunit == nil then return false end
  local ok, err = pcall(function()
    -- Set the colour and text together so over-range can't leave the normal legend red.
    local c = fftsa.sg_xunit_c
    if fftsa.overrange then c = fftsa.sg_over_c end
    if c ~= fftsa.sg_xunit_c_now then
      fftsa.sg_xunit_c_now = c
      display.setcolor(fftsa.sg_xunit, c)
    end
    display.settext(fftsa.sg_xunit, fftsa.sg_xunit_text())
  end)
  if not ok then
    -- Protect formatting as well as the display write; this runs after settings are committed.
    fftsa.lasterr = string.format(
      "settings line: %s [n=%s fs=%s fs_acq=%s range=%s rangetxt=%s win=%s "
      .. "binhz=%s nbins=%s term=%s]", tostring(err), tostring(fftsa.n), tostring(fftsa.fs),
      tostring(fftsa.fs_acq), tostring(fftsa.range),
      tostring(fftsa.range_labels[fftsa.range_to_idx(fftsa.range)]), tostring(fftsa.win_i),
      tostring(fftsa.binhz), tostring(fftsa.sg_nbins), tostring(fftsa.terminal_text()))
  end
  return ok
end

-- Store the span without pinning so Apply can pin both axes in order.
function fftsa.sg_store_xrange(flo_hz, fhi_hz)
  fftsa.sg_flo_hz = flo_hz
  fftsa.sg_fhi_hz = fhi_hz
  fftsa.sg_write_xunit()
end

-- Unavailable measurements use dashes, not a numerical zero.
function fftsa.sg_thd_text(thd, snr, ndb, n, over)
  local t, s
  if over then
    t, s, ndb = "THD: ---", "S/N: ---", nil
  elseif thd == nil and snr == nil then
    t, s = "THD: NoSig", "S/N: NoSig"
  else
    if thd == nil then t = "THD: ---"
    -- Check NaN by self-comparison; ordered comparisons are unreliable for it on this firmware.
    elseif thd ~= thd then t = "THD: ---"
    -- Suppress decimals above 100% THD.
    elseif thd >= 100 then t = string.format("THD: %.0f%%", thd)
    elseif n ~= nil and n >= fftsa.sg_thd_n4 then t = string.format("THD: %.4f%%", thd)
    elseif n ~= nil and n >= fftsa.sg_thd_n3 then t = string.format("THD: %.3f%%", thd)
    else t = string.format("THD: %.2f%%", thd) end
    if snr == nil or snr ~= snr then s = "S/N: --- dB"
    else s = string.format("S/N: %.1f dB", snr) end
  end
  if ndb == nil or ndb ~= ndb then return t .. "    " .. s .. "    Noise Floor: --- dBV" end
  return t .. "    " .. s .. string.format("    Noise Floor: %.1f dBV", ndb)
end

-- Update only on changed text, at peak-table cadence.
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

function fftsa.sg_set_xrange(flo_hz, fhi_hz)
  fftsa.sg_store_xrange(flo_hz, fhi_hz)
  fftsa.sg_pin_x()
end

function fftsa.sg_bind()
  local g = fftsa.sg_graph
  if g == nil then return false end
  -- Rebinding destroys the display ring; discard any cached pixel map before using it again.
  fftsa.sg_pix_stop('traces rebound')
  display.graph.removeall(g)
  display.graph.add(g, fftsa.sg_buf, display.ELEMENT_DATA,
                    fftsa.sg_buf, display.ELEMENT_EXTRA)
  if fftsa.sg_markers and fftsa.sg_mk ~= nil then
    display.graph.add(g, fftsa.sg_mk, display.ELEMENT_DATA,
                      fftsa.sg_mk, display.ELEMENT_EXTRA)
    -- Use a common scale so selecting the marker trace can't change either axis.
    display.graph.scaletrace(g, display.TRACE_ALL)
  end
  -- Line style is graph-wide; the marker trace draws needles with it.
  display.graph.drawstyle(g, display.STYLE_LINE)
  fftsa.sg_pin_y(g)
  fftsa.sg_pin_x()
  -- Reassert graph settings after removeall/add, which can reset them.
  fftsa.sg_hook_scale()
  return true
end

-- Check the buffer extrema for the digitizer's over-range sentinel before computing DSP.
function fftsa.cap_overrange(buf)
  if buf == nil then return false end
  if buffer.getstats == nil then return false end
  local st = buffer.getstats(buf)
  if st == nil or st.n == nil or st.n == 0 then return false end
  local lim = fftsa.sg_vmax_real
  if st.max ~= nil and st.max.reading ~= nil and st.max.reading > lim then return true end
  if st.min ~= nil and st.min.reading ~= nil and st.min.reading < -lim then return true end
  return false
end

function fftsa.sg_overrange_text(range)
  local i = fftsa.range_to_idx(range)
  local lab = tostring(fftsa.range_labels[i])
  -- On the largest range, advise reducing the input rather than raising the range.
  local fix = "raise the range"
  if i >= table.getn(fftsa.ranges) then fix = "reduce the input" end
  return "OVERRANGE: values in the signal exceed the " .. lab .. " range -- " .. fix
end

-- Dash the peak table once per over-range transition.
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

function fftsa.model_name()
  if fftsa.model_str == nil then
    local m = nil
    if localnode ~= nil then m = localnode.model end
    if m == nil then m = "" end
    fftsa.model_str = tostring(m)
  end
  return fftsa.model_str
end

-- Model strings can include prefixes or suffixes.
function fftsa.is_7510()
  return string.find(fftsa.model_name(), "7510", 1, true) ~= nil
end

function fftsa.sg_dbmin_for(range, n)
  if range ~= nil and range <= fftsa.sg_dbmin_deep_vmax then
    if fftsa.is_7510() then return fftsa.sg_dbmin_deep end
    if n ~= nil and n >= fftsa.sg_dbmin_deep_n then return fftsa.sg_dbmin_deep end
  end
  return fftsa.sg_dbmin_std
end

function fftsa.sg_dbmin_set(range, n)
  if n == nil then n = fftsa.n end
  local want = fftsa.sg_dbmin_for(range, n)
  if want == fftsa.sg_dbmin then return false end
  fftsa.sg_dbmin = want
  return true
end

function fftsa.sg_pin_y(g)
  if g == nil then g = fftsa.sg_graph end
  if g == nil then return false end
  display.graph.scaley(g, display.YSCALE_OFF, display.AXIS_NORMAL,
                       fftsa.sg_dbmin, fftsa.sg_dbmax)
  return true
end

-- Axis writes repaint the graph. Coalesce gesture notifications and only restore limits that moved.
fftsa.sg_ev = 0        -- EVENT_SCALE fires since the tick last looked

-- Normalize limit movement against the larger of span and limit magnitude.
fftsa.sg_tol = 1e-6

fftsa.sg_seen_lo = nil
fftsa.sg_seen_hi = nil

-- Keep gesture reporting enabled when locked: the widget still pans and zooms.
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
  if scale <= 0 then return false end
  return (got - want) > scale * fftsa.sg_tol
      or (want - got) > scale * fftsa.sg_tol
end

function fftsa.sg_restore_y(g)
  if g == nil then g = fftsa.sg_graph end
  if g == nil then return false end
  local span = fftsa.sg_dbmax - fftsa.sg_dbmin
  local y1, y2 = display.graph.scaley(g)
  -- Either nil limit makes the read-back unusable.
  if y1 == nil or y2 == nil
     or fftsa.sg_moved(y1, fftsa.sg_dbmin, span)
     or fftsa.sg_moved(y2, fftsa.sg_dbmax, span) then
    -- A changed dB axis invalidates the slope/intercept used to write pixels.
    fftsa.sg_pix_stale('the dB axis moved')
    fftsa.sg_pin_y(g)
    return true
  end
  return false
end

-- When unlocked, an X gesture updates the applied span through the same clamp as Options.
function fftsa.sg_adopt_x(lo, hi)
  if lo ~= lo or hi ~= hi then return false end
  -- Round widget floats to whole hertz before updating the Options fields.
  local nlo, nhi = fftsa.span_clamp(math.floor(lo + 0.5), math.floor(hi + 0.5))
  -- Check the need to replan against the old span before assigning the new one.
  local replan = fftsa.plan_changed(nhi)
  fftsa.flo, fftsa.fhi = nlo, nhi
  if replan then
    -- Apply pins the new limits; pinning here would repaint twice.
    fftsa.sg_store_xrange(nlo, nhi)
    fftsa.retune_pending = true
  else
    fftsa.sg_set_xrange(nlo, nhi)
  end
  return true
end

function fftsa.sg_settle_x(g)
  if g == nil then g = fftsa.sg_graph end
  if g == nil then return false end
  local wlo, whi = fftsa.sg_xwant()
  if wlo == nil then return false end
  local x1, x2 = display.graph.scalex(g)
  if x1 == nil or x2 == nil then
    fftsa.sg_pix_stale('the frequency axis read back nil')
    fftsa.sg_pin_x()
    return true
  end
  if not (fftsa.sg_moved(x1, wlo, whi - wlo)
          or fftsa.sg_moved(x2, whi, whi - wlo)) then
    fftsa.sg_seen_lo, fftsa.sg_seen_hi = nil, nil
    return false
  end
  -- A moved X axis invalidates the pixel map even if the ring stays put.
  fftsa.sg_pix_stale('the frequency axis moved')
  if fftsa.sg_lock then
    fftsa.sg_seen_lo, fftsa.sg_seen_hi = nil, nil
    fftsa.sg_pin_x()
    return true
  end
  -- Adopt unlocked limits only after consecutive checks see the same pair.
  if fftsa.sg_seen_lo == nil
     or fftsa.sg_moved(x1, fftsa.sg_seen_lo, whi - wlo)
     or fftsa.sg_moved(x2, fftsa.sg_seen_hi, whi - wlo) then
    fftsa.sg_seen_lo, fftsa.sg_seen_hi = x1, x2
    return false
  end
  fftsa.sg_seen_lo, fftsa.sg_seen_hi = nil, nil
  return fftsa.sg_adopt_x(x1, x2)
end

function fftsa.sg_settle()
  local g = fftsa.sg_graph
  if g == nil then return false end
  -- Clear the event count before writing: pinning itself can raise EVENT_SCALE.
  fftsa.sg_ev = 0
  -- Restore Y first; settling X can invoke the application reconfiguration path.
  local wy = fftsa.sg_restore_y(g)
  local wx = fftsa.sg_settle_x(g)
  return wy or wx
end

function fftsa.sg_scale_check()
  if (fftsa.sg_ev or 0) == 0 then return false end
  return fftsa.sg_settle()
end

-- Poll gestures independently of the slower readout and icon updates.
fftsa.sg_scale_period = 0.15    -- seconds between gesture checks
fftsa.sg_tick_last  = nil
fftsa.sg_scale_last = nil
fftsa.sg_term_last  = nil

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
    -- Read FRONT/REAR here because it changes outside the Options form.
    local term = fftsa.terminal_text()
    if term ~= fftsa.sg_term_last then
      fftsa.sg_term_last = term
      fftsa.sg_write_xunit()
    end
    if fftsa.overrange ~= fftsa.sg_over_shown then
      fftsa.sg_over_shown = fftsa.overrange
      fftsa.sg_write_xunit()
    end
    fftsa.sg_show_thd()
    did = true
    heavy = true
  end
  -- Return whether work ran and whether the display needs time to paint it.
  return did, heavy
end

function fftsa.sg_rebind()
  return fftsa.sg_bind()
end

-- Yield after refill so the display task can paint. Keep the startup yield separate.
fftsa.sg_yield = 0.010
fftsa.sg_first_paint = 0.25
fftsa.sg_seed_spread = 2
-- Allow the screen switch to settle before deleting the outgoing screen.
fftsa.sg_scr_yield = 0.15

fftsa.sg_pk_period = 1.0        -- seconds between refreshes
fftsa.sg_pk_ftol   = 0.002      -- fractional frequency move worth a redraw
fftsa.sg_pk_vtol   = 0.01       -- fractional amplitude move worth a redraw
fftsa.sg_pk_last   = nil
fftsa.sg_pk_lf     = {}
fftsa.sg_pk_lv     = {}

fftsa.sg_peaks_off = false      -- disables the peak table, to attribute display traffic

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

-- Draw each interpolated peak as a narrow line needle; sort by frequency.
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
  -- Bracket each peak with floor points one plot pixel away.
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

-- Refresh on cadence only if a peak changed enough to matter.
function fftsa.sg_show_peaks(bi, bv, count, binhz, pk_hz, pk_v)
  if fftsa.sg_peaks_off then return false end
  -- Force the first valid redraw after an over-range frame erased the readouts.
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
      moved = true
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

fftsa.sg_uv_fmt_std  = "%0.0f uVrms"
fftsa.sg_uv_fmt_fine = "%0.1f uVrms"
fftsa.sg_uv_fine_vmax = 1        -- the largest range that gets the decimal

function fftsa.sg_uv_fmt(range)
  if range ~= nil and range <= fftsa.sg_uv_fine_vmax then return fftsa.sg_uv_fmt_fine end
  return fftsa.sg_uv_fmt_std
end

-- Convert the voltage readout to RMS; the dBV column keeps the graph's reference.
local SG_PK_RMS = 1 / math.sqrt(2)

function fftsa.sg_show_peaks_now(bi, bv, count, binhz, pk_hz, pk_v)
  local log10, settext = math.log10, display.settext
  for p = 1, count do
    local f, v = fftsa.sg_peak_at(p, bi, bv, binhz, pk_hz, pk_v)
    if f ~= nil then
      local ftxt
      if f ~= f then ftxt = string.format("%d  ---", p)
      elseif f >= 1000 then ftxt = string.format("%d  %.3f kHz", p, f / 1000)
      else ftxt = string.format("%d  %.1f Hz", p, f) end
      local vtxt, dtxt
      if v ~= v then vtxt, dtxt = "", ""
      elseif v > fftsa.sg_vmax_real then vtxt, dtxt = "---", "--- dBV"
      else
        local rms = v * SG_PK_RMS
        -- Choose volts before a millivolt value rounds to 1000.00.
        if rms >= 0.999995 then vtxt = string.format("%.4f Vrms", rms)
        elseif rms >= 1e-3 then vtxt = string.format("%.2fmVrms", rms * 1e3)
        else vtxt = string.format(fftsa.sg_uv_fmt(fftsa.range), rms * 1e6) end
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
