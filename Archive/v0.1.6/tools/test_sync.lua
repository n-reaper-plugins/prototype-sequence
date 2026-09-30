package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local S = Mock.install()
local Core = require("ProtoCore")
local App = require("ProtoApp")

Mock.make_sounds("/snd", {
  bells = { "bell_a.wav", "bell_b.wav", "bell_c.wav", "readme.txt" },
  whistles = { "whistle_1.wav", "whistle_2.wav" },
  empty = {},
})
S.filelen["/snd/bells/bell_a.wav"] = 5.0
local user = Mock.new_user_track("my drums")
Mock.add_marker("whistles", 8)           -- appears FIRST -> whistles group first
local mb = Mock.add_marker("bells", 10)
local rg = Mock.add_marker("bells", 20, 22)   -- region, sound (5s) is longer for bell_a
Mock.add_marker("nothing", 30)
Mock.add_marker("empty", 31)

local app = App.new()
app:set_root("/snd/")                     -- trailing slash, must be cleaned
T.eq(app.cfg.root, "/snd", "root cleaned")
T.eq(app.ngroups, 3, "3 sub-folders scanned")
T.eq(#app.groups.bells.sounds, 3, "txt ignored")
app.cfg.seed = 5; app:save()

local function tick() S.clock = S.clock + 1; app:tick() end
tick()                                    -- sees the markers, starts debounce
T.eq(#app.rows, 5, "rows listed")
tick()                                    -- debounce expired -> sync
T.ok(app.msg and app.msg:match("^Synced"), "synced: " .. tostring(app.msg) .. tostring(app.err))

local struct, bal = Mock.structure()
T.eq(bal, 0, "folder nesting balanced")
local want = { "my drums", "PROTO", "  whistles", "    whistle_1", "    whistle_2", "  bells", "    bell_a", "    bell_b", "    bell_c" }
T.eq(table.concat(struct, "|"), table.concat(want, "|"), "structure / group order by appearance")
-- the user's track was before PROTO and stays untouched
T.eq(S.tracks[1], user, "user track untouched")
T.eq(user.depth, 0, "user depth untouched")
local proto = Mock.track_named("PROTO")
T.eq(proto.depth, 1, "PROTO opens folder")
T.eq(Mock.track_named("whistles").compact, 2, "group minimised")
T.eq(Mock.track_named("bells").compact, 2, "group minimised 2")
T.eq(Mock.track_named("whistle_2").depth, -1, "last kid of first group closes it")
T.eq(Mock.track_named("bell_c").depth, -2, "last kid of last group closes both")

-- exactly one unmuted item per marker, in the group
local function unmuted(key)
  local n, who = 0, nil
  for _, t in ipairs(S.tracks) do
    for _, it in ipairs(t.items) do
      if it.ext.PS_KEY == key and it.p.B_MUTE == 0 then n = n + 1; who = t.name end
    end
  end
  return n, who
end
local total_items = 0
for _, t in ipairs(S.tracks) do total_items = total_items + #t.items end
T.eq(total_items, 2 + 3 + 3, "items: 1 marker x2 whistles + 2 bells markers x3")
for _, key in ipairs({ "m1", "m2", "r1" }) do
  -- keys are per type; m1 = whistles marker, m2 = bells marker
end
T.eq((unmuted("m1")), 1, "one active whistle")
T.eq((unmuted("m2")), 1, "one active bell (marker)")
T.eq((unmuted("r1")), 1, "one active bell (region)")
T.eq(#Mock.items_of("bell_a") , 2, "each bell track has an item per bells marker")
-- item geometry
local a_items = Mock.items_of("bell_a")
local reg_item; for _, it in ipairs(a_items) do if it.ext.PS_KEY == "r1" then reg_item = it end end
T.eq(reg_item.p.D_POSITION, 20, "region item at region start")
T.eq(reg_item.p.D_LENGTH, 2, "long sound trimmed to region")
T.ok(reg_item.p.D_FADEOUTLEN > 0, "trim gets a fade-out")
local b_reg; for _, it in ipairs(Mock.items_of("bell_b")) do if it.ext.PS_KEY == "r1" then b_reg = it end end
T.eq(b_reg.p.D_LENGTH, 2, "2s sound in 2s region: full length")
local mk_item; for _, it in ipairs(a_items) do if it.ext.PS_KEY == "m2" then mk_item = it end end
T.eq(mk_item.p.D_LENGTH, 5, "marker item keeps natural length")
S.filelen["/snd/bells/bell_b.wav"] = 1.0
-- (short sound in longer region is never stretched - checked below after resync)

-- idempotent
local undo0, count0 = S.undo, S.statecount
tick(); tick()
T.eq(S.statecount, count0, "no project change when nothing changed")
app:sync_now(); tick()
T.eq(app.last_stats.items_new + app.last_stats.items_upd + app.last_stats.items_del + app.last_stats.tracks_new, 0, "sync_now is a no-op when in sync")

-- pick is stable when a marker moves
local _, who_before = unmuted("m2")
mb.pos = 12; Mock.touch()
tick(); tick()
local _, who_after = unmuted("m2")
T.eq(who_after, who_before, "moving a marker keeps its sound")
T.eq(Mock.items_of("bell_c")[1].p.D_POSITION == 12 or Mock.items_of("bell_c")[2].p.D_POSITION == 12, true, "item moved with marker")

-- debounce: continuous dragging does not sync until it settles
local cnt = S.statecount
for i = 1, 5 do mb.pos = 13 + i * 0.1; Mock.touch(); S.clock = S.clock + 0.1; app:tick() end
T.eq(S.statecount, cnt + 5, "no sync while dragging (only the 5 touches)")
tick()
T.ok(S.statecount > cnt + 5, "syncs after it settles")

-- rename marker to another group -> items move to whistles tracks, bells items for it disappear
mb.name = "whistles"; Mock.touch(); tick(); tick()
T.eq(#Mock.items_of("bell_a"), 1, "bells tracks lost the renamed marker's items")
T.eq(#Mock.items_of("whistle_1"), 2, "whistle track gained it")
T.eq((unmuted("m2")), 1, "still exactly one active")
mb.name = "bells"; Mock.touch(); tick(); tick()
T.eq(#Mock.items_of("bell_a"), 2, "renamed back")

-- seed change: picks change for some, mute state follows, one active each
local picks1 = {}
for _, k in ipairs({ "m1", "m2", "r1" }) do local _, w = unmuted(k); picks1[k] = w end
local changed = false
for seed = 6, 60 do
  app:set_seed(seed); tick(); tick()
  for _, k in ipairs({ "m1", "m2", "r1" }) do
    local n, w = unmuted(k); T.eq(n, 1, "one active after seed " .. seed)
    if w ~= picks1[k] then changed = true end
  end
end
T.ok(changed, "seed changes picks")
app:set_seed(5); tick(); tick()
for _, k in ipairs({ "m1", "m2", "r1" }) do local _, w = unmuted(k); T.eq(w, picks1[k], "back to seed 5 = same picks " .. k) end

-- manual mute edits survive a resync that does not change the choice
local other; for _, it in ipairs(Mock.items_of("bell_c")) do if it.ext.PS_KEY == "r1" then other = it end end
other.p.B_MUTE = 0; Mock.touch()
mb.pos = 15; Mock.touch(); tick(); tick()
T.eq(other.p.B_MUTE, 0, "manual unmute kept")
other.p.B_MUTE = 1  -- restore for the next checks
local _, wchk = unmuted("r1")

-- short sound, long region: never stretched
require("ProtoReaper").clear_len_cache()          -- (what a folder rescan does: the file on disk changed)
rg.rgnend = 30; Mock.touch(); tick(); tick()
local bshort; for _, it in ipairs(Mock.items_of("bell_b")) do if it.ext.PS_KEY == "r1" then bshort = it end end
T.eq(bshort.p.D_LENGTH, 1, "short sound not stretched (1s file, 10s region)")
local ashort; for _, it in ipairs(Mock.items_of("bell_a")) do if it.ext.PS_KEY == "r1" then ashort = it end end
T.eq(ashort.p.D_LENGTH, 5, "5s file in 10s region: natural length")

-- delete a marker: its items go, and an empty group disappears
local wm; for _, m in ipairs(S.markers) do if m.name == "whistles" and m ~= mb then wm = m end end
Mock.remove_marker(wm); tick(); tick()
T.eq(Mock.track_named("whistles"), nil, "group with no markers removed")
T.eq(Mock.track_named("whistle_1"), nil, "its sound tracks removed")
struct, bal = Mock.structure()
T.eq(bal, 0, "balanced after group removal")
T.eq(table.concat(struct, "|"), "my drums|PROTO|  bells|    bell_a|    bell_b|    bell_c", "structure after removal")
T.eq(Mock.track_named("bell_c").depth, -2, "closing depth moved")

-- foreign content on an obsolete track is preserved and released
local it = reaper.AddMediaItemToTrack(Mock.track_named("bell_c")); it.p.D_LENGTH = 1   -- user item, no tag
S.markers = {}; Mock.touch()
Mock.add_marker("bells", 1)
tick(); tick()
T.ok(#Mock.items_of("bell_c") >= 1, "user's own item kept")

-- FREEZE: nothing is touched any more
app:freeze()
local c1 = S.statecount
Mock.add_marker("bells", 50); tick(); tick(); tick()
T.eq(S.statecount, c1 + 1, "frozen: markers change, project untouched")
T.eq(#app.rows, 2, "frozen: list still follows markers")
-- sync once
app:sync_now(); tick()
T.ok(S.statecount > c1 + 1, "sync once works while frozen")
app:go_live(); tick(); tick()
T.eq(app:live(), true, "back to live")

-- FREEZE & CLEAN: only active items stay
app:freeze_clean()
T.eq(app:live(), false, "clean freezes")
local left = 0
for _, t in ipairs(S.tracks) do for _, i2 in ipairs(t.items) do if i2.ext.PS_KEY then left = left + 1; T.eq(i2.p.B_MUTE, 0, "only unmuted left") end end end
T.eq(left, 2, "one item per bells marker remains (2 markers)")
struct, bal = Mock.structure()
T.eq(bal, 0, "balanced after clean")
local names = {}
for _, t in ipairs(S.tracks) do names[#names + 1] = t.name end
T.eq(#names <= 6 and #names >= 4, true, "empty sound tracks removed: " .. table.concat(names, ","))
T.eq(Mock.track_named("bells").depth, 1, "group still a folder")
T.eq(S.tracks[#S.tracks].depth, -2, "last track closes group + PROTO")
T.eq(app.last_sig, nil, "clean forgets the sync signature")

-- bad file
S.badfiles["/snd/whistles/whistle_2.wav"] = true
app:go_live(); Mock.add_marker("whistles", 60); tick(); tick()
T.ok(app.err and app.err:match("could not be loaded"), "unloadable file reported: " .. tostring(app.err))
T.done("test_sync")
