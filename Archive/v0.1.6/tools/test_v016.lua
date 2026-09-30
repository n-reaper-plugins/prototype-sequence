package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")
local S = Mock.install()
local st = Stub.install(reaper)
local Core = require("ProtoCore")
local App = require("ProtoApp")
local UI = require("ProtoUI")

Mock.make_sounds("/snd", { bells = { "a.wav", "b.wav" }, whistles = { "w.wav" } })
Mock.make_sounds("/other", { bells = { "x.wav" } })
local function names() local n = {}; for _, t in ipairs(S.tracks) do n[#n + 1] = t.name end; return table.concat(n, "|") end
local function count_managed() local n = 0; for _, t in ipairs(S.tracks) do if t.ext.PS_ROLE and t.ext.PS_ROLE ~= "" then n = n + 1 end end; return n end
local function new_app() local a = App.new(); return a end
local app
local function tick() S.clock = S.clock + 1; app:tick() end
local function settle() tick(); tick(); tick() end

------------------------------------------------------------------ folders: project vs. default
app = new_app()
T.eq(app.cfg.root, "", "no folder yet")
app:set_root("/snd")
T.eq(S.projext["PrototypeSequence/root"], "/snd", "folder stored in the PROJECT")
T.eq(S.ext["PrototypeSequence/default_root"], "/snd", "first folder ever chosen also becomes the default")

-- another project starts with the default, but does not write it until used
S.projext = {}
S.proj = "PROJ_B"
local writes0 = S.proj_writes
local b = new_app()
T.eq(b.cfg.root, "/snd", "new project starts with the default folder")
T.eq(b.cfg.inherited, true, "... marked as inherited")
b:save()
T.eq(S.projext["PrototypeSequence/root"], nil, "inherited folder is not written to the project yet")
Mock.add_marker("bells", 1)
app = b; app:set_root("/other")               -- choosing another folder in project B
T.eq(S.projext["PrototypeSequence/root"], "/other", "project B keeps its own folder")
T.eq(S.ext["PrototypeSequence/default_root"], "/snd", "... and the default is NOT changed by it")
app:make_default()
T.eq(S.ext["PrototypeSequence/default_root"], "/other", "Make this the default")
app:use_default(); T.eq(app.cfg.root, "/other", "use default")
-- project A (has its own folder) is unaffected by a changed default
S.projext = { ["PrototypeSequence/root"] = "/snd" }
S.proj = "PROJ_A"
local a2 = new_app()
T.eq(a2.cfg.root, "/snd", "project with its own folder ignores the default")
T.eq(a2.cfg.inherited, false, "not inherited")
-- inherited folder is pinned by the first sync
S.projext = {}; S.proj = "PROJ_C"; S.markers = {}; S.tracks = {}
Mock.add_marker("bells", 1)
app = new_app(); tick(); tick(); tick()
T.eq(app.cfg.inherited, false, "first sync pins the inherited folder")
T.eq(S.projext["PrototypeSequence/root"], "/other", "... into the project")
-- old 0.1.x global key is still honoured
S.ext["PrototypeSequence/default_root"] = nil; S.ext["PrototypeSequence/root"] = "/snd"
S.projext = {}
T.eq(new_app().cfg.default_root, "/snd", "0.1.x 'root' key migrates to the default")

------------------------------------------------------------------ save hygiene
S.projext = { ["PrototypeSequence/root"] = "/snd", ["PrototypeSequence/seed"] = "1", ["PrototypeSequence/mode"] = "live", ["PrototypeSequence/fade"] = "0.05" }
S.proj = "PROJ_D"; S.tracks = {}; S.markers = {}
app = new_app()
local w = S.proj_writes
app:save(); app:save(); app:set_follow(false); app:set_follow(true)
T.eq(S.proj_writes, w, "saving unchanged state / toggling Follow does not touch the project")
app:set_seed(9)
T.eq(S.proj_writes, w + 1, "only the changed key is written")

------------------------------------------------------------------ renaming and look-alikes
S.projext = {}; S.tracks = {}; S.markers = {}; S.proj = "PROJ_E"
app = new_app(); app:set_root("/snd")
local m1 = Mock.add_marker("bells", 0)
Mock.add_marker("whistles", 30)
settle()
T.eq(names(), "PROTO|bells|a|b|whistles|w", "baseline")
local proto = Mock.track_named("PROTO")
proto.name = "My Sequence"; Mock.track_named("bells").name = "BELLZ"; Mock.track_named("a").name = "kick-a"
local cnt = #S.tracks
m1.pos = 5; Mock.touch(); settle()
T.eq(names(), "My Sequence|BELLZ|kick-a|b|whistles|w", "renamed tracks stay renamed after a sync")
T.eq(#S.tracks, cnt, "and no extra tracks were created")
T.eq(Mock.track_named("kick-a").items[1].p.D_POSITION, 5, "renamed track is still managed (its item followed the marker)")
T.eq(app.info.root_name, "My Sequence", "info shows the real name of the root")
T.eq(app.info.tracks, 5, "info counts managed tracks")
-- another track called PROTO is just a track
local fake = Mock.new_user_track("PROTO")
m1.pos = 6; Mock.touch(); settle()
T.eq(fake.ext.PS_ROLE, nil, "look-alike is not touched or adopted")
T.eq(#S.tracks, cnt + 1, "no new root was created (a tagged one exists)")
T.eq(app.info.root_name, "My Sequence", "managed root still the renamed one")
app:show_root()
T.eq(proto.sel, true, "Show selects the managed root"); T.eq(S.last_command, 40913, "and scrolls to it")
T.eq(fake.sel, false, "not the look-alike")
-- user deletes the root track but leaves the children: a new root is made, children adopted
reaper.DeleteTrack(proto); Mock.touch(); app:sync_now(); settle()
local _, bal = Mock.structure(); T.eq(bal, 0, "structure balanced after root was deleted")
local roots = 0
for _, t in ipairs(S.tracks) do if t.ext.PS_ROLE == "root" then roots = roots + 1 end end
T.eq(roots, 1, "exactly one new managed root")
T.eq(Mock.track_named("kick-a").ext.PS_ROLE, "snd", "children were adopted, not duplicated")

------------------------------------------------------------------ duplicated managed track
local orig = Mock.track_named("b")
local copy = Mock.duplicate_track(orig)
copy.name = "b copy"
local items_orig = #orig.items
Mock.touch(); app:sync_now(); settle()
T.ok(copy.name == "b copy" and not copy.deleted, "the copy still exists")
T.eq(copy.ext.PS_ROLE, "", "... but is released (not managed)")
T.eq(#copy.items, items_orig, "... with its items")
T.eq(copy.items[1].ext.PS_KEY, "", "... whose tags are gone")
T.eq(copy.depth, 0, "... and it does not open/close folders")
T.eq(#orig.items, items_orig, "the original is untouched")
_, bal = Mock.structure(); T.eq(bal, 0, "balanced with a released copy")
-- released items are not in the override scan and not in freeze&clean
app:freeze_clean()
T.ok(#copy.items == items_orig, "freeze & clean does not touch released copies")

------------------------------------------------------------------ detach
app:go_live(); settle()
local before_tracks = #S.tracks
local st_ = app:detach()
T.eq(app:live(), false, "detach freezes")
T.eq(count_managed(), 0, "no managed tracks left")
local tagged = 0
for _, t in ipairs(S.tracks) do for _, it in ipairs(t.items) do if it.ext.PS_KEY and it.ext.PS_KEY ~= "" then tagged = tagged + 1 end end end
T.eq(tagged, 0, "no tagged items left")
T.eq(#S.tracks, before_tracks, "tracks kept")
_, bal = Mock.structure(); T.eq(bal, 0, "folder structure kept")
settle()
T.eq(#S.tracks, before_tracks, "frozen: nothing happens")
app:go_live(); settle()
T.ok(#S.tracks > before_tracks, "going live again builds a NEW PROTO next to the detached one")
local n_proto = 0; for _, t in ipairs(S.tracks) do if t.ext.PS_ROLE == "root" then n_proto = n_proto + 1 end end
T.eq(n_proto, 1, "one managed root")

------------------------------------------------------------------ fade setting
S.filelen["/snd/bells/a.wav"] = 4.0; S.filelen["/snd/bells/b.wav"] = 4.0
local rg = Mock.add_marker("bells", 100, 101)
require("ProtoReaper").clear_len_cache(); settle()
local function region_item() for _, t in ipairs(S.tracks) do for _, it in ipairs(t.items) do if it.ext.PS_KEY and it.ext.PS_KEY:match("^r") then return it end end end end
local ri = region_item()
T.eq(ri.p.D_FADEOUTLEN, 0.05, "default fade-out on a trimmed item")
app:set_fade(200); settle()
T.eq(ri.p.D_FADEOUTLEN, 0.2, "changing the fade updates trimmed items")
T.eq(S.projext["PrototypeSequence/fade"], "0.2", "fade stored in the project")
app:set_fade(5000); settle()
T.eq(ri.p.D_FADEOUTLEN, 1, "fade never longer than the item")

------------------------------------------------------------------ UI
local ui = UI.new(app)
tick()
T.eq(ui:frame(), true, "frame ok"); T.ok(app.err == nil, "no UI error: " .. tostring(app.err))
local joined = table.concat(st.texts, "|")
T.ok(joined:find("Default for new projects", 1, true), "default folder row shown")
T.ok(joined:find("Managed:", 1, true), "managed info shown")
st.clicks["Detach..."] = true; ui:frame()
T.eq(ui.confirm_detach, true, "detach asks first")
st.clicks["Yes, detach"] = true; ui:frame()
T.eq(count_managed(), 0, "detach via UI")
st.seed_value = nil
T.done("test_v016")
