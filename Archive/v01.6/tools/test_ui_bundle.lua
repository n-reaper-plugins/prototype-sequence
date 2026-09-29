package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")

local function fresh()
  local S = Mock.install()
  local st = Stub.install(reaper)
  Mock.make_sounds("/snd", { bells = { "a.wav", "b.wav" }, whistles = { "w.wav" } })
  Mock.add_marker("bells", 1); Mock.add_marker("oops", 2)
  return S, st
end

------------------------------------------------------------------ UI (source modules)
do
  local S, st = fresh()
  local App, UI = require("ProtoApp"), require("ProtoUI")
  local app = App.new()
  local ui = UI.new(app)
  app:tick()
  T.eq(ui:frame(), true, "frame returns open")
  T.ok(app.err == nil, "no UI error: " .. tostring(app.err))
  local joined = table.concat(st.texts, "|")
  T.ok(joined:find("Drop the sounds root folder", 1, true) or st.calls[1]:find("Drop the sounds"), "drop zone shown")

  -- drop a folder onto the drop zone
  st.drop = "/snd"
  ui:frame(); app:tick()
  T.eq(app.cfg.root, "/snd", "dropped folder becomes root")
  T.eq(app.ngroups, 2, "scanned after drop")

  -- drop a FILE -> its folder
  st.drop = "/snd/bells/a.wav"
  ui:frame()
  T.eq(app.cfg.root, "/snd/bells", "dropped file -> parent folder")
  st.drop = "/snd"; ui:frame()

  -- typed path
  st.input_text = "/snd/"; ui:frame()
  T.eq(app.cfg.root, "/snd", "typed path")

  -- colours: matching name green, other red
  app:tick(); st.texts = {}; ui:frame()
  T.eq(st.last_color["bells"], 0x5FE07FFF, "matching marker is green")
  T.eq(st.last_color["oops"], 0xFF5F5FFF, "non-matching marker is red")

  -- seed edit
  st.seed_value = 77; st.deact = true; ui:frame()
  T.eq(app.cfg.seed, 77, "seed applied when editing finishes")

  -- buttons
  st.clicks["Freeze"] = true; ui:frame()
  T.eq(app:live(), false, "Freeze button")
  st.clicks["Go live"] = true; ui:frame()
  T.eq(app:live(), true, "Go live button")
  st.clicks["Freeze & clean"] = true; ui:frame()
  T.eq(app:live(), true, "clean needs confirmation")
  st.clicks["Yes, freeze & clean"] = true; ui:frame()
  T.eq(app:live(), false, "Freeze & clean after confirm")
  local before = app.cfg.seed
  st.clicks["Re-roll"] = true; ui:frame()
  T.ok(app.cfg.seed ~= before, "re-roll changes seed")
end

------------------------------------------------------------------ bundle: real main loop
do
  for k in pairs(package.loaded) do if k:match("^Proto") then package.loaded[k] = nil end end   -- the bundle must bring its own modules
  package.path = "./tools/?.lua;" .. package.path:gsub("%./src/%?%.lua;", "")
  local S = fresh()
  S.projext["PrototypeSequence/root"] = "/snd"
  local ok, err = pcall(dofile, "dist/PrototypeSequence.lua")
  T.ok(ok, "bundle runs: " .. tostring(err))
  T.eq(S.ext["PrototypeSequenceApp/running"], "1", "marked as running")
  local n = 0
  while #S.deferred > 0 and n < 12 do
    local f = table.remove(S.deferred, 1); S.clock = S.clock + 1; f(); n = n + 1
  end
  T.ok(Mock.track_named("PROTO") ~= nil, "PROTO created by live loop")
  T.ok(Mock.track_named("bells") ~= nil and Mock.track_named("a") ~= nil, "bells group + sounds created")
  T.eq(Mock.track_named("whistles"), nil, "no marker for whistles -> no group")
  local _, bal = Mock.structure(); T.eq(bal, 0, "balanced")

  -- second run asks the first to stop
  pcall(dofile, "dist/PrototypeSequence.lua")
  T.eq(S.ext["PrototypeSequenceApp/stop"], "1", "second run requests stop")
  local f = table.remove(S.deferred, 1); if f then f() end
  T.eq(S.ext["PrototypeSequenceApp/running"], "0", "loop shut down")
  T.eq(S.projext["PrototypeSequence/mode"], "live", "mode saved")
end
T.done("test_ui_bundle")
