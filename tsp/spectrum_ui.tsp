-- Loading cover for startup and Apply. Creating a screen makes it active;
-- raise the cover again before building the new screen's children.

fftsa = fftsa or {}

if fftsa.load_handles_inited == nil then
  fftsa.loadscr = nil
  fftsa.loadtxt = nil
  fftsa.load_handles_inited = true
end
fftsa.load_x = 261
fftsa.load_y = 214

function fftsa.loading_build()
  if fftsa.loadscr ~= nil then return fftsa.loadscr end
  fftsa.loadscr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT SPECTRUM ANALYSER")
  if fftsa.loadscr == nil then return nil end
  fftsa.loadtxt = display.create(fftsa.loadscr, display.OBJ_TEXT, fftsa.load_x, fftsa.load_y,
                                 "Loading, please wait...", 16777215, display.FONT_MEDIUM)
  -- Hook End App on the cover too: the firmware can dispatch it to the visible screen.
  display.setevent(fftsa.loadscr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
  return fftsa.loadscr
end

function fftsa.loading_front()
  if fftsa.loadscr == nil then return false end
  -- Disarm the Back handler before showing the cover intentionally.
  if fftsa.loadwatch then
    display.setevent(fftsa.loadscr, display.EVENT_PRESS, 0)
    fftsa.loadwatch = false
  end
  display.changescreen(fftsa.loadscr)
  fftsa.scr_now = fftsa.loadscr
  return true
end

-- Physical EXIT can return to the retained cover instead of sending EVENT_ENDAPP.
-- Arm its on-show cleanup only after switching away.
function fftsa.loading_watch_back()
  if fftsa.loadscr == nil or fftsa.loadwatch then return end
  display.setevent(fftsa.loadscr, display.EVENT_PRESS,
    "if fftsa ~= nil and fftsa.loadwatch then fftsa.guard(fftsa.cleanup) end")
  fftsa.loadwatch = true
end

-- Switch away before deleting the cover; deleting the active screen leaves it black.
function fftsa.loading_destroy(showscr)
  if showscr == nil then showscr = display.SCREEN_HOME end
  fftsa.loadwatch = false
  if fftsa.loadscr == nil then
    display.changescreen(showscr)
    return false
  end
  fftsa.del_obj(fftsa.loadtxt)
  fftsa.del_scr(fftsa.loadscr, showscr)
  fftsa.loadtxt, fftsa.loadscr = nil, nil
  return true
end
