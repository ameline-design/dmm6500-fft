-- spectrum_app.tsp -- interactive standalone spectrum analyser for the DMM6500
--
-- The touch options form and the run loop, over fft_core.tsp, spectrum_ui.tsp and
-- spectrum_graph.tsp. The stop frequency sets the sample rate -- smallest exact rate at
-- or above 2x stop, with a 100 kS/s floor -- and the start frequency only windows the
-- display.
--
-- Every screen and field is created once in start(), behind the loading cover, and
-- deleted once by stop(); a press only ever switches screens. A create/delete cycle
-- risks part of the 463-object pool for the rest of the power cycle, because a refused
-- display.delete raises nothing. The capture buffer and the frame timer are the
-- exceptions.

fftsa = fftsa or {}   -- the single global this app exposes

-- Capability gate.  Two tiers on this branch, from fastest to slowest:
--   1. our own compiled PPC DSP (no flicker, no Keithley clear). nl.ready is set by
--      nl.init() from fftsa.start(); it stays false until the binary is installed.
--   2. Keithley's native dsp.* module (fast, but clears sg_buf before each fill).
--
-- The Lua fallback that was tier 3 is not in the archive on this branch: the DSP work is
-- done in C, so shipping a second full implementation in interpreted Lua only costs
-- script size. tsp/dsp_lua.tsp still exists and still builds on main, it is just not in
-- tools/package_tspa.py's MODULES here.
--
-- So dsp_install may be nil, and the gate must not call it. An instrument without
-- Keithley's dsp module gets a refusal it can act on rather than a -286 at load from
-- calling a nil, which is what reaching for the absent fallback would produce.
fftsa.dsp_native = (dsp ~= nil and dsp.version ~= nil and dsp.version >= 1)
if not fftsa.dsp_native then
  if type(fftsa.dsp_install) == 'function' then
    fftsa.dsp_install()
    fftsa.dsp_native = (dsp ~= nil and dsp.version ~= nil and dsp.version >= 1)
  else
    fftsa.dsp_absent = true
  end
end

-- nl.ready is set by fftsa.nl.init() inside fftsa.start().  It is false here at
-- load time so the frame body starts on the existing path without waiting.
-- native_link.tsp is concatenated before this file in the package order.

-- Here and not in fft_core.tsp because tools/package_tspa.py concatenates the modules into
-- one loadscript chunk in a fixed order and there is no runtime module loading on this
-- instrument: both implementations are in the archive for ever and this only decides which
-- binds the name. tsp/dsp_lua.tsp sits ahead of this file in that order, so the installer
-- exists before the gate runs.

-- THE WINDOW ENUM IS NOT THE PICKER INDEX. It currently coincides -- dsp.WINDOW_HANN is 1
-- and fftsa.win_names[1] is "Hann", with WINDOW_RECT at 0 excluded, which is the only reason
-- the off-by-one never shows. Twenty-five call sites drive the options form and the settings
-- line off the index, so an enum numbered differently in the firmware would select the wrong
-- window with nothing on the glass to say so: every amplitude out by a scalloping factor.
-- Mapped rather than assumed, in both directions, one map each side of the seam. Built from
-- whatever dsp.WINDOW_* turn out to be, which is why it sits after the gate.
--
-- Index-parallel to fftsa.win_names: a window added to one and not the other falls back to
-- Hann without saying so, which is what the length check in the proto suite is for.
--
-- GUARDED, because dsp CAN be nil and this is load-time code. The gate above sets
-- fftsa.dsp_absent in that case and said so; the next statement then indexed the nil
-- anyway. Measured on 1.7.17a, which has NO FIRMWARE dsp MODULE: with dsp_lua.tsp left out
-- of the module list this file raised "-286 attempt to index global `dsp'" at this line
-- while the archive was still loading, so every function below it was never defined and
-- fftsa.start was nil. The refusal the gate promised has to be a refusal, not a raise.
fftsa.win_dsp = {}
if not fftsa.dsp_absent then
  fftsa.win_dsp[1] = dsp.WINDOW_HANN
  fftsa.win_dsp[2] = dsp.WINDOW_BLACKMAN
  fftsa.win_dsp[3] = dsp.WINDOW_BLACKMAN_HARRIS
  fftsa.win_dsp[4] = dsp.WINDOW_KAISER
end

function fftsa.win_to_dsp(wi)
  local k = fftsa.win_dsp[wi or fftsa.win_i]
  if k == nil then k = fftsa.win_dsp[1] end
  return k
end

-- The harmonic rules are the app's, not an implementation default. Their own names because
-- fftsa.thd_hmax, thd_nsample and thd_mains are where the primitive puts the ones it used.
-- After the gate, the mains selection being one of its enums.
fftsa.thd_hmax_want  = 20              -- harmonics counted; the window top usually stops first
fftsa.thd_bins_want  = 1024            -- bins sampled for the floor; 0 means every bin
-- -1 is DSP_THD_MAINS_BOTH and is what dsp.MAINS_BOTH is set to, taken literally here for
-- the same reason as the window map above: this is load-time code and dsp can be nil.
fftsa.thd_mains_want = -1              -- hum discounted at 50 and at 60 Hz
if not fftsa.dsp_absent and dsp.MAINS_BOTH ~= nil then
  fftsa.thd_mains_want = dsp.MAINS_BOTH
end

-- A refusal as something that can go on the glass. The primitives post an event and return a
-- negative code, and "-2" tells an operator nothing; dsp.lastevent() carries the reason the
-- implementation posted. fftsa.options_apply writes this behind "APPLY FAILED:" and
-- fftsa.frame puts its first 60 characters behind the HALTED banner.
--
-- The code is compared as well as read: an older event still in the log is not this
-- refusal's reason, and a wrong reason reads exactly like a right one.
function fftsa.dsp_why(what, code)
  local msg = tostring(what) .. " refused (" .. tostring(code) .. ")"
  local e = dsp.lastevent()
  if e ~= nil and e.why ~= nil and e.code == code then
    msg = msg .. ": " .. tostring(e.why)
  end
  return msg
end

-- Every table, window and twiddle is sized from the selected power-of-two count.
--
-- Two defaults, chosen between in start(). On the compiled path everything below 4096 runs
-- at the same measured frame rate, because what sets it there is per-frame work independent
-- of the count -- so 2048 is twice the resolution of 1024 for nothing, 48.8 Hz bins against
-- 97.7 at 100 kS/s. The interpreted primitive does scale with the count, so 1024 is what to
-- open at when the compiled path will not be there.
--
-- 32768 is the largest the arena can serve: dsp_plan_segs(32768, 1, FOURSTEP, 32736) is 26
-- segments against the 32 of DSPN_MAX_SEGS, and 65536 does not lay out at all. Six entries
-- either way, which the option field needs.
fftsa.n          = 1024
fftsa.n_compiled = 2048
fftsa.sample_counts = {1024, 2048, 4096, 8192, 16384, 32768}
fftsa.sample_labels = {"1024", "2048", "4096", "8192", "16384", "32768"}

-- Will the compiled path install on this instrument? What it needs is the blob in the
-- archive, the sizes the generated module carries with it, and the memory interface the
-- install goes through. None of that depends on the firmware build, so there is no
-- version to consult and this costs three tests.
--
-- Necessary and not sufficient: the install can still fail, and a boot that has already
-- spent one refuses a second. So this decides a default and never a correctness question,
-- and a wrong answer costs a slower first screen rather than a wrong spectrum.
function fftsa.native_likely()
  local nl = fftsa.nl
  if nl == nil then return false end
  if nl.SIZEOF_REAL == nil or nl.SIZEOF_REAL == 0 then return false end
  if nl._DSP_CODE_B64 == nil or nl._DSP_CODE_B64_LEN == 0 then return false end
  if ki == nil or ki.memwrite == nil or ki.poke32 == nil then return false end
  return true
end

-- Floor for the start frequency. A start of 0 would admit bin 1, which is DC and,
-- with the mean removed by fftsa.fft_load(), holds only window leakage.
fftsa.flomin  = 10          -- floor for the start frequency (Hz)
fftsa.flo     = 10          -- display start frequency (Hz)
fftsa.fhi     = 50000       -- display stop frequency (Hz)
-- Nyquist at the fastest rate, so this is the widest view the hardware can give.
-- The low end is well under the slowest rate, so a stop down here narrows the view
-- rather than the bin: 500 Hz holds 40 bins at the smallest count and about 1280 at
-- the largest, drawn into 255 columns either way.
fftsa.fhi_max = 500000
fftsa.fhi_min = 500
-- Ceiling for the start, a kilohertz under the stop's so the form cannot be set to a span
-- of nothing. It is the Start field's own max, and span_clamp holds a gesture to the same
-- line: without that, a pinch high up the range could hand Options a start its own field
-- would refuse.
fftsa.flo_max = fftsa.fhi_max - 1000
fftsa.range   = 10          -- digitizer input range (V): 0.1 / 1 / 10
fftsa.fs      = 100000      -- sample rate (picked from fftsa.fhi, then measured)
fftsa.binhz   = 0           -- true bin width, from measured fs
fftsa.busy    = false       -- reentrancy guard (never preserved across a reload)
fftsa.stop_pending = false  -- a teardown deferred until the running frame ends
fftsa.retune_pending = false -- a gesture's span, waiting for its re-plan between frames
fftsa.halted  = false       -- frames suppressed after repeated failures
fftsa.lasterr = nil         -- last frame error, nil if none
fftsa.errcount = 0          -- count of dropped frames
fftsa.errrun  = 0           -- consecutive dropped frames
fftsa.errmax  = 20          -- give up (and say so) after this many in a row
fftsa.shortreads = 0        -- captures rejected for returning fewer than n samples

-- What the Reset button restores, captured from the assignments that set the six form
-- fields rather than restating their values: one owner per setting, so a changed default
-- cannot disagree with what the button offers. The capture is sound because every one of
-- those assignments is unconditional -- fftsa = fftsa or {} inherits the previous launch's
-- table, and an `or` on any of them would make this the last session's settings.
fftsa.defaults = {flo = fftsa.flo, fhi = fftsa.fhi, range = fftsa.range,
                  win_i = fftsa.win_i, kbeta_i = fftsa.kbeta_i, n = fftsa.n}

-- The legal span, for anything that asks for one: the Options form and an unlocked graph
-- gesture both come through here, or the form would offer a range a gesture could not
-- reach. Each end clamps to its own field's declared range, then the pair is ordered -- a
-- stop at or below the start holds no bins. One repair settles the order whatever the four
-- clamps did, and does so because fhi_min is wholly above flomin: the stop is already at or
-- above fhi_min by then, so dropping the start to flomin always leaves start < stop.
function fftsa.span_clamp(lo, hi)
  local nlo, nhi = lo, hi
  -- NaN first, or it passes through as a pair that is neither in range nor ordered: every
  -- comparison below is false for one. Tested against itself, NaN being the only value not
  -- equal to itself; repaired to the floors, which is the narrowest legal span. Callers
  -- should still refuse a NaN rather than adopt this, and sg_adopt_x does -- but the
  -- postcondition belongs here, where it holds for any two numbers whatever.
  if nlo ~= nlo then nlo = fftsa.flomin end
  if nhi ~= nhi then nhi = fftsa.fhi_min end
  if nhi > fftsa.fhi_max then nhi = fftsa.fhi_max end
  if nhi < fftsa.fhi_min then nhi = fftsa.fhi_min end
  if nlo < fftsa.flomin then nlo = fftsa.flomin end
  if nlo > fftsa.flo_max then nlo = fftsa.flo_max end
  if nlo >= nhi then nlo = fftsa.flomin end
  return nlo, nhi
end

-- Firmware handles, initialised only on the first load: opening the App again in
-- one power session re-runs this body, and clearing a live handle would strand the
-- previous launch's objects. fftsa.start()'s opening fftsa.stop() reclaims them.
if fftsa.handles_inited == nil then
  fftsa.cap      = nil      -- acquisition buffer
  fftsa.cap_cap  = nil      -- readings it was made for
  fftsa.optbtn   = nil      -- Options (cog) button on the spectrum screen
  fftsa.optimg   = nil      -- cog image drawn over it
  fftsa.lockbtn  = nil      -- Lock button beside it
  fftsa.lockimg_c = nil     -- closed-padlock image over the Lock button
  fftsa.lockimg_o = nil     -- open-padlock image over it; one of the pair is visible
  fftsa.timer    = nil      -- periodic timer driving frames
  fftsa.errscr   = nil      -- error screen shown if startup fails
  fftsa.optscr   = nil      -- options form screen
  fftsa.opt_flo  = nil      -- Start Frequency edit field
  fftsa.opt_fhi  = nil      -- Stop Frequency edit field
  fftsa.opt_rng  = nil      -- Input Range edit-option field
  fftsa.opt_win  = nil      -- Window edit-option field
  fftsa.opt_beta = nil      -- Kaiser Beta edit-option field
  fftsa.opt_n    = nil      -- FFT sample-count edit-option field
  fftsa.opt_info = nil      -- read-back info line on the options screen
  fftsa.handles_inited = true
end

-- The span picks the rate, and a narrow span picks a slow one: bin width is fs/n, so the
-- rate is the only way to narrow a bin without changing the transform.
--
-- The cost is aliasing, and the aperture cannot mitigate it -- it clamps at 10 us, whose
-- boxcar first nulls at 100 kHz, so it attenuates nothing near the 6.25 kHz folding
-- frequency of the slowest rung. Content above the chosen Nyquist folds in at full
-- amplitude with nothing on the glass to say so, and a narrow span is the view most
-- exposed to it.
--
-- Each rate declares the highest stop frequency it may serve, and pick_fs takes the
-- slowest that covers the span. The ceilings are Nyquist on the four fast rungs and under
-- it on the three slow ones, which is where folding reaches ordinary signals: 5 kHz against
-- a 6.25 kHz Nyquist, 12 kHz against 12.5, 25 kHz against 25.
--
-- Exact rates only: the delivered rate is 66e6/ceil(66e6/request), so only a divisor of
-- 66e6 arrives as asked -- 5280 for 12500, 2640 for 25000, 1320 for 50000 -- while 102400
-- is read back verbatim and delivered as 102325.5, putting every bin 0.073 % out. A gate
-- holds the whole ladder to that division.
fftsa.rates    = {12500, 25000, 50000, 100000, 200000, 500000, 1000000}
fftsa.rate_fhi = { 5000, 12000, 25000,  50000, 100000, 250000,  500000}
fftsa.fs_min   = fftsa.rates[1]

-- Slowest rate whose ceiling covers the stop frequency. A NaN stop compares false against
-- every ceiling and lands on the fastest rate, which is the one that cannot alias.
function fftsa.pick_fs(fhi)
  local r = fftsa.rates
  local n = table.getn(r)
  for i = 1, n do
    if fftsa.rate_fhi[i] >= fhi then return r[i] end
  end
  return r[n]
end

-- Does a new stop frequency need the hardware re-planned? The digitizer runs at the lowest
-- rate whose Nyquist covers the stop, so a stop inside the rate in force changes only which
-- bins are plotted: one axis write, no capture. Planned rate against planned rate, never
-- against fs_acq, which holds the rate MEASURED off the timestamps and never equals one.
function fftsa.plan_changed(fhi_new)
  return fftsa.pick_fs(fhi_new) ~= fftsa.pick_fs(fftsa.fhi)
end

-- Boolean fields are an EDIT_OPTION of two, matching the other fields on the form rather
-- than using display.OBJ_EDIT_CHECK. Index 1 is off, so a field the pool refused reads as
-- off through fftsa.getval's fallback.
fftsa.onoff_labels = {"Off", "On"}

function fftsa.onoff_to_idx(v)
  if v then return 2 end
  return 1
end

fftsa.ranges       = {0.1, 1, 10}
fftsa.range_labels = {"0.1 V", "1 V", "10 V"}

function fftsa.range_to_idx(r)
  for i = 1, table.getn(fftsa.ranges) do
    if fftsa.ranges[i] == r then return i end
  end
  return 3
end

-- getvalue() on an OBJ_EDIT_OPTION returns the 1-based index, but it can also come
-- back as the option's own label, so both are read. Anything outside the list
-- clamps: an index used raw would otherwise fetch a nil option.
function fftsa.opt_index(v, labels, fallback)
  local n = table.getn(labels)
  if type(v) == "string" then
    for j = 1, n do
      if v == labels[j] then return j end
    end
    v = tonumber(v)
  end
  if v == nil then return fallback end
  v = math.floor(v + 0.5)
  if v < 1 then v = 1 end
  if v > n then v = n end
  return v
end

function fftsa.idx_to_range(v)
  local i = fftsa.opt_index(v, fftsa.range_labels, fftsa.range_to_idx(fftsa.range))
  return fftsa.ranges[i]
end

-- Falls back rather than raising. A count off the list can only arrive from a host
-- assignment, and raising here took Options and Apply down together with no way back
-- but End App: both paths call this before they can show anything.
function fftsa.sample_to_idx(n)
  for i = 1, table.getn(fftsa.sample_counts) do
    if fftsa.sample_counts[i] == n then return i end
  end
  return 1
end

function fftsa.options_samples()
  local i = fftsa.opt_index(fftsa.getval(fftsa.opt_n), fftsa.sample_labels,
                           fftsa.sample_to_idx(fftsa.n))
  return fftsa.sample_counts[i]
end

-- The DIGITIZER's rate, from the capture's own timestamps. The fallback is fs_acq, not
-- fftsa.fs: fftsa.fs is the decimated rate and returning it here would divide it twice.
function fftsa.measure_fs(buf)
  local back = fftsa.fs_acq or fftsa.fs
  local n = buf.n
  if n < 4 then return back end
  local t1, tN = buf.relativetimestamps[1], buf.relativetimestamps[n]
  if tN <= t1 then return back end
  return (n - 1) / (tN - t1)
end

-- The clamped frame-class counts, recomputed every frame so every knob stays live. Both are
-- clamped to what was built, being refused above it. The peak count is returned so the
-- display loops ask for the same number -- read separately, a raised sg_npeak asks
-- dsp.peak() for a peak it never found, and that posts an event per peak per frame.
--
-- This writes no dsp.* attribute. The eleven of them the interpreted primitive reads are
-- pushed by dsp_live_push, which runs immediately before that primitive and nowhere else:
-- the compiled path reads none of them, taking fftsa.live_ncol and fftsa.live_npk and the
-- axis fields straight from Lua, so on a recognised firmware -- where the compiled path
-- serves every count -- writing them once a frame was eleven property writes into the
-- interpreter that nothing afterwards read. Pushing at the point of use rather than once a
-- frame keeps every one of them live, which is what writing them all together was for.
function fftsa.dsp_live()
  local ncol = fftsa.sg_ncol
  local cap = nil
  if fftsa.sg_buf ~= nil then cap = fftsa.sg_buf.capacity end
  if cap ~= nil and ncol ~= nil and ncol > cap then ncol = cap end
  if ncol == nil or ncol < 2 then ncol = 2 end
  -- Kept for the native path, which has no dsp.out to read back: these are the CLAMPED
  -- counts, and a second clamp elsewhere is how the trace and the primitive end up
  -- disagreeing about how many points there are.
  fftsa.live_ncol = ncol
  -- Ceiling is the rows build() made: a row that does not exist cannot be written.
  local npk = fftsa.sg_npeak
  local rows = nil
  if fftsa.sg_pk_f ~= nil then rows = table.getn(fftsa.sg_pk_f) end
  if rows ~= nil and rows > 0 and npk > rows then npk = rows end
  if npk == nil or npk < 1 then npk = 1 end
  fftsa.live_npk = npk
  return npk
end

-- Hand dsp_live's counts and the plot's own limits to the interpreted primitive. Called
-- from dsp_commit() and from spectrum_interp(), so nothing reaches dsp.spectrum or
-- dsp.commit without them current.
function fftsa.dsp_live_push()
  dsp.out.segments = fftsa.live_ncol
  -- The plot's own axis, so trace, peak column and noise figure share one floor.
  dsp.out.dbfloor = fftsa.sg_dbmin
  dsp.out.dbceil  = fftsa.sg_dbmax
  dsp.out.vfloor  = fftsa.sg_vfloor
  dsp.peaks.count = fftsa.live_npk
  -- The harmonic rules, or a native dsp's own defaults move all three figures on switch day.
  dsp.thd.harmonics = fftsa.thd_hmax_want
  dsp.thd.bins      = fftsa.thd_bins_want
  dsp.thd.mains     = fftsa.thd_mains_want
end

-- The only route to the interpreted primitive, so the attributes it reads cannot be left
-- behind by a caller that forgot them. Every fallback in the frame goes through here.
function fftsa.spectrum_interp(cap, buf)
  -- THERE IS NOTHING TO FALL BACK TO. The archive ships no interpreted transform, so a
  -- demotion from the compiled path is the end of the line: halt and say so once. Without
  -- this the frame carries on, dsp.spectrum posts EUNSUPPORTED and then dsp.peak posts
  -- "no spectrum yet" once per peak per frame, behind a panel that looks alive.
  if fftsa.fft_init == nil then
    if not fftsa.halted then
      fftsa.halted = true
      fftsa.lasterr = 'the compiled DSP stopped and this archive has no interpreted fallback'
      fftsa.say('HALTED: ' .. fftsa.lasterr)
    end
    return nil
  end
  fftsa.dsp_live_push()
  fftsa.dsp_window()
  return dsp.spectrum(cap, buf, nil)
end

-- The plotted window, written per frame. An adopted gesture moves the axis without re-planning, so a
-- window written only at Apply leaves the trace, the peaks and the THD figures on the span
-- before it -- every frequency on the plot mislabelled. Frame attributes, so this dirties
-- nothing. From the stored axis range, which is what the widget was pinned to.
function fftsa.dsp_window()
  local lo, hi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if lo == nil or hi == nil or not (hi > lo) then return false end
  dsp.out.lowfreq  = lo
  dsp.out.highfreq = hi
  return true
end

-- ---------------------------------------------------------------------------
-- The native path's plumbing. Three things the compiled primitive cannot discover for
-- itself: where the two buffers keep their chunk storage, which bins the plotted span
-- covers, and the bin width this capture actually delivered.
-- ---------------------------------------------------------------------------

-- The largest sample count the native arena is built for, which is every count the app
-- offers. No array has to fit a chunk whole: dsp_plan_init_segs slices one that does not,
-- and the transform reads the capture in place rather than de-striding it into n contiguous
-- doubles. What bounds the count is the number of chunks dsp_plan_segs reports, and nl.init
-- refuses a count the image cannot serve. A refusal leaves nl.ready false and the app runs
-- on Keithley's dsp.*, which is also what an arena that cannot be allocated gives.
--
-- This is what nl.init is given, NOT fftsa.n: the arena is sized once per boot and
-- nl.reinit re-plans inside it for every count at or below, which is what makes a sample
-- count press cost one call instead of an install.
fftsa.nl_nmax = 32768

-- The count the acquisition buffer's capacity is floored at. At nl_nmax one allocation
-- serves every count, so the buffer's object identity never changes and the content scan
-- that finds its storage -- a sweep of the whole heap window, seconds of ki.memread -- runs
-- once per boot rather than once per step up to a longer record. At nl_nmax of 32768 the
-- price is 131,072 readings held for the life of the app, about 3.2 MB of a 200 MB window,
-- and it buys an Apply that sweeps nothing at any count.
fftsa.cap_floor_n = fftsa.nl_nmax

-- OFF, AND FOR ONE REASON: THE GRAPH DOES NOT REDRAW FROM AN IN-PLACE WRITE.
--
-- Everything else about the native path is measured and correct. On the instrument it
-- installs, plans, re-plans through nl.reinit across a sample-count press, computes the
-- whole frame in 3.1 ms where the interpreted phases are 32.6 ms between them, and leaves a
-- trace buffer holding 255 (dB, Hz) points at the right frequencies with the descriptor
-- rewound so buf.n reads 255. Lua reads those points back correctly. THE WIDGET DOES NOT.
--
-- Three notify calls were tried, same conditions, five frames each:
--
--   display.graph.scaletrace   126.6 ms a frame, and it unpins both axes
--   display.graph.drawstyle     46.6 ms a frame, axes correct, nothing drawn
--   none at all                 21.4 ms a frame, axes correct, nothing drawn
--
-- spectrum_graph.tsp:69 said why before any of them was tried: the clear is the only notify
-- compatible with FILL_ONCE, and not clearing is the entire point of writing in place. The
-- remaining lever is the buffer's fill mode, and FILL_ONCE is a tested invariant in
-- tools/test_tsp.lua -- "the trace buffer is FILL_ONCE, never a ring" -- so changing it
-- needs the wrap-line artefact measured on the glass first, not argued away.
--
-- ON, TO BE TESTED FROM THE KEY, which is the install path none of the above was measured
-- on. Every one of those three readings came from tools/run_app.py, which pushes the
-- modules over the control socket -- and on that path the whole display EVENT system was
-- measured dead afterwards: a brand new OBJ_TIMER fired zero times in four seconds, and
-- zero during a blocking delay(3), while painting carried on normally. Both buttons were
-- dead too. So "the widget does not re-read the buffer" and "nothing in the display
-- dispatches at all" are not separated yet, and the second explanation fits every
-- observation including the ones that have nothing to do with the native path.
--
-- Installed from the key the firmware's own installer runs, the loadimage blocks register,
-- and there is no socket session holding the instrument. If the trace draws there, the
-- conclusion above was an artefact of the harness.
fftsa.nl_enable = true

-- fftsa.thd_mains_want holds Keithley's dsp.MAINS_* value and the native side takes
-- DSP_THD_MAINS_*, which is 50, 60, 0 or BOTH. Those three are the mains frequencies
-- themselves, so they carry across whatever the firmware numbered its enum; anything else
-- is taken as BOTH, which is this app's default and the only other thing it offers.
function fftsa.mains_native(v)
  if v == 50 or v == 60 or v == 0 then return v end
  return fftsa.nl.MAINS_BOTH
end

-- Chunk storage for the capture. This runs at Apply and never in a frame. describe() is
-- called every time, because the chunk vector lengthens as a longer record lands in the
-- same allocation and a chunk outside the window is refused on every frame. It is cheap to
-- call again: describe() sweeps the heap twice, once for the storage and once for the
-- descriptor, and caches both -- the first against the buffer, the second against the
-- storage address -- so a repeat call re-reads the descriptor's words and nothing else.
-- Only a replaced buffer pays either sweep, and the capture buffer is never replaced.
--
-- The trace buffer is not scanned for at all. Its points reach the graph through
-- buffer.write.reading -- the display task draws from its own copy of a bound buffer and
-- that call is what feeds it -- so the primitive has no reason to know where the buffer
-- keeps its elements, and asking would cost a second scan at startup.
--
-- The second argument says whether the buffer stores extra values, and it is this code's
-- answer rather than something describe() may discover: reading .extravalues on a
-- STYLE_STANDARD buffer posts event 4927, for which the firmware puts a modal dialog on the
-- glass over the running app. pcall is no defence -- it posts where it does not raise. The
-- capture is STYLE_STANDARD.
function fftsa.nl_bind()
  local nl = fftsa.nl
  if nl == nil or not nl.ready or fftsa.cap == nil or fftsa.sg_buf == nil then
    fftsa.nl_cap = nil
    return false
  end
  fftsa.nl_cap, fftsa.nl_cap_of = nil, nil
  local c = nl.describe(fftsa.cap, false)
  if c == nil then return false end
  fftsa.nl_cap, fftsa.nl_cap_of = c, fftsa.cap
  return true
end

-- Is the native path usable for the plan in force? Tested every frame, so it is
-- comparisons and no work. nl.n is the count the arena was last planned for, which only
-- nl.reinit moves, so this catches a sample count the install cannot serve.
function fftsa.nl_usable()
  if not fftsa.nl_enable then return false end
  local nl = fftsa.nl
  if nl == nil or not nl.ready then return false end
  if nl.n ~= fftsa.n then return false end
  return fftsa.nl_cap ~= nil
end

-- The reduction, per frame. The table is allocated once and refilled: the house rule is to
-- allocate at Apply and never in a frame.
function fftsa.nl_reduction(binhz)
  local r = fftsa.nl_redt
  if r == nil then r = {}; fftsa.nl_redt = r end
  local kmin, kmax = fftsa.sg_window_bins(fftsa.sg_nbins, binhz,
                                          fftsa.sg_flo_hz, fftsa.sg_fhi_hz)
  -- One based there, zero based here. sg_window_bins counts bins the way the Lua
  -- implementation indexes its power array, from 1; dsp_reduce indexes from 0. Getting
  -- this wrong shifts the whole trace by one bin, which no plot would show.
  r.k0, r.k1 = kmin - 1, kmax - 1
  r.nseg   = fftsa.live_ncol
  r.npk    = fftsa.live_npk
  r.binhz  = binhz
  -- No decimation on this path yet, so bin k is at k * binhz and frequency rises with the
  -- index. dsp_reduce reverses the trace itself for an odd Nyquist zone, which is what
  -- sense is for; nothing here produces one.
  r.f0     = 0
  r.sense  = 1
  r.dbmin  = fftsa.sg_dbmin
  r.dbmax  = fftsa.sg_dbmax
  r.vfloor = fftsa.sg_vfloor
  r.mains  = fftsa.mains_native(fftsa.thd_mains_want)
  return r
end

-- Apply the current settings to the hardware and the graph. Safe to repeat: the
-- capture buffer is resized when needed; the graph keeps its original buffer.
-- dsp.commit() rebuilds the window and its interpolation tables, which is the slow part of a
-- press -- 0.163 ms a sample, so 83 ms at 512 and a measured 2.667 s at 16384 -- hence the
-- cover. It rebuilds nothing when neither the count, the window nor the beta moved, which is
-- every adopted gesture and most presses: every attribute below is rewritten
-- unconditionally, and a write that does not CHANGE the value dirties nothing.
function fftsa.apply()
  -- fs_acq is the digitizer's rate and fftsa.fs the rate the transform sees. They are equal
  -- with no filter in the path, and kept separate because everything downstream -- binhz,
  -- the settings line, the span arithmetic -- reads fftsa.fs.
  fftsa.fs_acq = fftsa.pick_fs(fftsa.fhi)
  dsp.fft.samples    = fftsa.n
  dsp.fft.window     = fftsa.win_to_dsp(fftsa.win_i)
  dsp.fft.beta       = fftsa.kbeta(fftsa.kbeta_i)
  -- The rate the digitizer is ABOUT to be set to. commit() needs it before any capture
  -- exists, because the bin width and srclength follow from it.
  dsp.fft.samplerate = fftsa.fs_acq
  -- Written every Apply, not left at the default: the app offers no filter, and something
  -- setting it over the socket would otherwise survive the next press.
  dsp.filter.state = dsp.OFF
  -- From fftsa.flo/fhi, not the stored axis dsp_window() reads: the pin below is what puts
  -- the axis on this pair, so the stored one still holds the previous span here.
  dsp.out.lowfreq  = fftsa.flo
  dsp.out.highfreq = fftsa.fhi
  -- The axis floor follows the range: a DMM7510 plots to -140 dBV on 1 V and 0.1 V, where its
  -- noise floor measures -129 and -134. Ahead of dsp_live(), whose floor dsp_live_push hands
  -- to the primitive, and ahead of the capture for the same reason the X pin is; the pin is
  -- conditional because an axis write costs 60 ms.
  if fftsa.sg_dbmin_set(fftsa.range) then fftsa.sg_pin_y() end
  fftsa.dsp_live()
  -- dsp.commit() rebuilds from these, so they are pushed here and not left to the first
  -- frame that happens to need the interpreted primitive.
  fftsa.dsp_live_push()
  local rc = dsp.commit()
  if rc ~= dsp.OK then error(fftsa.dsp_why("commit", rc), 0) end
  local need = dsp.fft.srclength
  fftsa.fs = fftsa.fs_acq
  -- Before the sg_set_xrange() below, which reads it: the settings line counts the bins
  -- inside the span, and that count is computed from sg_nbins.
  fftsa.sg_nbins = fftsa.n / 2
  -- NOTHING ABOUT THE INSTRUMENT'S STATE MAY BE ASSUMED HERE. An autoexec script runs before
  -- any of this and can leave the DMM on any function, with a trigger model running, and with
  -- a user buffer current. So the app takes the instrument rather than adjusting it:
  --
  --   abort first, because a model left running owns the digitizer, and
  --   the FUNCTION FIRST, because measure and digitize are mutually exclusive and every
  --   digitize attribute below is refused with event 2800 while a measure function is live.
  --
  -- Measured on 1.7.17a from the state a power cycle leaves (measure DC voltage, digitize
  -- idle): abort on an empty model is quiet, and so is this switch, which flips
  -- dmm.measure.func to FUNC_NONE. Both post nothing, so neither needs a state test first --
  -- and a state test is the wrong shape anyway, since the point is not to depend on the state.
  trigger.model.abort()
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = fftsa.range
  dmm.digitize.samplerate = fftsa.fs_acq
  -- The bin width commits with the rate, not after the capture: a capture that fails
  -- between the two -- a trigger timeout is the obvious one -- would otherwise leave the
  -- hardware at the new rate and fftsa.binhz at the old one. The measurement below
  -- refines it by about 0.01 %.
  fftsa.binhz = fftsa.fs / fftsa.n
  -- The span is fftsa.flo/fhi, committed by options_apply(), so the axis is pinned before
  -- the capture rather than after it.
  fftsa.sg_set_xrange(fftsa.flo, fftsa.fhi)
  dmm.digitize.aperture   = 1e-6
  -- srclength read back rather than assumed to be fftsa.n: it is the primitive that decides
  -- how long a record it consumes, and under-acquiring would short-read every frame.
  dmm.digitize.count      = need
  -- Capacity, never the record length, and floored at the longest record the app offers, so
  -- the same allocation serves every count and the buffer is made once per boot. Replacing
  -- it is what moves its storage, and finding storage again is a heap sweep of seconds; the
  -- grow-and-never-shrink rule below is kept for a floor that is ever lowered.
  local want = need
  if want < fftsa.cap_floor_n then want = fftsa.cap_floor_n end
  want = want * 4
  if fftsa.cap ~= nil and (fftsa.cap_cap == nil or fftsa.cap_cap < want) then
    fftsa.del_buf(fftsa.cap)
    fftsa.cap = nil
  end
  if fftsa.cap == nil then
    fftsa.cap     = buffer.make(want, buffer.STYLE_STANDARD)
    fftsa.cap_cap = want
  end
  fftsa.cap.clear()
  dmm.digitize.read(fftsa.cap)
  -- Measured from the capture's own timestamps: the samplerate read-back is unreliable.
  fftsa.fs_acq = fftsa.measure_fs(fftsa.cap)
  fftsa.fs     = fftsa.fs_acq
  fftsa.binhz  = fftsa.fs / fftsa.n
  -- Large transforms outrun the 2 s default, so the guard follows the measured frame
  -- cost with margin rather than a multiple of the sample count.
  fftsa.busy_max = math.max(2.0, 3.0 * fftsa.frame_estimate(fftsa.n))
  -- Re-armed only when the sample count moved, which is the only thing the period is
  -- derived from. arm() deletes the timer and creates a replacement, so re-arming restarts
  -- the period and churns the object pool: an adopted gesture, which cannot change the
  -- count, would pay a frame of latency for an identical timer and throw away the period
  -- frame() had measured. From the model, which frame() replaces on the first real frame.
  fftsa.work_peak, fftsa.work_seen, fftsa.plain_peak = nil, 0, nil
  -- The diagnostics too, which is not cosmetic. Every one of these is a worst-seen, and a
  -- worst-seen that outlives the count it was measured at reads as a figure for the count on
  -- screen. It cost two wrong diagnoses: a 215.5 ms acquisition against a true 169.3, and a
  -- work_plain of 117.8 ms sitting beside a work_tick of 353.3 as though one frame in eight
  -- were three times the cost of the others, when they were simply recorded at different
  -- sample counts. phases() is read to decide what to optimise, so a stale entry sends the
  -- work somewhere it is not.
  fftsa.ph_peak = {}
  fftsa.work_plain, fftsa.work_tick = nil, nil
  -- Dropped rather than carried across: the rate the previous sample count ran at is wrong
  -- for this one, and the line is written twice from here, so a stale figure would be on
  -- the glass before the first new frame.
  fftsa.fps, fftsa.fps_n, fftsa.fps_t0 = nil, 0, nil
  if fftsa.timer ~= nil and fftsa.armed_n ~= fftsa.n then
    fftsa.period = fftsa.frame_period(fftsa.n)
    fftsa.arm(fftsa.period)
    -- Set with the modelled arm and not beside it. An Apply that leaves the count alone --
    -- an adopted gesture, a span or window change -- keeps a period measured from real
    -- frames, and flagging that modelled would have the next frame re-arm from one frame:
    -- a timer deleted and recreated, and the measurement thrown away, which is the whole
    -- thing the guard on this branch exists to prevent.
    fftsa.period_modelled = true
  end
  fftsa.sg_pk_last, fftsa.sg_pk_lf, fftsa.sg_pk_lv = nil, {}, {}
  -- The native plan follows the same three attributes dsp.commit() rebuilds from. The code
  -- and the arena are untouched -- nl.reinit is one params write and one call -- so this is
  -- microseconds against commit()'s window rebuild, and it has to come after the capture
  -- above, because nl_bind scans the capture buffer's own readings to find its storage.
  fftsa.nl_replan()
  -- The LEGEND again, not the axis. What the measured rate refined is binhz, and so the bin
  -- count the legend reports for a narrow span; fftsa.flo and fftsa.fhi have not moved since
  -- the pin above, so re-pinning would be a second 60 ms write of identical limits.
  fftsa.sg_write_xunit()
end

-- Re-plan the native path for the settings in force, and find the buffers it writes.
-- Called from apply(), and from start() once the install exists.
--
-- A count above what the arena was sized for leaves nl.ready false, which is the whole
-- mechanism for falling back: nl_usable() then says no and the frame runs dsp.spectrum.
-- Nothing here raises -- a native path that cannot be built is a slower app, not a broken
-- one -- so a failure is recorded and swallowed.
function fftsa.nl_replan()
  local nl = fftsa.nl
  if nl == nil or type(nl.reinit) ~= 'function' then return false end
  if nl.entry == nil or nl.entry == 0 then return false end
  if nl.nmax == nil or fftsa.n > nl.nmax then
    -- The descriptors stay. Dropping them here would throw away both of describe()'s
    -- cached sweeps on the way back down to a count the arena can serve, and each is a walk
    -- of the heap window.
    nl.ready = false
    return false
  end
  local ok = nl.reinit(fftsa.n, nl.win_to_native(fftsa.win_i),
                       fftsa.kbeta(fftsa.kbeta_i), 1, nl.FFT_FOURSTEP)
  if not ok then
    fftsa.nl_lasterr = 'reinit ' .. tostring(nl.last_rc)
    return false
  end
  return fftsa.nl_bind()
end

-- The peaks the primitive reported, into two tables the display reads. Allocated once: the
-- house rule is to allocate at Apply and never in a frame.
--
-- Through dsp.peak() rather than the implementation's own arrays, which are not API -- a
-- native primitive has none to reach into. Resolved once here, where the three display users
-- between them used to call fftsa.peak_interp eighteen times a frame.
function fftsa.dsp_peaks(count)
  if fftsa.pk_hz == nil then fftsa.pk_hz, fftsa.pk_v = {}, {} end
  local hz, v = fftsa.pk_hz, fftsa.pk_v
  local i
  -- On the native path the peaks come out of the results block the same call filled, not
  -- from dsp.peak(): no dsp.spectrum ran on this path, so that implementation's notion of
  -- "a spectrum has been computed" is never set and every call would refuse -- one posted
  -- event per peak per frame. Keyed on nl_frame, not on nl_res: if the trace came from the
  -- native path and the results did not read back, the answer is no peaks, not a question
  -- put to a primitive that cannot answer it.
  if fftsa.nl_frame then
    local res = fftsa.nl_res
    for i = 1, count do
      if res == nil then hz[i], v[i] = nil, nil
      else hz[i], v[i] = res.hz[i], res.v[i] end
    end
    return hz, v
  end
  for i = 1, count do
    hz[i], v[i] = dsp.peak(i)
  end
  return hz, v
end

-- Distortion, signal-to-noise and the noise floor, from whichever path produced the
-- spectrum on screen. thd is a FRACTION, as dsp.distortion() reports it; the THD line
-- turns it into a percentage. Each figure is nil where the measurement did not apply, and
-- all three are nil on a native frame whose results block did not read back.
function fftsa.distortion()
  if fftsa.nl_frame then
    local res = fftsa.nl_res
    if res == nil then return nil, nil, nil end
    return res.thd, res.snr, res.noise
  end
  return dsp.distortion()
end

-- The sample count the spectrum on screen was computed from. The THD line picks its
-- decimal places off this, and dsp.fft.samples is the OTHER implementation's plan: on the
-- native path that figure describes a transform nothing ran.
function fftsa.plan_n()
  if fftsa.nl_frame then return fftsa.n end
  return dsp.fft.samples
end

-- One frame: acquire, one primitive call, plot. Runs under pcall from fftsa.frame().
-- docs/PERFORMANCE.md has the measured phase costs.
function fftsa.frame_body()
  -- A frame can be dispatched while the app is half-built (a failed startup) or
  -- half-torn-down (End App, a host reload); bail out rather than index a nil.
  if fftsa.cap == nil or fftsa.sg_buf == nil or fftsa.sg_graph == nil
     or fftsa.sg_pk_f == nil then
    return
  end
  -- Diagnostic: FFTSA_FREEZE, set before launch, runs one frame then stops touching the
  -- trace buffer, so dropouts that continue are the widget's and not ours. A bare global
  -- because a socket command aborts a running app.
  if FFTSA_FREEZE and fftsa.froze then return end
  local t_a = os.clock()
  fftsa.cap.clear()
  dmm.digitize.read(fftsa.cap)
  -- Asked of the capture before anything is computed from it, and free: the firmware keeps the
  -- buffer's min and max current as the readings land, so this is one call rather than a pass.
  fftsa.overrange = fftsa.cap_overrange(fftsa.cap)
  local t_b = os.clock()
  -- The counts only. The attributes the interpreted primitive reads, including the plotted
  -- window, are pushed by spectrum_interp at the point of use, so a compiled frame writes
  -- none of them.
  local npk = fftsa.dsp_live()
  -- Native path: the compiled DSP computes, Lua writes the trace, because the display task
  -- feeds from buffer.write.reading only. The clear and refill below is the window the trace
  -- drops out in -- measured on the glass, and gone when FFTSA_FREEZE stops the writes.
  -- Falls back to dsp.spectrum when the install cannot serve the plan in force.
  --
  -- Both flags are cleared first and set only on success, so everything that reads them --
  -- the peak table, the THD line, plan_n -- is reading this frame or nothing.
  --
  -- Two flags and not one: nl_frame says which primitive produced the spectrum, nl_res
  -- holds the figures that came with it. They can disagree -- a trace written and the
  -- results block failing to read back -- and keying the peak table on nl_res alone would
  -- then send it to dsp.peak(), which has run no transform on this path and posts
  -- "no spectrum yet" once per peak per frame.
  local nseg
  fftsa.nl_frame = false
  fftsa.nl_res = nil
  local native = fftsa.nl_usable()
  -- A WRAPPED capture comes back ROTATED: readings[1] is the ring's physical slot 1 and the
  -- oldest reading sits at startindex, so a linear walk over the storage transforms the
  -- record in the wrong order -- every frequency wrong, and nothing on the plot to say so.
  -- Only a full buffer can have wrapped and this one is four times the record, so this is
  -- expected never to fire; it is one attribute read and the failure it guards is silent.
  -- Not a demotion: the next capture may well be in order, so the frame falls back and the
  -- occurrence is counted.
  if native and fftsa.cap.startindex ~= nil and fftsa.cap.startindex ~= 1 then
    fftsa.nl_rotated = (fftsa.nl_rotated or 0) + 1
    native = false
  end
  if native then
    -- A short record is refused rather than transformed: zero-padding the tail gives a
    -- convincing and false broadband spectrum, and a trigger timeout is the ordinary
    -- cause. dsp.spectrum makes the same test against its own srclength.
    if fftsa.cap.n == nil or fftsa.cap.n < fftsa.n then
      -- Counted on its own name and then mirrored, because the other path reports an
      -- absolute total of its own: incrementing the shared name on one path and assigning
      -- it from a different counter on the other makes the figure jump at a demotion.
      fftsa.nl_shortreads = (fftsa.nl_shortreads or 0) + 1
      fftsa.shortreads = fftsa.nl_shortreads
      return
    end
    -- The bin width THIS capture delivered, off its own timestamps: the samplerate
    -- read-back does not match what arrives, so it is never the source. Two table reads.
    local binhz = fftsa.measure_fs(fftsa.cap) / fftsa.n
    -- nil for the output: the primitive reduces and touches no reading buffer. Having it
    -- write the trace itself was tried and is below.
    nseg = fftsa.nl.call_dsp(fftsa.nl_cap, nil, fftsa.nl_reduction(binhz))
    if nseg == nil then
      -- Demoted for the rest of the session rather than raising once a frame. last_rc
      -- carries the reason; fftsa.nl.RC names it.
      fftsa.nl.ready = false
      fftsa.nl_lasterr = tostring(fftsa.nl.last_rc)
      nseg = fftsa.spectrum_interp(fftsa.cap, fftsa.sg_buf)
    else
      -- The trace reaches the graph through buffer.write.reading, from the values the same
      -- call reduced. The display task works from its own copy of a bound buffer and that
      -- write is what feeds it, so the native side's own write into the buffer's chunk
      -- storage draws nothing and no notify call rescues it; nl.reduce says more.
      --
      -- Cleared and refilled, which is what dsp.spectrum does internally on the other
      -- path, so the window holding a partial trace is the loop below and no longer.
      local rd = fftsa.nl.reduce(nseg)
      if rd == nil then
        fftsa.nl.ready = false
        fftsa.nl_lasterr = 'reduce'
        nseg = fftsa.spectrum_interp(fftsa.cap, fftsa.sg_buf)
      else
        fftsa.binhz = binhz
        fftsa.nl_frame = true
        fftsa.nl_res = fftsa.nl.results()
        -- Cleared and refilled. The window between the clear and the last append is where
        -- the trace drops out for a frame, and TWO WAYS OUT OF IT WERE TRIED ON THE GLASS
        -- and both were worse:
        --
        --   hiding the graph across the refill changed nothing, because setstate posts
        --   without waiting and so cannot bracket this against the GUI's own paint timer;
        --
        --   having the primitive write the elements in place and re-subscribing to rebuild
        --   the GUI's ring repaints the WHOLE widget, axes included, once a frame -- far
        --   worse flicker, and no faster, since a rebind re-pins the axes.
        --
        -- Clearing less often was the third option -- the buffer holds 680 and a frame
        -- writes 255 -- and it is REFUSED: it halves the dropouts by drawing the last two
        -- spectra overlaid, and a doubled trace is not wanted. So the dropout stays.
        local wr = buffer.write.reading
        local tb, db, hz = fftsa.sg_buf, rd.db, rd.hz
        local i
        tb.clear()
        for i = 1, nseg do
          wr(tb, db[i], hz[i], i, 0)
        end
      end
    end
  else
    -- Existing path: dsp.spectrum clears sg_buf internally before filling it.
    -- marks = nil deliberately (see comment below).
    nseg = fftsa.spectrum_interp(fftsa.cap, fftsa.sg_buf)
  end
  if nseg == nil or nseg < 0 then error(fftsa.dsp_why("spectrum", nseg), 0) end
  -- Zero segments is a short record, not a failure: nothing was written, the previous
  -- spectrum is still on screen, and a trigger timeout is the ordinary cause. Counted by the
  -- primitive, mirrored here because the settings line and the suite read this name.
  if nseg == 0 then
    fftsa.shortreads = dsp.shortreads
    return
  end
  -- binhz: measured from the capture's timestamps on the native path, where it is already
  -- set above and is the figure dsp_reduce was given, so the markers and the trace cannot
  -- describe different frequencies. From the primitive's own read-back otherwise.
  if not fftsa.nl_frame then
    fftsa.binhz = dsp.fft.binwidth
  end
  -- Segments the widget was actually handed, from the primitive's own count rather than
  -- inferred from the buffer: clamped or overrun, the buffer's n ends at capacity either
  -- way, so only a counter can tell the two apart.
  fftsa.sg_nwrote = nseg
  local t_c = os.clock()
  local pk_hz, pk_v = fftsa.dsp_peaks(npk)
  -- After the trace rather than before it: the peaks come out of the same call that writes
  -- the trace, so the markers cannot be filled first. What the ordering was for still holds
  -- -- the yield below is the first paint after BOTH buffers are complete -- and the window
  -- in which one of them is incomplete is now the 18 marker points rather than 255 trace
  -- points.
  fftsa.sg_update_markers(nil, nil, npk, fftsa.binhz, pk_hz, pk_v)
  local t_d = os.clock()
  -- Display work the primitive does not do: outside any write window, then the paint.
  -- Whether the one-a-second block ran is recorded, because the timer period follows the
  -- PEAK frame over a window and that block is in one frame of every window.
  -- The SECOND answer, which is whether the one-a-second block ran. The first is whether
  -- any of sg_slow_tick ran, and its 0.15 s gesture clock sets that on every frame at any
  -- count whose period is longer than 150 ms -- every count from 4096 up. Keyed on the
  -- first, no frame from 4096 up was ever recorded as plain, plain_peak stayed nil for the
  -- life of the setting, and the period rule fell back to the worst frame of all at exactly
  -- the counts pacing from the plain frame was aimed at.
  local sg_ran, sg_heavy = fftsa.sg_slow_tick()
  fftsa.ph_tick = sg_heavy
  local t_e = os.clock()
  delay(fftsa.sg_yield)
  local t_f = os.clock()
  -- Dashes rather than the figures, which are all arithmetic about the sentinel: the peak
  -- frequencies in particular are arbitrary picks from a spectrum whose bins are equal.
  if fftsa.overrange then
    fftsa.sg_show_peaks_over()
  else
    fftsa.sg_show_peaks(nil, nil, npk, fftsa.binhz, pk_hz, pk_v)
  end
  -- The HELP key, still at the END of the graph update: the glass is complete, so the
  -- firmware's dialog is either over a finished frame or not there at all, and the check is
  -- never reading a half-painted screen. There is no event to hang it on; every delivery
  -- path the firmware offers refuses the key.
  --
  -- Once a second, not once a frame, and the cost is not the checksum itself. The firmware
  -- answers that in 0.33 ms. It is the wait: getchecksum returns glass-derived data, so it
  -- blocks until the display task answers, and at this point in the frame that task owes the
  -- 255 reading messages the trace fill just batched and the repaint they cause. Measured on
  -- 1.7.17a at 16,384 samples, 46.1 ms of a 274.3 ms frame, against 0.1 ms with the call
  -- gone -- a sixth of the frame spent waiting for a keypress poll.
  --
  -- A second of latency on a human pressing HELP costs nothing, which is the argument
  -- sg_slow_tick already makes for reading FRONT/REAR on this clock instead of per frame.
  local hnow = os.clock()
  if fftsa.help_last == nil or (hnow - fftsa.help_last) >= fftsa.help_period then
    fftsa.help_last = hnow
    fftsa.help_main()
  end
  -- Phase costs, last frame and the worst seen. Seven clock reads, about 15 us, against a
  -- frame of tens of milliseconds; fftsa.phases() formats them.
  local ph, pk = fftsa.ph, fftsa.ph_peak
  ph.acq  = t_b - t_a
  -- acq split by whether the PREVIOUS frame carried the one-a-second display block. The
  -- display task runs only while Lua is blocked and digitize.read is the longest block in the
  -- frame, so if painting is being absorbed by acq it shows up here. The previous frame, not
  -- this one: the display block runs after acq within a frame.
  -- Per sample count, or the means mix the sizes and say nothing. Reset when n moves.
  if fftsa.acq_for ~= fftsa.n then
    fftsa.acq_for = fftsa.n
    fftsa.acq_after_tick, fftsa.acq_after_plain = nil, nil
    fftsa.acq_tick_n, fftsa.acq_tick_s = 0, 0
    fftsa.acq_plain_n, fftsa.acq_plain_s = 0, 0
  end
  if fftsa.prev_tick then
    if fftsa.acq_after_tick == nil or ph.acq > fftsa.acq_after_tick then
      fftsa.acq_after_tick = ph.acq
    end
    fftsa.acq_tick_n = (fftsa.acq_tick_n or 0) + 1
    fftsa.acq_tick_s = (fftsa.acq_tick_s or 0) + ph.acq
  else
    if fftsa.acq_after_plain == nil or ph.acq > fftsa.acq_after_plain then
      fftsa.acq_after_plain = ph.acq
    end
    fftsa.acq_plain_n = (fftsa.acq_plain_n or 0) + 1
    fftsa.acq_plain_s = (fftsa.acq_plain_s or 0) + ph.acq
  end
  ph.spec = t_c - t_b
  ph.mark = t_d - t_c
  ph.tick = t_e - t_d
  ph.yld  = t_f - t_e
  ph.show = os.clock() - t_f
  local k, v
  for k, v in pairs(ph) do
    if pk[k] == nil or v > pk[k] then pk[k] = v end
  end
  -- One full frame has now drawn a trace, so the freeze diagnostic above can stand everything
  -- down. Set unconditionally: it costs one store and it means the flag can be raised from a
  -- socket between launches without the app having to be rebuilt for it.
  fftsa.froze = true
  fftsa.prev_tick = fftsa.ph_tick
end

-- The per-phase costs as one line, for a probe. Milliseconds, last frame then the worst.
function fftsa.phases()
  local ph, pk = fftsa.ph, fftsa.ph_peak
  local names = {'acq', 'spec', 'mark', 'tick', 'yld', 'show'}
  local out, i = '', nil
  for i = 1, table.getn(names) do
    local k = names[i]
    out = out .. string.format('%s %.1f/%.1f  ', k, 1000 * (ph[k] or 0),
                               1000 * (pk[k] or 0))
  end
  return string.format('%sframe %.1f  plain %.1f  tick %.1f', out,
                       1000 * (fftsa.frame_work or 0),
                       1000 * (fftsa.work_plain or 0), 1000 * (fftsa.work_tick or 0))
end

-- Reentrancy-guarded frame. The body runs under pcall so an error cannot leave
-- fftsa.busy set, which would make every later frame return at the top. A host
-- abort (event 1409) mid-frame is not covered by the pcall and does leave it set,
-- so a guard held longer than fftsa.busy_max is broken and the break counted.
fftsa.busy_since = nil
fftsa.busy_max   = 2.0      -- seconds a guard may be held before it is judged stuck


-- Seconds one frame costs at a given count and rate. The transform term is stated by the
-- primitive rather than modelled here -- dsp.fft.spectrumtime, filled by commit() for the
-- plan in force, so its coefficients belong to whichever implementation is bound -- and it
-- reads zero when the archive carries no interpreted transform.
--
-- busy_max breaks a guard a host abort left set, and the app looks dead until it expires, so
-- it has to clear a legitimate frame and not much more. Three times this does that at every
-- count and rate; a multiple of the sample count does not.
function fftsa.frame_estimate(n, fs)
  if n == nil or n < 2 then n = 512 end
  local est = 0.05
  if dsp.fft.samples == n then
    local t = dsp.fft.spectrumtime
    if type(t) == "number" and t > 0 then est = t end
  end
  -- The capture is a floor on any estimate, and the only term known exactly rather than
  -- modelled. It dominates at the slow rates: 32768 samples at 25 kS/s is 1.31 s, which on
  -- its own outruns the 2 s busy guard this feeds.
  if type(fs) ~= "number" or fs <= 0 then fs = fftsa.fs_acq or fftsa.fs or fftsa.fs_min end
  local acq = n / fs
  if est < acq then est = acq end
  return est
end
fftsa.busy_stuck = 0        -- how many times the guard had to be broken

-- Frame rate, measured over a window of completed frames and shown on the settings line.
fftsa.fps_window = 1.0      -- seconds a measurement spans
fftsa.fps        = nil      -- frames a second, nil until the first window closes
fftsa.fps_n      = 0        -- frames counted in the window
fftsa.fps_t0     = nil      -- when the window opened
fftsa.fps_show   = false    -- a fresh figure is waiting for the line

-- Per-phase frame costs, last frame and the worst seen, written by frame_body.
fftsa.ph       = {}
fftsa.ph_peak  = {}
fftsa.ph_tick  = false      -- the one-a-second display block ran in the last frame
-- The worst frame of each kind. The timer period follows a peak over eight frames and one
-- of those frames carries the one-a-second block, so a single number cannot say whether the
-- period is set by the spectrum or by the display.
fftsa.work_plain = nil
fftsa.work_tick  = nil
-- The worst plain frame of the window in force, which is what the period follows. Separate
-- from work_plain, which is the worst since the count was applied and never decays, so it
-- would pin the period to a single slow frame for the life of the setting.
fftsa.plain_peak = nil
-- The period in force came from frame_estimate and no frame has been timed against it yet,
-- so the first one that is may replace it outright.
fftsa.period_modelled = false

function fftsa.frame()
  if fftsa.halted then return end
  if fftsa.busy then
    local since = fftsa.busy_since
    if since == nil or (os.clock() - since) < (fftsa.busy_max or 2.0) then return end
    fftsa.busy_stuck = (fftsa.busy_stuck or 0) + 1
  end
  fftsa.busy_since = os.clock()
  fftsa.busy = true
  -- Timed, because the timer period is set from what a frame actually costs.
  local entry = os.clock()
  local ok, err = pcall(fftsa.frame_body)
  fftsa.frame_work = os.clock() - entry
  -- Completed frames against the wall clock, which is the rate on the glass. Neither of the
  -- other two figures is that: frame_work is one frame's work with no idle in it, and the
  -- timer period rounds up to a 50 ms tick, so a 60 ms frame and a 99 ms frame both display
  -- at 10 a second. Counted over a window and not per frame, because a rate from one
  -- interval dithers by a tick.
  -- The DELIVERED interval between frames, which is the figure that says where the rate
  -- actually goes. It is NOT frame_work: the firmware's timer and the display task both live
  -- in the gap between frames, and the display task runs only while Lua is blocked. Measured
  -- at 4096: the app armed 0.15 s and delivered 0.20 s with frame_work at 0.125, so 50 ms a
  -- frame was being spent where frame_work cannot see it.
  if fftsa.last_entry ~= nil then
    local gap = entry - fftsa.last_entry
    if fftsa.gap_peak == nil or gap > fftsa.gap_peak then fftsa.gap_peak = gap end
  end
  fftsa.last_entry = entry
  fftsa.fps_n = (fftsa.fps_n or 0) + 1
  if fftsa.fps_t0 == nil then fftsa.fps_t0 = entry end
  local span = os.clock() - fftsa.fps_t0
  if span >= fftsa.fps_window then
    fftsa.fps = fftsa.fps_n / span
    fftsa.fps_n, fftsa.fps_t0 = 0, os.clock()
    fftsa.fps_show = true
    -- A CENSUS PER SAMPLE COUNT, kept in a bare global, because a socket command aborts the
    -- running app: one statement returns a frozen snapshot of the last frame and the app is
    -- dead after it, so a size sweep can neither be driven nor read from outside. The app
    -- records its own instead -- change size on the panel, and one read afterwards gives the
    -- whole curve. A formatted string so that read is a single print.
    if FFTSA_CENSUS == nil then FFTSA_CENSUS = {} end
    local ph = fftsa.ph
    FFTSA_CENSUS[fftsa.n] = string.format(
      'per=%.3f fps=%.2f gap=%.1f wp=%.1f wt=%.1f acq=%.1f spec=%.1f yld=%.1f nl=%s',
      fftsa.period or 0, fftsa.fps or 0, 1000 * (fftsa.gap_peak or 0),
      1000 * (fftsa.work_plain or 0), 1000 * (fftsa.work_tick or 0),
      1000 * (ph.acq or 0), 1000 * (ph.spec or 0), 1000 * (ph.yld or 0),
      tostring(fftsa.nl_frame))
    -- The acq split, where a paint absorbed by the capture would show.
    local pn, tn = fftsa.acq_plain_n or 0, fftsa.acq_tick_n or 0
    FFTSA_ACQ = string.format(
      'n=%d after-plain mean=%.1f peak=%.1f (%d) | after-tick mean=%.1f peak=%.1f (%d)',
      fftsa.n,
      1000 * (pn > 0 and (fftsa.acq_plain_s / pn) or 0),
      1000 * (fftsa.acq_after_plain or 0), pn,
      1000 * (tn > 0 and (fftsa.acq_tick_s / tn) or 0),
      1000 * (fftsa.acq_after_tick or 0), tn)
  end
  -- Re-arm from measured work: frame_estimate() is a model, and divided by the occupancy
  -- target an error of a few ms lands either side of a tick boundary, which is a 50 %
  -- swing in displayed rate.
  --
  -- The peak over a window of frames, not the mean, because the period has to cover the
  -- slowest frame or ticks drop and the rate halves. Raised only by a whole tick and
  -- re-armed only when the tick count changes, so one long frame does not re-arm
  -- every frame after it.
  if ok then
    if fftsa.work_peak == nil or fftsa.frame_work > fftsa.work_peak then
      fftsa.work_peak = fftsa.frame_work
    end
    if fftsa.ph_tick then
      if fftsa.work_tick == nil or fftsa.frame_work > fftsa.work_tick then
        fftsa.work_tick = fftsa.frame_work
      end
    else
      if fftsa.work_plain == nil or fftsa.frame_work > fftsa.work_plain then
        fftsa.work_plain = fftsa.frame_work
      end
      if fftsa.plain_peak == nil or fftsa.frame_work > fftsa.plain_peak then
        fftsa.plain_peak = fftsa.frame_work
      end
    end
    fftsa.work_seen = (fftsa.work_seen or 0) + 1
    -- One frame replaces a modelled period, eight replace a measured one. The model is
    -- frame_estimate, which is the interpreted primitive's cost for the count: the compiled
    -- path runs a fraction of it, so at the large counts the modelled period is several
    -- times the real frame and a window of eight would hold the app there for most of a
    -- minute. Nothing is lost by replacing it early, because the peak still governs from
    -- the next window on and a period set by a plain frame is raised again by the next
    -- frame that carries the display block.
    local win = 8
    if fftsa.period_modelled then win = 1 end
    if fftsa.work_seen >= win and fftsa.timer ~= nil then
      -- Paced from the worst frame that did not carry the one-a-second display block, not
      -- from the worst of the window. That block lands in one frame of every eight, so a
      -- period covering it holds every other frame idle for the difference; letting it
      -- overrun instead drops a tick once a second and buys that difference back on the
      -- other seven. For any window longer than one frame the arithmetic favours the
      -- overrun, and the tick frame is still bounded by busy_max.
      --
      -- work_peak remains the basis until a plain frame has been seen, which is the state
      -- in the first window after a size change.
      local want = fftsa.tick_period(fftsa.plain_peak or fftsa.work_peak)
      -- The delivered gap is measured and NOT acted on. 8.9 floored the period at it and it
      -- ratcheted -- arm() delays the frame it then measures, so the period only climbed and
      -- 2048 fell from 10.7 fps to 3. Using it needs the frame after a re-arm excluded.
      --
      -- The deadband: on a 10 ms grid every step is a timer delete and create, so a
      -- converged period must stop re-arming. The old 50 ms grid gave that for free.
      -- ASYMMETRIC, biased towards rate. Arming a step short costs an occasional missed
      -- tick; arming a step long costs every frame. At 4096 the work straddles the 0.12/0.15
      -- boundary -- acq alone varies 42 to 74 ms -- so a symmetric deadband chased the jitter
      -- and the rate swung between 8.2 and 6.7 fps. Dropping takes one grid step, raising
      -- takes tick_rise, so it settles at the fast end and still follows a size change, which
      -- moves the period far more than tick_rise.
      local move = want - (fftsa.period or 0)
      local need = fftsa.tick_rise
      if move < 0 then
        move, need = -move, fftsa.tick_grid
      end
      if fftsa.period == nil or move >= need then
        fftsa.period = want
        fftsa.arm(want)
      end
      fftsa.period_modelled = false
      -- Decay the peaks so a size change downwards is noticed: they are re-earned over the
      -- next window rather than remembered for the life of the app.
      fftsa.work_peak = fftsa.frame_work
      fftsa.plain_peak = nil
      if not fftsa.ph_tick then fftsa.plain_peak = fftsa.frame_work end
      -- The delivered gap decays with the work peaks and for the same reason: a size change
      -- downwards has to be noticed, and a gap earned at the old count would hold the period
      -- up for the life of the setting. Cleared HERE and not in the census above, which runs
      -- once a second and would wipe it before this window closed.
      fftsa.gap_peak = nil
      fftsa.work_seen = 0
    end
  end
  if not ok then
    -- Re-bind the trace after a failure so the graph is never left without one, and only
    -- while the bound buffer still holds points: adding over an empty one binds nothing
    -- and never draws again.
    --
    -- Once per run of failures, not once per failure. Each add allocates an 82,464-byte
    -- display-side trace object against a ceiling of 30 across all graphs, so a run of
    -- twenty rebinding frames spends most of that pool for nothing, and the axis re-pin in
    -- every one of them is visible as the scales walking across the screen. errrun still
    -- holds the previous value here, so zero is the first failure of a run.
    if fftsa.errrun == 0 and fftsa.sg_graph ~= nil and fftsa.sg_buf ~= nil
       and fftsa.sg_buf.n > 0 then
      fftsa.sg_rebind()
    end
    fftsa.lasterr  = tostring(err)
    fftsa.errcount = (fftsa.errcount or 0) + 1
    fftsa.errrun   = (fftsa.errrun or 0) + 1
    -- After a run of failures stop retrying and say so on screen: a trace that
    -- stopped updating looks like a working analyser on a dead signal.
    if fftsa.errrun >= (fftsa.errmax or 20) then
      fftsa.halted = true
      display.settext(fftsa.sg_xunit,
        "HALTED after " .. fftsa.errrun .. " failed frames: " ..
        string.sub(tostring(fftsa.lasterr), 1, 60))
    end
  else
    fftsa.errrun = 0
  end
  -- Once a second, when the window above closed, so the line carries the rate just measured.
  -- Not written per frame: the line is otherwise off the frame path and a closure per second
  -- is affordable where one per frame would not be. Never over a halt message.
  if fftsa.fps_show and not fftsa.halted then
    fftsa.fps_show = false
    fftsa.sg_write_xunit()
  end
  -- An unlocked gesture's span is installed here, between frames: fftsa.apply() re-plans
  -- the digitizer and takes its own capture, so it cannot run inside a frame using the
  -- buffers. halted keeps the timer out of frame_body meanwhile and the guard above is still
  -- held. Skipped when a teardown waits, and when the frame above gave up -- halted is
  -- cleared at the end of this block, so retuning through a halt would restart that loop.
  if fftsa.retune_pending and not fftsa.stop_pending and not fftsa.halted then
    fftsa.retune_pending = false
    -- Reconfigures the digitizer and takes one capture, with the trace frozen for it. The
    -- window tables are NOT rebuilt: fft_init() is keyed on the sample count and the window,
    -- and a gesture changes neither. The line says why; apply() rewrites it at the end.
    fftsa.say(string.format("retuning to %.0f - %.0f Hz", fftsa.flo, fftsa.fhi))
    fftsa.halted = true
    local rok, rerr = pcall(function() fftsa.apply() end)
    fftsa.halted = false
    if not rok then
      fftsa.lasterr = tostring(rerr)
      fftsa.say("RETUNE FAILED: " .. tostring(rerr))
      -- sg_adopt_x left the pin to apply(), so a failure before apply's own pin would
      -- strand the axis on the gesture's unclamped limits with the trace in the clamped
      -- window. Nothing else would re-pin until the next gesture.
      fftsa.sg_pin_x()
    end
  end
  fftsa.busy = false
  -- A teardown that arrived mid-frame waits here, where nothing is in flight.
  if fftsa.stop_pending then
    fftsa.stop_pending = false
    fftsa.stop()
  end
end

-- The firmware frees the fields with their screen; the Lua handles still need clearing.
function fftsa.destroy_options()
  if fftsa.optscr ~= nil then
    -- Never delete the screen currently on show: leave it first.
    fftsa.show_main()
    fftsa.del_obj(fftsa.optscr)
  end
  fftsa.optscr, fftsa.opt_flo, fftsa.opt_fhi, fftsa.opt_rng, fftsa.opt_info =
    nil, nil, nil, nil, nil
  fftsa.opt_win, fftsa.opt_beta, fftsa.opt_n = nil, nil, nil
  fftsa.opt_mk = nil
  fftsa.opt_info_last = nil
end

-- Form geometry, two columns like the decode app's: six fields become three rows,
-- and the gap that buys is what makes each box a touch target. display.create takes
-- no width for an OBJ_EDIT_*, so the second column's x is the one number to check on
-- the glass. Labels are right-aligned and end at the column x.
-- Six: Peak Markers is withheld. See fftsa.opt_mk.
fftsa.opt_nf      = 6
fftsa.opt_cols    = 2
fftsa.opt_x       = 185
fftsa.opt_x_c2    = 552
fftsa.opt_y0      = 8
fftsa.opt_dy      = 100     -- preferred pitch; clamped to what fits
fftsa.opt_edit_h  = 50      -- box height, measured
fftsa.opt_edit_dy = 4       -- offset of the box inside the object
fftsa.opt_y_adj   = 0       -- nudge of the centred block, negative being up
fftsa.opt_btn_y   = 360
fftsa.opt_info_y  = 323     -- readback line BASELINE; an OBJ_TEXT y is its baseline
fftsa.opt_info_h  = 20      -- its height above that baseline, so the fields clear it

-- Rows, pitch and top for the field block. The pitch is the preferred one, clamped if a
-- field count ever needs it: the last box has to end above the button row. At the six
-- fields the form carries, three rows at the preferred 100 leave the clamp inert.
function fftsa.opt_layout()
  local nrows = math.ceil(fftsa.opt_nf / fftsa.opt_cols)
  local eh, edy = fftsa.opt_edit_h, fftsa.opt_edit_dy
  local y0, dy  = fftsa.opt_y0, fftsa.opt_dy
  -- The last box has to end above the readback line, which sits above the buttons: at
  -- seven fields the button row alone leaves the bottom box over the top of it.
  local floor_y = fftsa.opt_info_y - fftsa.opt_info_h
  if nrows > 1 then
    local maxdy = math.floor((floor_y - y0 - edy - eh) / (nrows - 1))
    if dy > maxdy then dy = maxdy end
  end
  -- Centred, because three rows do not fill the form, then nudged. Only ever down,
  -- and only by what is spare; the nudge is separate from y0 because the centring
  -- divides the leftover space and would give back half of a move asked for there.
  local spare = floor_y - ((nrows - 1) * dy + eh + edy) - y0
  if spare > 0 then y0 = y0 + math.floor(spare / 2) end
  if y0 + fftsa.opt_y_adj >= 0 then y0 = y0 + fftsa.opt_y_adj end
  fftsa.opt_nrows, fftsa.opt_dy_used, fftsa.opt_y0_used = nrows, dy, y0
  return nrows, dy, y0
end

function fftsa.build_options()
  fftsa.destroy_options()

  local create = display.create
  -- A screen title over 31 characters is truncated by the firmware (event 1707).
  fftsa.optscr = create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER OPTIONS")
  if fftsa.optscr == nil then
    fftsa.lasterr = "display object pool exhausted building the options screen -- "
                    .. "power cycle the instrument."
    return false, fftsa.lasterr
  end
  fftsa.loading_front()

  -- Columns fill top to bottom, left column first. No instructions on the form:
  -- the fields label themselves.
  local nrows, dy, y0 = fftsa.opt_layout()
  local row = 0
  local function nextpos()
    local c = math.floor(row / nrows)
    if c > fftsa.opt_cols - 1 then c = fftsa.opt_cols - 1 end
    local fx = fftsa.opt_x
    if c > 0 then fx = fftsa.opt_x_c2 end
    local fy = y0 + (row - c * nrows) * dy
    row = row + 1
    return fx, fy
  end

  local x1, y1 = nextpos()
  fftsa.opt_flo = create(fftsa.optscr, display.OBJ_EDIT_NUMBER, x1, y1,
                       "Start Freq", "low edge",
                       display.NFORMAT_PREFIX, fftsa.flo, fftsa.flomin, fftsa.flo_max, "Hz")
  local x2, y2 = nextpos()
  fftsa.opt_fhi = create(fftsa.optscr, display.OBJ_EDIT_NUMBER, x2, y2,
                       "Stop Freq", "display top",
                       display.NFORMAT_PREFIX, fftsa.fhi, fftsa.fhi_min, fftsa.fhi_max, "Hz")
  local x3, y3 = nextpos()
  fftsa.opt_rng = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x3, y3,
                       "Input Range", "full-scale",
                       fftsa.range_labels[1], fftsa.range_labels[2], fftsa.range_labels[3])
  -- Spelled out rather than built from the table: display.create takes the options as
  -- separate arguments and Lua 5.0.2 has no unpack() worth using here.
  local x5, y5 = nextpos()
  fftsa.opt_win = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x5, y5,
                       "Window", "lobe vs sidelobe",
                       fftsa.win_names[1], fftsa.win_names[2], fftsa.win_names[3],
                       fftsa.win_names[4])
  -- Always built, not only when Kaiser is selected: a field created on a press is a
  -- create on a visible screen, and this one is inert for the other three windows.
  local x6, y6 = nextpos()
  fftsa.opt_beta = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x6, y6,
                       "Kaiser Beta", "sidelobe level",
                       fftsa.kbeta_labels[1], fftsa.kbeta_labels[2], fftsa.kbeta_labels[3],
                       fftsa.kbeta_labels[4], fftsa.kbeta_labels[5], fftsa.kbeta_labels[6])
  local x7, y7 = nextpos()
  fftsa.opt_n = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x7, y7,
                       "FFT Samples", "resolution vs speed",
                       fftsa.sample_labels[1], fftsa.sample_labels[2], fftsa.sample_labels[3],
                       fftsa.sample_labels[4], fftsa.sample_labels[5], fftsa.sample_labels[6])
  -- Peak markers is not offered, so the eighth field is not created and fftsa.opt_mk
  -- stays nil; getval answers the fallback for a nil handle, so apply sees "off".
  --
  -- What is missing is the second trace's scaling: the firmware does not honour a pin
  -- applied with that trace selected, so its six points auto-scale across the plot and
  -- land nowhere near the spectrum. The buffer, the refill and the binding are in place.

  fftsa.opt_info = create(fftsa.optscr, display.OBJ_TEXT, 400, fftsa.opt_info_y, "",
                        56575, display.FONT_SMALL, display.JUST_CENTER)   -- cyan 00DCFF
  -- A timer on the options screen previews edits without configuring acquisition, and
  -- answers the HELP key while this form is the screen a press lands on.
  local preview = create(fftsa.optscr, display.OBJ_TIMER, fftsa.opt_tick_period,
                         display.TIMER_FOREVER)
  display.setevent(preview, display.EVENT_PRESS,
                  "if fftsa ~= nil then fftsa.guard(fftsa.opt_tick) end")

  local b_apply = create(fftsa.optscr, display.OBJ_BUTTON, 470, fftsa.opt_btn_y, "Apply", 140)
  display.setevent(b_apply, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options_apply) end")
  local b_cancel = create(fftsa.optscr, display.OBJ_BUTTON, 630, fftsa.opt_btn_y, "Cancel", 140)
  display.setevent(b_cancel, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options_cancel) end")
  local b_about = create(fftsa.optscr, display.OBJ_BUTTON, 8, fftsa.opt_btn_y, "About", 140)
  display.setevent(b_about, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.about) end")
  -- Left of centre, 20 px off About and well clear of Apply at 470: the two that change
  -- what is measured stay together on the right, away from a thumb reaching for About.
  local b_rst = create(fftsa.optscr, display.OBJ_BUTTON, 168, fftsa.opt_btn_y, "Reset", 140)
  display.setevent(b_rst, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options_reset) end")
  -- End App is hooked on this screen too: the firmware may deliver EVENT_ENDAPP to
  -- the visible screen, and leaving from the form must still tear down.
  display.setevent(fftsa.optscr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
  return fftsa.optscr
end

-- ==================== About ====================
-- An OBJ_TEXT y is the text's BASELINE, not the top of its box, which is why these sit
-- lower than a button's y for the same apparent position.
fftsa.about_x        = 12
fftsa.about_title_x  = 400        -- centred, so the x is the screen's middle
fftsa.about_title_y  = 30
fftsa.about_body_y   = 70
-- FONT_1's line pitch, measured on the panel: the numbered fonts are in the firmware's
-- registration table but not in the display API reference, and FONT_1 draws about 17 px
-- tall. Eleven rows at this pitch end clear of the button row at opt_btn_y.
fftsa.about_body_dy  = 20
-- Rows a page. 14 splits the licence after the blank line that follows the copyright
-- notice, so the first page carries everything up to it and the second starts flush with
-- the warranty block instead of with a blank row.
fftsa.about_rows     = 14
fftsa.about_page     = 1
fftsa.about_c_title  = 56575      -- cyan 00DCFF
fftsa.about_c_body   = 16777215   -- white

-- The licence, verbatim from LICENSE and wrapped there: OBJ_TEXT does not wrap, so one
-- line is one row, and a blank line is a row of its own.
fftsa.about_text = {
  "MIT License",
  "",
  "Copyright (c) 2026 Ian Ameline",
  "",
  "Permission is hereby granted, free of charge, to any person obtaining a copy",
  'of this software and associated documentation files (the "Software"), to deal',
  "in the Software without restriction, including without limitation the rights",
  "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell",
  "copies of the Software, and to permit persons to whom the Software is",
  "furnished to do so, subject to the following conditions:",
  "",
  "The above copyright notice and this permission notice shall be included in",
  "all copies or substantial portions of the Software.",
  "",
  'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR',
  "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,",
  "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE",
  "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER",
  "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,",
  "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE",
  "SOFTWARE.",
}

function fftsa.destroy_about()
  if fftsa.aboutscr ~= nil then
    -- Never delete the screen currently on show: leave it first.
    fftsa.show_main()
    fftsa.del_obj(fftsa.aboutscr)
  end
  fftsa.aboutscr, fftsa.about_name, fftsa.about_lines = nil, nil, nil
  fftsa.about_pageno, fftsa.about_page = nil, 1
end

function fftsa.about_pages()
  local rows = fftsa.about_rows
  return math.ceil(table.getn(fftsa.about_text) / rows)
end

-- Page p into the row objects, which are made once and rewritten. A row past the end of
-- the licence is blanked rather than left holding the previous page.
function fftsa.about_show_page(p)
  if fftsa.about_lines == nil then return false end
  local last = fftsa.about_pages()
  if p < 1 then p = 1 end
  if p > last then p = last end
  fftsa.about_page = p
  local base, i = (p - 1) * fftsa.about_rows, nil
  for i = 1, fftsa.about_rows do
    local s = fftsa.about_text[base + i]
    if s == nil then s = "" end
    fftsa.settxt(fftsa.about_lines[i], s)
  end
  fftsa.settxt(fftsa.about_pageno, string.format("page %d of %d", p, last))
  return true
end

function fftsa.about_pgup()
  return fftsa.about_show_page(fftsa.about_page - 1)
end

function fftsa.about_pgdn()
  return fftsa.about_show_page(fftsa.about_page + 1)
end

-- The options form's timer does two jobs, and the key goes first: the preview is cosmetic
-- where the operator is waiting on a dialog to clear. Both run every tick.
--
-- 100 ms, against the firmware's 0.05 s period floor. It costs nothing anywhere else: a
-- display timer fires only while its own screen is the one on show, and the frame loop is
-- frozen for as long as this form is up, so the instrument is otherwise idle here. The
-- checksum is 0.33 ms of it, 0.33%.
fftsa.opt_tick_period = 0.1

function fftsa.opt_tick()
  fftsa.help_check("opt")
  fftsa.options_preview()
  return true
end

-- ==================== help screens ====================
-- Two of them, raised by the HELP key: one for the spectrum screen and one for the options
-- form. Same shape as About -- rows of text, a page counter, PgUp, PgDn and Back -- so the
-- geometry constants above are shared rather than restated, and one builder makes both.
--
-- Which screen a press lands on is decided by which timer ran, not by tracking the visible
-- screen: a display timer only fires while its own screen is showing, measured on the
-- instrument -- the frame timer freezes the moment Options or About is raised. So the
-- spectrum screen's frame timer asks for "main" and the options form's preview timer asks
-- for "opt", and neither needs to know what else is on the glass.
-- fftsa.help_screens and fftsa.help_cur are DELIBERATELY NOT DECLARED HERE, the same as
-- optscr, aboutscr and errscr. Opening the App re-runs this whole script body, so a handle
-- field assigned at module level is cleared while the previous launch's objects are still
-- alive -- they become unreachable and survive until a power cycle, 40 of the 463 pool each
-- time. help_screens holds the built screens by key, and help_cur the one whose buttons are
-- on the glass, which is what lets the button handlers take no argument like About's.

-- Help geometry, separate from About's: a bigger font wants a wider pitch, and these screens
-- start their text right under the title bar where About leaves room for its author line.
--
-- MEASURED on the panel, because the numbered fonts are absent from the display API
-- reference and their order is not the SMALL/MEDIUM/LARGE one. Ink height, width of one
-- fixed string, and how far the ink starts BELOW the y given -- an OBJ_TEXT y is not the
-- baseline, whatever the About comment above says:
--
--   FONT_1  17 px  202 px  37 below      FONT_SMALL   17 px  244 px  37 below
--   FONT_2  19 px  230 px  36 below      FONT_MEDIUM  24 px  380 px  32 below
--   FONT_3  21 px  264 px  34 below      FONT_LARGE   29 px  434 px  28 below
--
-- FONT_3 is 31% wider than FONT_1, so a 49-character row runs to about 540 px and still
-- clears the panel from the icon column. 12 rows is what fits at this pitch: a 13th lands
-- its ink on the button row at opt_btn_y, which is why both texts are written to 12.
fftsa.help_font    = display.FONT_3
fftsa.help_body_y  = 24
fftsa.help_body_dy = 25
fftsa.help_rows    = 12

fftsa.help_text = {
-- Rows are wrapped by hand because OBJ_TEXT does not wrap, and they are wrapped to the
-- MEASURED width: FONT_3 averages 10.2 px a character, so the 734 px from the icon column
-- to the edge of the panel is about 71 characters. Wrapped shorter than that and the screen
-- is mostly empty; the limit the width check enforces is deliberately the conservative
-- 11 px a character, which leaves room for a row of unusually wide glyphs.
  main = {
    -- page 1, rows 1..12: the trace and the two buttons, illustrated with their own icons
    "The trace is the amplitude spectrum of the input, redrawn every",
    "frame. The vertical dB scale is always fixed.",
    "",
    "Options: start and stop frequency, input range, window and",
    "sample count.",
    "",
    "Locked: the frequency span is held where Options set it, and a",
    "drag or a pinch on the graph snaps back to it.",
    "",
    "Unlocked: drag or pinch the graph to move the frequency span or",
    "zoom it. The analyser retunes to wherever you leave it.",
    "Press HELP on the Options form for help with the settings.",
    -- page 2, rows 13..24: the readouts under the trace
    "THD is total harmonic distortion: the harmonics of the strongest",
    "tone, measured against that tone.",
    "",
    "S/N compares the strongest tone with the mean of every other",
    "plotted bin. Noise Floor is that mean, in dBV.",
    "",
    "The six numbered rows are the strongest peaks, each with its",
    "frequency, its amplitude, and its amplitude in dBV.",
    "",
    "The bottom line is the settings in force: point count, sample",
    "rate, bin width, capture time, window, range and terminals.",
    "",
  },
  opt = {
    -- Wrapped wider than the main screen's rows: this one has no icon column, so the text
    -- starts at fftsa.about_x and has the whole 778 px of panel, about 76 characters.
    -- page 1, rows 1..12: the settings
    "Start and stop frequency set the span. The sample rate follows from",
    "the stop frequency, and the bin width from the sample count.",
    "",
    "Range is the full scale input voltage. A signal past it reads",
    "OVERRANGE, and the distortion and peak figures dash out.",
    "",
    "Samples set the resolution: more of them give a narrower bin and a",
    "longer frame, and reduce the rate the graph updates at.",
    "",
    "Apply commits, Cancel abandons, Reset restores the defaults.",
    "",
    "Window is explained on page 2.",
    -- page 2, rows 13..24: the windows. Side lobe levels and main lobe widths are the
    -- standard figures for these four; the form's own beta labels carry Kaiser's.
    "A window tapers the capture to zero at both ends. Without one the",
    "FFT sees a step at the join and smears energy across every bin.",
    "",
    "The choice trades how narrow a peak is against how far the skirts",
    "beside it fall away.",
    "",
    "Hann: skirts -31 dB, peak 4 bins. Narrowest, so it separates close",
    "tones best. Blackman: -58 dB, 6 bins wide.",
    "Blk-Harris: -92 dB, 8 bins, for a small tone beside a large one.",
    "",
    "Kaiser: beta sets the same trade by hand, and the form labels the",
    "skirt level each beta gives.",
  },
}
fftsa.help_titles = {main = "FFT ANALYSER HELP", opt = "FFT OPTIONS HELP"}

-- The main screen's help illustrates its two buttons with the SAME embedded images the
-- buttons use, so it costs no new asset. Resolved by this function rather than a table at
-- module level, because fftsa.img_cog and the padlock pair are assigned further down the
-- file and a table built here would capture nil.
--
-- row is the text row the icon sits beside, and page is the page it belongs to: the objects
-- are made once and live for the screen, so one that is not on the page showing has to be
-- hidden or it sits beside text about something else. The images are 34 tall against a 22 px
-- pitch, so each spans the row named and the one after it, and the text is written at
-- fftsa.help_text_x to clear the icon column.
fftsa.help_icon_x = 12
fftsa.help_text_x = {main = 56, opt = nil}   -- nil means the shared fftsa.about_x

-- The page counter sits IN the button row, in the gap between the PgUp/PgDn pair and Back,
-- rather than above it. Derived rather than typed, from two offsets measured on the panel
-- because neither is in the display API reference: a button's y is 50 px ABOVE its top edge
-- and its face is btn_h tall, so the row centres at opt_btn_y + 50 + btn_h/2; an OBJ_TEXT in
-- FONT_SMALL starts its ink 38 px below the y given and runs 16 px, so the ink centres at
-- y + 46. Equating the two puts this at opt_btn_y + 34.
--
-- A function, not a constant: fftsa.btn_h is assigned further down this file, so a value
-- computed here would read nil and the arithmetic would fail at load.
function fftsa.help_pageno_y()
  return fftsa.opt_btn_y + 50 + fftsa.btn_h / 2 - 46
end

function fftsa.help_icon_list(key)
  if key ~= "main" then return nil end
  return {
    {name = fftsa.img_help_cog, w = fftsa.cog_img_w, h = fftsa.cog_img_h,
     row = 4, page = 1},
    {name = fftsa.img_help_lkc, w = fftsa.lock_img_w, h = fftsa.lock_img_h,
     row = 7, page = 1},
    {name = fftsa.img_help_lko, w = fftsa.lock_img_w, h = fftsa.lock_img_h,
     row = 10, page = 1},
  }
end

function fftsa.destroy_help()
  if fftsa.help_screens ~= nil then
    local k, h
    -- Never delete the screen currently on show, and switch away once rather than per
    -- screen: deleting the visible one can wedge the panel until a power cycle.
    fftsa.show_main()
    for k, h in pairs(fftsa.help_screens) do
      if h.scr ~= nil then fftsa.del_obj(h.scr) end
    end
  end
  fftsa.help_screens, fftsa.help_cur = nil, nil

end

function fftsa.help_pages(h)
  if h == nil then return 1 end
  return math.ceil(table.getn(h.text) / fftsa.help_rows)
end

-- Page p into the row objects, which are made once and rewritten. A row past the end of the
-- text is blanked rather than left holding the previous page.
function fftsa.help_show_page(h, p)
  if h == nil or h.lines == nil then return false end
  local last = fftsa.help_pages(h)
  if p < 1 then p = 1 end
  if p > last then p = last end
  h.page = p
  local base, i = (p - 1) * fftsa.help_rows, nil
  for i = 1, fftsa.help_rows do
    local s = h.text[base + i]
    if s == nil then s = "" end
    fftsa.settxt(h.lines[i], s)
  end
  fftsa.settxt(h.pageno, string.format("page %d of %d", p, last))
  -- Paging controls only where there is paging to do, and the counter goes with them: on a
  -- single page a PgUp can only clamp and "page 1 of 1" says nothing. Asserted on every page
  -- change rather than once at build, so the one place that knows the count decides.
  local vis = display.STATE_ENABLE
  if last <= 1 then vis = display.STATE_INVISIBLE end
  if h.b_up ~= nil then display.setstate(h.b_up, vis) end
  if h.b_dn ~= nil then display.setstate(h.b_dn, vis) end
  if h.pageno ~= nil then display.setstate(h.pageno, vis) end
  -- The illustrations belong to a page. Hidden rather than moved: an OBJ_IMAGE cannot be
  -- repositioned after it is made, so the ones for other pages go invisible.
  if h.icons ~= nil and h.icon_page ~= nil then
    for i = 1, table.getn(h.icons) do
      if h.icons[i] ~= nil then
        if h.icon_page[i] == p then
          fftsa.icon_redraw(h.icons[i])
        else
          display.setstate(h.icons[i], display.STATE_INVISIBLE)
        end
      end
    end
  end
  return true
end

-- Always from the first page, so a screen reads the same every time it is raised.
function fftsa.help_open(key)
  if fftsa.help_screens == nil then return false end
  local h = fftsa.help_screens[key]
  if h == nil or h.scr == nil then return false end
  fftsa.help_cur = h
  fftsa.help_show_page(h, 1)
  display.changescreen(h.scr)
  return true
end

function fftsa.help_pgup()
  if fftsa.help_cur == nil then return false end
  return fftsa.help_show_page(fftsa.help_cur, fftsa.help_cur.page - 1)
end

function fftsa.help_pgdn()
  if fftsa.help_cur == nil then return false end
  return fftsa.help_show_page(fftsa.help_cur, fftsa.help_cur.page + 1)
end

-- Back to whichever screen the help was raised from, by key rather than by a stored handle:
-- the screens are rebuilt on a reload and a saved handle would outlive its object.
function fftsa.help_back()
  local h = fftsa.help_cur
  fftsa.help_cur = nil
  if h ~= nil and h.home == "opt" and fftsa.optscr ~= nil then
    display.changescreen(fftsa.optscr)
    return true
  end
  return fftsa.show_main()
end

function fftsa.build_help_one(key, home)
  local create = display.create
  local h = {key = key, home = home, page = 1, lines = {},
             text = fftsa.help_text[key]}
  h.scr = create(display.ROOT, display.OBJ_SCREEN, fftsa.help_titles[key])
  if h.scr == nil then return nil end
  -- Immediately, before any child: creating a screen brings it to the front, so the cover
  -- goes back in front now rather than after the rows are built. Deferred to the end of the
  -- build it is a visible flicker the whole time the children are being created.
  fftsa.loading_front()
  h.lines = {}
  local tx = fftsa.help_text_x[key]
  if tx == nil then tx = fftsa.about_x end
  local y, i = fftsa.help_body_y, nil
  for i = 1, fftsa.help_rows do
    h.lines[i] = create(h.scr, display.OBJ_TEXT, tx, y, "",
                        fftsa.about_c_body, fftsa.help_font, display.JUST_LEFT)
    y = y + fftsa.help_body_dy
  end
  -- The icons after the rows, so a pool refusal costs the illustration and not the words.
  h.icons, h.icon_page = {}, {}
  local icons = fftsa.help_icon_list(key)
  if icons ~= nil then
    for i = 1, table.getn(icons) do
      local ic = icons[i]
      local iy = fftsa.help_body_y + (ic.row - 1) * fftsa.help_body_dy
      h.icons[i] = fftsa.icon_at(fftsa.help_icon_x, iy, ic.name, h.scr)
      h.icon_page[i] = ic.page
    end
  end
  h.pageno = create(h.scr, display.OBJ_TEXT, fftsa.about_title_x, fftsa.help_pageno_y(), "",
                    fftsa.about_c_title, display.FONT_SMALL, display.JUST_CENTER)
  -- Kept on the screen's record, because a one-page screen hides them: a PgUp that can only
  -- clamp is a control that does nothing, and the operator cannot tell that by looking.
  h.b_up = create(h.scr, display.OBJ_BUTTON, 8, fftsa.opt_btn_y, "PgUp", 140)
  display.setevent(h.b_up, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.help_pgup) end")
  h.b_dn = create(h.scr, display.OBJ_BUTTON, 168, fftsa.opt_btn_y, "PgDn", 140)
  display.setevent(h.b_dn, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.help_pgdn) end")
  local b_back = create(h.scr, display.OBJ_BUTTON, 630, fftsa.opt_btn_y, "Back", 140)
  display.setevent(b_back, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.help_back) end")
  -- A HELP press on a help screen would otherwise leave the firmware's dialog on the glass
  -- with nothing running to clear it: this timer dismisses it and stays put.
  local t = create(h.scr, display.OBJ_TIMER, 0.5, display.TIMER_FOREVER)
  display.setevent(t, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.help_stay) end")
  -- End App is delivered to the visible screen, and this one can be it.
  display.setevent(h.scr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
  fftsa.help_show_page(h, 1)
  return h
end

-- Built at launch with every other screen, and after the two it returns to.
function fftsa.build_help()
  fftsa.destroy_help()
  fftsa.help_screens = {}
  local key, home
  for key, home in pairs({main = "main", opt = "opt"}) do
    local h = fftsa.build_help_one(key, home)
    if h == nil then
      fftsa.lasterr = "display object pool exhausted building the " .. key
                      .. " help screen -- power cycle the instrument."
      return false, fftsa.lasterr
    end
    fftsa.help_screens[key] = h
  end
  return true
end

-- Built at launch with every other screen. A create on a visible screen is what strands
-- objects, and the only screen visible during a build is the loading cover.
function fftsa.build_about()
  fftsa.destroy_about()
  local create = display.create
  fftsa.aboutscr = create(display.ROOT, display.OBJ_SCREEN, "FFT Analyser - About")
  if fftsa.aboutscr == nil then
    fftsa.lasterr = "display object pool exhausted building the about screen -- "
                    .. "power cycle the instrument."
    return false, fftsa.lasterr
  end
  fftsa.loading_front()
  -- Outside the paged rows, so it stays put whichever page is showing.
  fftsa.about_name = create(fftsa.aboutscr, display.OBJ_TEXT, fftsa.about_title_x,
                            fftsa.about_title_y, "Author: Ian Ameline",
                            fftsa.about_c_title, display.FONT_4, display.JUST_CENTER)
  fftsa.about_lines = {}
  local y, i = fftsa.about_body_y, nil
  for i = 1, fftsa.about_rows do
    fftsa.about_lines[i] = create(fftsa.aboutscr, display.OBJ_TEXT, fftsa.about_x, y, "",
                                  fftsa.about_c_body, display.FONT_1, display.JUST_LEFT)
    y = y + fftsa.about_body_dy
  end
  fftsa.about_pageno = create(fftsa.aboutscr, display.OBJ_TEXT, fftsa.about_title_x,
                              fftsa.opt_btn_y - 8, "", fftsa.about_c_title,
                              display.FONT_SMALL, display.JUST_CENTER)
  local b_up = create(fftsa.aboutscr, display.OBJ_BUTTON, 8, fftsa.opt_btn_y, "PgUp", 140)
  display.setevent(b_up, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.about_pgup) end")
  local b_dn = create(fftsa.aboutscr, display.OBJ_BUTTON, 168, fftsa.opt_btn_y,
                      "PgDn", 140)
  display.setevent(b_dn, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.about_pgdn) end")
  local b_back = create(fftsa.aboutscr, display.OBJ_BUTTON, 630, fftsa.opt_btn_y,
                        "Back", 140)
  display.setevent(b_back, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.about_back) end")
  -- This screen has no help of its own, and the frame timer does not run while it is
  -- showing, so without this a HELP press here leaves the firmware's dialog on the glass
  -- with nothing to clear it.
  local t = create(fftsa.aboutscr, display.OBJ_TIMER, 0.5, display.TIMER_FOREVER)
  display.setevent(t, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.help_stay) end")
  -- End App is delivered to the visible screen, and this one can be it.
  display.setevent(fftsa.aboutscr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
  fftsa.about_show_page(1)
  return fftsa.aboutscr
end

-- A press only switches, like Options: a nil handle means the pool refused at build.
-- Always from the first page, so the screen reads the same every time it is opened.
function fftsa.about()
  if fftsa.aboutscr == nil then return false end
  fftsa.about_show_page(1)
  display.changescreen(fftsa.aboutscr)
  return true
end

-- Back to the form it was opened from, or to the spectrum if the form is gone.
function fftsa.about_back()
  if fftsa.optscr == nil then return fftsa.show_main() end
  display.changescreen(fftsa.optscr)
  return true
end

-- Which pair of terminals the ADC is on. FRONT/REAR is a front-panel button the app does
-- not own and cannot refuse, and the pair not selected is an open input: a signal on the
-- front with the switch on REAR reads as a dead signal rather than as a wrong setting,
-- which is indistinguishable from a broken transform. Named on the settings line so the
-- selection is always visible, and watched by the tick so pressing the button mid-session
-- shows up without an Apply. Total, like every other builder feeding that line.
function fftsa.terminal_text()
  local t = dmm.terminals
  if t == dmm.TERMINALS_REAR then return "REAR" end
  if t == dmm.TERMINALS_FRONT then return "FRONT" end
  return "TERM?"
end

-- Total by construction. This feeds the settings line and the Options readback, both
-- cosmetic, and both are built inside apply() after the hardware has been configured: a
-- rate that is not a number has to read as a gap, not abort the Apply around it.
function fftsa.sample_rate_text(fs)
  if type(fs) ~= "number" then return "?" end
  if fs >= 1000000 then return string.format("%g MS/s", fs / 1000000) end
  if fs >= 1000 then return string.format("%g kS/s", fs / 1000) end
  return string.format("%g S/s", fs)
end

-- Acquisition duration is N/fs, not the first-to-last interval (N-1)/fs.
function fftsa.opt_info_text(fs, n, wi, bi, acq)
  fs, n = fs or fftsa.fs, n or fftsa.n
  if acq == nil then acq = fftsa.fs_acq or fs end
  -- Every input can be nil or zero while the app is part-built or part-torn-down, and a
  -- raise here would abort an Apply over a text line. The bin and record length are the
  -- two that need arithmetic, so they are the two that get withheld; tostring() covers
  -- the window label, which is a table lookup and can miss.
  local wl = tostring(fftsa.win_label(wi, bi))
  if type(fs) ~= "number" or type(n) ~= "number" or n == 0 or fs == 0 then
    return string.format("fs %s   bin ? Hz   acq ? ms   %s",
                         fftsa.sample_rate_text(acq), wl)
  end
  return string.format("fs %s   bin %.2f Hz   acq %.2f ms   %s",
                       fftsa.sample_rate_text(acq), fs / n, 1000 * n / fs, wl)
end

-- Read a field, or answer the fallback if the handle was never built. The firmware
-- returns nil from display.create when the object pool is exhausted, so a field handle
-- can legitimately be nil, and getvalue on nil is a raise in OUR code -- not a firmware
-- refusal. Testing for nil here is what keeps a missing field from taking Options and
-- Apply down with it.
function fftsa.getval(h, fallback)
  if h == nil then return fallback end
  return display.getvalue(h)
end

-- Set a field, or do nothing if the handle was never built. See fftsa.options().
function fftsa.setval(h, v)
  if h == nil then return false end
  display.setvalue(h, v)
  return true
end

-- Set a text, or do nothing if the handle was never built.
function fftsa.settxt(h, t)
  if h == nil then return false end
  display.settext(h, t)
  return true
end

function fftsa.options_preview()
  local lo, hi = fftsa.options_span()
  local n = fftsa.options_samples()
  local fs = fftsa.pick_fs(hi)
  -- Reuse the timestamp-measured rate when previewing the active acquisition rate.
  if fs == fftsa.pick_fs(fftsa.fhi) then fs = fftsa.fs_acq or fftsa.fs end
  local acq = fs
  -- The window comes from the fields too, or three quarters of the line would track
  -- the edit and the fourth would silently show the applied window.
  local wi = fftsa.opt_index(fftsa.getval(fftsa.opt_win), fftsa.win_names, fftsa.win_i)
  local bi = fftsa.opt_index(fftsa.getval(fftsa.opt_beta), fftsa.kbeta_labels,
                             fftsa.kbeta_i)
  local text = fftsa.opt_info_text(fs, n, wi, bi, acq)
  if text ~= fftsa.opt_info_last then
    fftsa.settxt(fftsa.opt_info, text)
    fftsa.opt_info_last = text
  end
end

-- Every button press goes through here. A press is dispatched by the firmware
-- evaluating the command string setevent was given, and an error raised inside that
-- string arrives as a dialog over the app, not as a return value anyone can read --
-- so the handler is the last place that can catch it.
function fftsa.guard(f)
  if f == nil then return false end
  local ok, err = pcall(f)
  if not ok then
    fftsa.lasterr = "button handler failed: " .. tostring(err)
    fftsa.say(fftsa.lasterr)
  end
  return ok
end

-- Put a line on the glass, on the settings line under the peak rows. Failures that are
-- only recorded in fftsa.lasterr are invisible to the operator, who sees a press that did
-- nothing and a previous spectrum still running. The settings line is rewritten by the
-- next fftsa.sg_set_xrange(), so this is not sticky.
function fftsa.say(msg)
  if fftsa.sg_xunit ~= nil then
    display.settext(fftsa.sg_xunit, string.sub(tostring(msg), 1, 70))
  end
end

-- Back to the spectrum screen, which is also what lets the frame timer run again.
function fftsa.show_main()
  if fftsa.sg_scr ~= nil then
    display.changescreen(fftsa.sg_scr)
    return true
  end
  display.changescreen(display.SCREEN_HOME)
  return false
end

-- The six fields from one set of values, and the readback line that follows from them. The
-- single filler, so what Options shows and what Reset offers cannot drift apart.
--
-- A nil handle is what an exhausted pool leaves, so every field goes through the nil-testing
-- setters: the cost is then the fields the pool refused, not the Options button and Apply
-- together. Callers run under fftsa.guard for the same reason -- unguarded, a refusal at the
-- end of the create list leaves the button dead for the life of the app.
function fftsa.opt_fill(flo, fhi, range, win_i, kbeta_i, n)
  fftsa.setval(fftsa.opt_flo, flo)
  fftsa.setval(fftsa.opt_fhi, fhi)
  fftsa.setval(fftsa.opt_rng, fftsa.range_to_idx(range))
  fftsa.setval(fftsa.opt_win, win_i)
  fftsa.setval(fftsa.opt_beta, kbeta_i)
  fftsa.setval(fftsa.opt_n, fftsa.sample_to_idx(n))
  fftsa.options_preview()
end

-- A press only switches. Everything is built in fftsa.start(), so a nil handle
-- means the object pool refused and building it now would fail the same way.
function fftsa.options()
  if fftsa.optscr == nil then return false end
  fftsa.opt_fill(fftsa.flo, fftsa.fhi, fftsa.range, fftsa.win_i, fftsa.kbeta_i, fftsa.n)
  display.changescreen(fftsa.optscr)
  return true
end

-- The shipped settings back into the form, and nothing else: Apply commits them and Cancel
-- abandons them, like every other control here, so a mis-press costs a press. Acquisition is
-- untouched until Apply, which is what keeps this off the 2.667 s commit a changed sample
-- count would otherwise charge for a button nobody meant to hit.
function fftsa.options_reset()
  if fftsa.optscr == nil then return false end
  local d = fftsa.defaults
  fftsa.opt_fill(d.flo, d.fhi, d.range, d.win_i, d.kbeta_i, d.n)
  return true
end

-- The form's span: read the two fields, then clamp through fftsa.span_clamp, which is also
-- where a graph gesture lands. A field the object pool refused reads as nil through
-- getval's fallback, and a value the form cannot produce is not a span -- either keeps what
-- is in force rather than being clamped into something.
function fftsa.options_span()
  local nlo, nhi = fftsa.flo, fftsa.fhi
  local lo = fftsa.getval(fftsa.opt_flo, fftsa.flo)
  local hi = fftsa.getval(fftsa.opt_fhi, fftsa.fhi)
  if hi ~= nil and hi > 0 then nhi = hi end
  if lo ~= nil and lo >= 0 then nlo = lo end
  return fftsa.span_clamp(nlo, nhi)
end

function fftsa.options_apply()
  -- Every field is read before anything is committed: a raise in here leaves the
  -- applied state untouched, where a raise after the first commit would leave the
  -- span changed with the axis, the cover and the message all still describing the
  -- old one -- and say() writes the spectrum screen, which is not on show yet.
  local ri = fftsa.getval(fftsa.opt_rng)
  local wi = fftsa.getval(fftsa.opt_win)
  local bi = fftsa.getval(fftsa.opt_beta)
  local mki = fftsa.opt_index(fftsa.getval(fftsa.opt_mk),
                              fftsa.onoff_labels,
                              fftsa.onoff_to_idx(fftsa.sg_markers))
  local nnew = fftsa.options_samples()
  local nlo, nhi = fftsa.options_span()
  fftsa.flo, fftsa.fhi = nlo, nhi
  local nold    = fftsa.n
  fftsa.n       = nnew
  fftsa.range   = fftsa.idx_to_range(ri)
  fftsa.win_i   = fftsa.opt_index(wi, fftsa.win_names, fftsa.win_i)
  fftsa.kbeta_i = fftsa.opt_index(bi, fftsa.kbeta_labels, fftsa.kbeta_i)
  -- Rebound only on a change: sg_bind() calls removeall, which repaints the whole widget
  -- including its axis labels, and this is the one moment that is already a repaint.
  local mknew = (mki == 2)
  local mkchanged = (mknew ~= fftsa.sg_markers)
  fftsa.sg_markers = mknew
  -- Under the cover: fftsa.apply() rebuilds the window tables and takes a capture,
  -- and the frame timer does not run while its screen is off show, so no frame can
  -- meet half-rebuilt tables.
  fftsa.loading_front()
  -- A failed resize must not resume frames with mismatched FFT and buffer sizes.
  -- An unchanged size cannot desync them, and halting there would freeze the trace
  -- on any failed capture -- a trigger timeout leaves binhz describing the rate in
  -- force, which is exactly the case the frames should keep running through.
  fftsa.halted = (fftsa.n ~= nold)
  local ok, err = pcall(function() fftsa.apply() end)
  -- A failure with the count changed leaves the FFT tables and the capture buffer possibly
  -- sized apart, which is what halted above guards -- but leaving it set is an app that
  -- never draws again and that only another Apply can revive. So the count goes back and
  -- apply() runs once more on the pair that was in force a moment ago. Frames resume if
  -- that works. The Apply is still reported as failed, because the setting asked for did
  -- not take, and fftsa.n now holds what did, so the form reopens on it.
  if not ok and fftsa.n ~= nold then
    fftsa.n = nold
    if pcall(function() fftsa.apply() end) then
      err = tostring(err) .. "  [kept " .. tostring(nold) .. " samples]"
      fftsa.halted, fftsa.errrun = false, 0
      if mkchanged then fftsa.sg_bind() end
    end
  end
  fftsa.show_main()
  if not ok then
    fftsa.lasterr = tostring(err)
    fftsa.say("APPLY FAILED: " .. tostring(err))
  else
    fftsa.halted, fftsa.errrun = false, 0
    -- Apply supersedes a gesture waiting to be re-planned: it has just re-planned from
    -- the same fftsa.flo/fhi, so leaving the flag set buys a second, identical apply on
    -- the next frame.
    fftsa.retune_pending = false
    if mkchanged then fftsa.sg_bind() end
    -- Through the guarded writer, like the two inside apply(): this one is past every
    -- commit, so a raise building the text would report a failed Apply that had in fact
    -- succeeded -- and it is outside the pcall above, so it would escape options_apply
    -- altogether and take the button handler with it.
    fftsa.sg_write_xunit()
  end
  return ok
end

function fftsa.options_cancel()
  fftsa.show_main()
end

-- Lock and Options: two icon buttons in the slot Options filled alone. A button carries
-- no image and display.settext does not accept one, so an icon is an OBJ_IMAGE child
-- created after its button, which puts it on top; a press on the icon reaches the button
-- underneath.
fftsa.btn_y      = 350
fftsa.btn_h      = 60       -- measured off a panel capture
fftsa.btn_lock_x = 660
fftsa.btn_lock_w = 60
fftsa.btn_opt_x  = 730
fftsa.btn_opt_w  = 60
fftsa.lock_img_w = 28       -- fftlockc and fftlocko are 28x34
fftsa.lock_img_h = 34
fftsa.cog_img_w  = 34       -- fftcog is 34x34
fftsa.cog_img_h  = 34

-- tools/package_tspa.py reads these out of the source to decide which assets/<name>.png
-- to embed, so inlining one of them stops its image shipping.
fftsa.img_lock_c = "fftlockc"
fftsa.img_lock_o = "fftlocko"
fftsa.img_cog    = "fftcog"
-- The same three drawings remapped for a black background, by tools/make_help_icons.py:
-- the button art is #9D9D9D line work on a #282828 field, which on a help screen is a dark
-- tile carrying the hardest-to-read thing on it. These are white on black instead, so the
-- field disappears into the screen and the line work matches the body text. Same sizes,
-- 28x34 for the padlocks and 34x34 for the cog.
fftsa.img_help_lkc = "helplockc"
fftsa.img_help_lko = "helplocko"
fftsa.img_help_cog = "helpcog"

-- The lock state on the glass is which of the padlock pair is visible: closed while the
-- view is locked, open while it is free.
function fftsa.lock_icon()
  local on, off = fftsa.lockimg_o, fftsa.lockimg_c
  if fftsa.sg_lock then on, off = fftsa.lockimg_c, fftsa.lockimg_o end
  if off ~= nil then display.setstate(off, display.STATE_INVISIBLE) end
  fftsa.icon_redraw(on)
end

-- Force an icon to paint. Setting a state the object already holds is 0.020 ms and may
-- be taken as nothing to do, so the pair is what guarantees the draw, at 0.034 ms.
function fftsa.icon_redraw(h)
  if h == nil then return false end
  display.setstate(h, display.STATE_INVISIBLE)
  display.setstate(h, display.STATE_ENABLE)
  return true
end

-- Called from fftsa.sg_slow_tick(), which is where the cadence is explained. Re-asserting
-- from a press handler instead does not work: the firmware's repaint comes after it.
function fftsa.icons_reassert()
  fftsa.lock_icon()
  fftsa.icon_redraw(fftsa.optimg)
  return true
end

-- The icon goes before the settle, so a settle that fails cannot leave the padlock showing
-- the opposite of fftsa.sg_lock for the rest of the session. Locking settles at once rather
-- than at the next tick, which is also the only settle a halted app gets; unlocking settles
-- nothing, because a free view is exactly what the press asked for.
function fftsa.toggle_lock()
  fftsa.sg_lock = not fftsa.sg_lock
  fftsa.lock_icon()
  if fftsa.sg_lock then fftsa.sg_settle() end
  return fftsa.sg_lock
end

-- A button whose icon did not load is blank but still works, so a nil here is recorded
-- rather than failing the start.
-- parent defaults to the spectrum screen, which is where the button icons live; the help
-- screens pass their own, to reuse the same embedded images as illustrations.
function fftsa.icon_at(x, y, name, parent)
  if name == nil then return nil end
  if parent == nil then parent = fftsa.sg_scr end
  local img = display.create(parent, display.OBJ_IMAGE, x, y, name)
  if img == nil then
    fftsa.lasterr = "image " .. tostring(name) .. " did not load"
    fftsa.say(fftsa.lasterr)
  end
  return img
end

-- A button with one or two icons centred over it, two being the padlock pair. An
-- exhausted object pool returns nil, so the icons are skipped without their button:
-- an icon alone looks pressable and does nothing.
function fftsa.icon_button(x, w, cmd, iw, ih, name1, name2)
  local b = display.create(fftsa.sg_scr, display.OBJ_BUTTON, x, fftsa.btn_y, " ", w)
  if b == nil then
    fftsa.lasterr = "button at x=" .. tostring(x) .. " could not be created"
    fftsa.say(fftsa.lasterr)
    return nil, nil, nil
  end
  display.setevent(b, display.EVENT_PRESS, cmd)
  local ix = x + math.floor((w - iw) / 2)
  local iy = fftsa.btn_y + math.floor((fftsa.btn_h - ih) / 2)
  return b, fftsa.icon_at(ix, iy, name1), fftsa.icon_at(ix, iy, name2)
end

-- Everything the app ever displays, created here and nowhere else. The cover comes
-- first so that no screen is ever assembled in view.
function fftsa.build()
  fftsa.loading_build()
  fftsa.loading_front()
  -- The trace buffer at sg_maxpts, for the life of the app: allocated at the CEILING
  -- rather than at sg_ncol so the point count stays adjustable upwards while running
  -- without anything being resized or reallocated.
  local scr, why = fftsa.sg_build("FFT SPECTRUM ANALYSER", fftsa.n / 2, fftsa.sg_maxpts)
  if scr == nil then return false, why end
  -- The buttons died with the screen fftsa.sg_build() just destroyed: clear the
  -- stale handles, do not delete them.
  fftsa.optbtn, fftsa.optimg = nil, nil
  fftsa.lockbtn, fftsa.lockimg_c, fftsa.lockimg_o = nil, nil, nil
  fftsa.lockbtn, fftsa.lockimg_c, fftsa.lockimg_o = fftsa.icon_button(
    fftsa.btn_lock_x, fftsa.btn_lock_w,
    "if fftsa ~= nil then fftsa.guard(fftsa.toggle_lock) end",
    fftsa.lock_img_w, fftsa.lock_img_h, fftsa.img_lock_c, fftsa.img_lock_o)
  fftsa.lock_icon()
  fftsa.optbtn, fftsa.optimg = fftsa.icon_button(
    fftsa.btn_opt_x, fftsa.btn_opt_w,
    "if fftsa ~= nil then fftsa.guard(fftsa.options) end",
    fftsa.cog_img_w, fftsa.cog_img_h, fftsa.img_cog)
  local optok, optwhy = fftsa.build_options()
  if optok == false then return false, optwhy end
  local aboutok, aboutwhy = fftsa.build_about()
  if aboutok == false then return false, aboutwhy end
  -- After the two screens they return to, so Back has somewhere to go.
  local helpok, helpwhy = fftsa.build_help()
  if helpok == false then return false, helpwhy end
  return fftsa.sg_scr
end

-- Timer period leaving a frame of this length fftsa.tick_idle of slack, rounded up to the
-- firmware's 0.05 s tick floor (arm(0.045) is refused with event 1131). The one place the
-- occupancy rule lives, so the modelled first arm and the measured re-arms agree.
--
-- The idle is what dispatches a touch: delay() lets the display task paint, but a press
-- needs the interpreter, and a tick landing during a frame is dropped. At the 0.05 s floor
-- that left 12 ms of 500 at 4096 samples, where Options was unreachable.
--
-- An amount, not a fraction, because that is the shape of the thing being reserved for:
-- dispatching a press costs about the same however long the frame was, so a reserve in
-- proportion to frame work over-provisions the long counts and under-provisions the short
-- ones. It is also the display task's budget, with fftsa.sg_yield -- that task runs only
-- while Lua is blocked.
--
-- 20 ms rather than more because of where the tick boundaries fall: the floor only costs
-- rate when it pushes busy over a multiple of 50 ms, and at 25 or 30 it does that to the
-- 80 ms frame and to 2048 samples while buying nothing at the long counts that 20 does not
-- already buy. It is 1.7 times the 12 ms that failed, not a wide margin, and it is a live
-- knob: raise fftsa.tick_idle from the socket if a press gets swallowed, no reinstall.
--
-- The 2.5 ms of slack prefers rate over idle. A tick is 50 ms, so holding the target to
-- the last millisecond buys a fiftieth of a tick of idle and costs a whole tick of rate.
fftsa.tick_idle = 0.020
-- The period granularity, and the timer's own floor. The grid was 0.05 for both, which is
-- what the firmware's minimum is, not what its resolution is -- so the period could only
-- ever be a multiple of 50 ms and a frame needing 205 ms was armed at 250. A finer grid
-- costs nothing and gives the loop below somewhere to land.
fftsa.tick_grid = 0.010
fftsa.tick_min  = 0.050
-- How far the period must move before it is worth re-arming. Every re-arm is a display timer
-- deleted and created against a 463-object pool, and the 50 ms grid used to supply this
-- deadband as a side effect of being coarse. On a 10 ms grid it has to be explicit, or a
-- period that dithers by one step re-arms for the life of the app.
fftsa.tick_rearm = 0.020
-- How far the period must RISE before it is re-armed, against one grid step to fall. Wider
-- than the jitter it is meant to ignore and narrower than a size change.
fftsa.tick_rise = 0.050

function fftsa.tick_period(busy)
  if busy == nil or busy <= 0 then return fftsa.tick_min end
  local g = fftsa.tick_grid
  local ticks = math.ceil((busy + fftsa.tick_idle) / g - 0.05)
  if ticks < 1 then ticks = 1 end
  local p = ticks * g
  if p < fftsa.tick_min then p = fftsa.tick_min end
  return p
end

-- The FIRST arm, before any frame has been timed. From here on frame() re-arms from the
-- work it actually measures.
function fftsa.frame_period(n)
  return fftsa.tick_period(fftsa.frame_estimate(n))
end

-- Arm the frame timer. It is active only while its parent screen is visible, which is
-- what stops frames while Options or About is on show. One frame per tick: back-to-back
-- frames keep the interpreter out of its event loop.
function fftsa.arm(period_s)
  if period_s == nil then period_s = 0.05 end
  if fftsa.timer ~= nil then
    fftsa.del_obj(fftsa.timer)
    fftsa.timer = nil
  end
  if fftsa.sg_scr == nil then return nil end
  -- The count the live timer was armed for, so fftsa.apply() can tell a press that needs a
  -- new period from one that does not.
  fftsa.armed_n = fftsa.n
  fftsa.timer = display.create(fftsa.sg_scr, display.OBJ_TIMER, period_s, display.TIMER_FOREVER)
  display.setevent(fftsa.timer, display.EVENT_PRESS, "if fftsa ~= nil and fftsa.frame ~= nil then fftsa.frame() end")
  return fftsa.timer
end

-- End App tears the screen set down and nils every handle. Nothing is carried across a
-- launch.
--
-- Keeping them for the next launch to reuse was tried and reverted: opening the app a
-- second time answered 1703, object ID is invalid. So a handle that was valid at
-- EVENT_ENDAPP named nothing by the time the app came back. What frees them was not
-- established; what was established is that the handle does not survive, and that this
-- teardown is what makes the next launch safe, because it leaves nothing for a later call
-- to reach for.
--
-- A launch cannot check first, either: every display call on a dead handle posts that same
-- 1703 and raises a modal dialog over a half-built app, so there is no probe that costs
-- less than the fault it looks for.
function fftsa.cleanup()
  fftsa.stop()
end

-- Hooked as soon as the spectrum screen exists, so a later startup failure still
-- leaves a way out that cleans up.
function fftsa.install_cleanup()
  if fftsa.sg_scr == nil then return false end
  local ok, err = pcall(function()
    display.setevent(fftsa.sg_scr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
  end)
  if not ok then fftsa.lasterr = "ENDAPP hook failed: " .. tostring(err) end
  return ok
end

-- One cleanup path for a failed start, so the two ways of failing cannot drift apart.
function fftsa.start_failed(why)
  fftsa.lasterr = tostring(why)
  fftsa.stop()
  print("fftsa start FAILED (cleaned up): " .. tostring(why))
  -- No console as an installed App, so the failure goes on the panel.
  fftsa.show_error(tostring(why))
  return false
end

-- Startup, guarded end to end so a failure part-way leaves nothing without a teardown.
-- The opening fftsa.stop() reclaims a previous launch's handles: as an installed App the
-- script re-runs on every open, and an exit that skipped EVENT_ENDAPP (the Home screen,
-- another App) leaves them behind. fftsa.cleanup() says why they are never reused.
function fftsa.start()
  fftsa.stop()
  fftsa.halted, fftsa.errrun, fftsa.stop_pending = false, 0, false
  -- Cleared per launch, because fftsa survives one: left set, the freeze diagnostic would
  -- bail out of the FIRST frame of the next launch and the trace would never be drawn at all,
  -- which reads as permanent flicker rather than as the frozen trace it is meant to give.
  fftsa.froze = false

  -- The refusal the capability gate promised, taken before anything is built. Without it
  -- the first dsp.* write is inside apply(), so the whole screen set is created and then
  -- torn down again by start_failed -- and a create/delete cycle risks part of the
  -- 463-object pool for the rest of the power cycle.
  if fftsa.dsp_absent then
    return fftsa.start_failed("no DSP implementation: the archive was built without "
                              .. "dsp_lua.tsp and this instrument has no dsp module")
  end

  -- The display object pool running out is a RETURN, not a raise: display.create answers
  -- nil and posts one event, and build() passes that up as false and a reason. Handled
  -- here directly rather than raised into the boundary below, which would be reporting a
  -- condition to ourselves.
  local built, why = fftsa.build()
  if built == false then return fftsa.start_failed(why or "build failed") end

  -- Resolved once, here, so the 1 Hz tick tests one boolean instead of the six names the
  -- HELP recogniser needs out of the undocumented ki namespace.
  fftsa.help_probe()

  local hooked = fftsa.install_cleanup()
  -- The boundary that remains, and what it is for: apply() is arithmetic over tables
  -- fft_init builds, so a defect in OUR code raises here. A raise escaping a timer or
  -- button callback on this firmware posts -286 and leaves the app on screen and dead,
  -- so one backstop per entry point stays until those paths are proved non-raising.
  -- The opening count, before the only Apply start() runs, so choosing it costs no second
  -- capture and no reordering of the install below. Both names move together or Reset would
  -- restore a count this never opened at.
  if fftsa.native_likely() then
    fftsa.n = fftsa.n_compiled
    fftsa.defaults.n = fftsa.n_compiled
  end
  -- The period is settled here and the timer created at the end of start(), after the
  -- screen is on show: see the arm there for why the two are separated.
  local ok, err = pcall(function()
    fftsa.apply()
    fftsa.period = fftsa.frame_period(fftsa.n)
  end)
  if not ok then return fftsa.start_failed(tostring(err)) end

  -- Attempt to initialise the native DSP path. nl.ready stays false if the binary is not
  -- in the archive, if the install fails, or if this boot has already installed heap code:
  -- a second install wedges the interpreter, nl.init refuses one, and start() runs on
  -- every app start. In all of those the frame body falls back to dsp.spectrum.
  --
  -- SIZED FOR fftsa.nl_nmax, NOT fftsa.n. The arena is built once per boot and nl.reinit
  -- re-plans inside it, so a sample count press afterwards costs one call rather than
  -- another install -- and an install is the one thing that cannot be repeated freely.
  -- nl_replan() below then plans for the count actually selected.
  --
  -- The window and beta still have to be passed, because a refusal between here and the
  -- replan would leave the plan built from defaults: n = 512 and DSP_WINDOW_HANN, which is
  -- a spectrum of the wrong length with the wrong taper while the panel shows the user's
  -- choices. win_to_native is OUR enum map, not fftsa.win_to_dsp, which targets Keithley's
  -- dsp.WINDOW_* -- the note at the top of this file spells out what conflating them costs.
  --
  -- The trace point ceiling is sg_maxpts rather than the count in force, so raising
  -- sg_ncol while the app runs needs no reinstall either.
  --
  -- nil for the barrier buffer: nl.init barriers on a buffer it fills itself. fftsa.cap
  -- holds no readings until the first capture completes, and buffer.getstats on an empty
  -- buffer need not make the service-task call that the barrier is -- which bluescreened
  -- the instrument once, from exactly this call site.
  if fftsa.nl ~= nil and type(fftsa.nl.init) == 'function' then
    fftsa.nl.init(nil, fftsa.nl_nmax, fftsa.nl.win_to_native(fftsa.win_i),
                  fftsa.kbeta(fftsa.kbeta_i), 1, fftsa.nl.FFT_FOURSTEP,
                  fftsa.sg_maxpts)
    fftsa.nl_replan()
  end
  -- NO IMPLEMENTATION AT ALL is a refusal, not twenty error frames a second. The archive
  -- ships no interpreted transform -- tsp/fft_interp.tsp is left out -- so if the compiled
  -- path did not come up there is nothing to compute a spectrum with, and every frame would
  -- post EUNSUPPORTED behind a panel that looks like it is working. nl_lasterr carries why
  -- the install refused.
  if fftsa.fft_init == nil
     and (fftsa.nl == nil or not fftsa.nl.ready or not fftsa.nl_usable()) then
    return fftsa.start_failed("the compiled DSP did not start and this archive has no "
                              .. "interpreted fallback -- " .. tostring(fftsa.nl_lasterr)
                              .. " -- power cycle the instrument and try again")
  end
  if not hooked then
    print("fftsa WARNING: End App cleanup not hooked -- " .. tostring(fftsa.lasterr))
    display.settext(fftsa.sg_xunit, "WARNING: End App will not clean up")
  end
  print("fftsa started fs=" .. fftsa.fs .. " bin=" .. fftsa.binhz ..
        " range=" .. fftsa.range .. " window=" .. fftsa.win_label())
  -- Switching away from the cover is what starts the frames: the timer only runs
  -- while the screen it is parented to is the one on show. The cover itself stays
  -- allocated until fftsa.stop(), since Apply raises it again.
  fftsa.show_main()
  -- The widget's first draw of this trace gets a window of its own before any frame can
  -- clear the buffer under it. The switch above is that first draw, of a trace object built
  -- moments earlier, and a frame opens with tb.clear(), which takes the buffer's n to zero;
  -- a timer armed before the switch can fire inside the draw. Creating the timer after the
  -- yield, rather than only yielding, keeps the ordering independent of whether delay()
  -- dispatches timer callbacks.
  --
  -- Under pcall because display.create answers nil on an exhausted pool and the setevent
  -- that follows would raise, which here would escape start().
  delay(fftsa.sg_first_paint)
  local aok, aerr = pcall(function() fftsa.arm(fftsa.period) end)
  if not aok then return fftsa.start_failed(tostring(aerr)) end
  return true
end

function fftsa.stop()
  -- Not underneath a running frame, which would be left writing into a deleted
  -- buffer: defer once (fftsa.frame() runs the pending stop as it finishes), then
  -- proceed regardless, so a stuck guard cannot make the app impossible to stop.
  if fftsa.busy and not fftsa.stop_pending then
    fftsa.stop_pending = true
    return false
  end
  fftsa.stop_pending = false
  -- Timer first: stop frames before removing what the frames use.
  if fftsa.timer ~= nil then fftsa.del_obj(fftsa.timer) end
  fftsa.timer = nil
  fftsa.optbtn, fftsa.optimg = nil, nil       -- children of the spectrum screen
  fftsa.lockbtn, fftsa.lockimg_c, fftsa.lockimg_o = nil, nil, nil
  -- THE PLAN GOES WITH THE APP. Natively it is one arena, and the app is relaunchable --
  -- every module opens with `fftsa = fftsa or {}` and fftsa.start() opens with this -- so an
  -- arena nobody releases is leaked per launch for the rest of the power cycle, which is the
  -- failure class this app is already careful about for buffers and for the 463-object
  -- display pool. Under pcall for the same reason sg_destroy is: a stop that raises leaves
  -- the rest of the teardown undone.
  --
  -- The cost is that the next launch rebuilds the tables, 0.163 ms a sample. It is paid
  -- behind the loading cover, start() running apply() before it switches away.
  pcall(function() dsp.release() end)
  -- release: the trace buffers are deleted and defbuffer1 made current again, rather than
  -- handed to a next launch. sg_destroy() says why the two callers differ.
  pcall(function() fftsa.sg_destroy(true) end)   -- screen, graph, texts, trace buffers
  fftsa.destroy_options()
  fftsa.destroy_about()
  fftsa.destroy_help()
  fftsa.loading_destroy(display.SCREEN_HOME)
  if fftsa.errscr ~= nil then
    fftsa.del_obj(fftsa.errscr)
    fftsa.errscr = nil
  end
  if fftsa.cap ~= nil then
    fftsa.del_buf(fftsa.cap)
    fftsa.cap, fftsa.cap_cap = nil, nil
  end
  -- The pending re-plan goes with the app. Two stops under one frame reach the teardown
  -- from the second call, which clears stop_pending -- and fftsa.frame() then finds the flag
  -- set with nothing left to retune, where apply() strands a fresh capture buffer on a
  -- screen that is already gone. This is also what keeps a gesture from the previous launch
  -- off the next one's first frame, fftsa.start() opening with a stop().
  fftsa.busy, fftsa.halted, fftsa.errrun = false, false, 0
  fftsa.retune_pending, fftsa.armed_n = false, nil
  return true
end

-- Startup failure on the panel. End App is hooked here too and the handle kept, so
-- stop() can delete the screen.
--
-- The commonest reason startup fails is an exhausted pool, and display.create then
-- answers nil here too: unguarded, every child is built against a nil parent and
-- changescreen(nil) raises, leaving a blank panel in exactly the case this screen exists
-- for. Nothing can be drawn at that point, so it says so on the console instead.
--
-- These children are created on a visible screen, which nothing else in the app does:
-- it runs once, after startup has already failed, and the cover is gone by then.
function fftsa.show_error(msg)
  local shown = pcall(function()
    if fftsa.errscr ~= nil then
      fftsa.del_obj(fftsa.errscr)
      fftsa.errscr = nil
    end
    fftsa.errscr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER ERROR")
    if fftsa.errscr == nil then
      -- No screen to report on, so the console is all there is. Returning rather than
      -- raising: the caller is already handling a failure and has nothing better to do
      -- with a second one.
      print("fftsa: object pool exhausted; no error screen")
      return false
    end
    display.create(fftsa.errscr, display.OBJ_TEXT, 20, 80,
                   "The analyser could not start.", 16736352,   -- red FF6060
                   display.FONT_MEDIUM, display.JUST_LEFT)
    local m = tostring(msg)
    local y = 140
    local i = 1
    while i <= string.len(m) and y <= 400 do
      display.create(fftsa.errscr, display.OBJ_TEXT, 20, y, string.sub(m, i, i + 79),
                     14737632, display.FONT_SMALL, display.JUST_LEFT)   -- light grey E0E0E0
      i = i + 80
      y = y + 22
    end
    display.create(fftsa.errscr, display.OBJ_TEXT, 20, 420,
                   "Press End App to exit.", 9474192,   -- grey 909090
                   display.FONT_SMALL, display.JUST_LEFT)
    display.setevent(fftsa.errscr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
    display.changescreen(fftsa.errscr)
  end)
  if not shown or fftsa.errscr == nil then
    fftsa.errscr = nil
    display.changescreen(display.SCREEN_HOME)
    print("fftsa: could not build the error screen either -- " .. tostring(msg))
  end
  return fftsa.errscr
end
