-- spectrum_ui.tsp -- the loading cover.
--
-- A screen holding nothing but a line of text, kept in front while the real screens are
-- built and while Apply reconfigures the hardware. Creating a screen makes it active, so
-- every screen build raises this again before its first child, or the operator watches a
-- screen assemble itself one create at a time. Made once and deleted once by stop(): raising
-- it is a changescreen and nothing else, a create/delete per raise churning the 463-object
-- pool.

fftsa = fftsa or {}   -- the single global this app exposes

if fftsa.load_handles_inited == nil then
  fftsa.loadscr = nil
  fftsa.loadtxt = nil
  fftsa.load_handles_inited = true
end
-- x for the string below on FONT_MEDIUM, measured on the panel.
fftsa.load_x = 261
fftsa.load_y = 214

function fftsa.loading_build()
  if fftsa.loadscr ~= nil then return fftsa.loadscr end
  fftsa.loadscr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT SPECTRUM ANALYSER")
  if fftsa.loadscr == nil then return nil end     -- pool exhausted; a visible build is the cost
  fftsa.loadtxt = display.create(fftsa.loadscr, display.OBJ_TEXT, fftsa.load_x, fftsa.load_y,
                                 "Loading, please wait...", 16777215, display.FONT_MEDIUM)
  -- End App is hooked here too: the firmware may deliver EVENT_ENDAPP only to the
  -- visible screen, and this is the visible one while Apply rebuilds the tables.
  display.setevent(fftsa.loadscr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
  return fftsa.loadscr
end

function fftsa.loading_front()
  if fftsa.loadscr == nil then return false end
  display.changescreen(fftsa.loadscr)
  return true
end

-- Put a real screen in front, then take the cover away. Switch first, delete
-- second: deleting the screen on show leaves the panel black.
function fftsa.loading_destroy(showscr)
  if showscr == nil then showscr = display.SCREEN_HOME end
  if fftsa.loadscr == nil then
    display.changescreen(showscr)
    return false
  end
  -- The text is a child and not a screen, so it takes no yield of its own; the cover does.
  fftsa.del_obj(fftsa.loadtxt)
  fftsa.del_scr(fftsa.loadscr, showscr)
  fftsa.loadtxt, fftsa.loadscr = nil, nil
  return true
end
