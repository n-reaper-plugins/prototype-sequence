-- @description PrototypeSequence: random sound sequences on one PROTO folder track, driven by markers & regions
-- @version @@VERSION@@
-- @about
--   Run this action to open the PrototypeSequence window (needs ReaImGui: ReaPack > ReaTeam Extensions;
--   a folder dialog additionally needs js_ReaScriptAPI, otherwise a file dialog / drag&drop / typing is used).
--   Choose a sounds root folder with one sub-folder per sound group (root/bells, root/whistles).
--   Every marker or region NAMED like a sub-folder gets that group: one track per sound, all items placed,
--   one picked by the seed (from seed + marker number + file name) and the others muted.
--   Run the action again while the window is open to close it.

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

if not r.ImGui_CreateContext then
  r.MB("This script needs the ReaImGui extension.\n\nInstall it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').", "PrototypeSequence", 0)
  return
end

local App = require("ProtoApp")
local UI  = require("ProtoUI")

local EXT = "PrototypeSequenceApp"

-- single instance: running the action a second time asks the running one to close
local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if cmdid and cmdid ~= 0 then r.SetToggleCommandState(sec, cmdid, on and 1 or 0); r.RefreshToolbar2(sec, cmdid) end
end
set_toggle(true)

math.randomseed(os.time())
local app = App.new()
local ui = UI.new(app)

local function shutdown()
  app:save()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local last_hb, last_err = 0, nil
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end

  local ok, err = pcall(app.tick, app)
  if not ok and tostring(err) ~= last_err then
    last_err = tostring(err)
    app.err = "Error: " .. last_err
  end
  if ui:frame() then r.defer(loop) else shutdown() end
end

loop()
