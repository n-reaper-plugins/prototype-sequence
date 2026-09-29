package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")
local S = Mock.install()
local st = Stub.install(reaper)
local Core = require("ProtoCore")
local RA = require("ProtoReaper")
local App = require("ProtoApp")
local UI = require("ProtoUI")

Mock.make_sounds("/snd", { bells = { "a.wav", "b.wav", "c.wav" }, whistles = { "w.wav" } })
for _, f in ipairs({ "a", "b", "c" }) do S.filelen["/snd/bells/" .. f .. ".wav"] = 4.0 end
S.filelen["/snd/whistles/w.wav"] = 1.5

local app = App.new()
app:set_root("/snd")
local function tick() S.clock = S.clock + 1; app:tick() end
local function settle() tick(); tick(); tick() end
local function names() local n = {}; for _, t in ipairs(S.tracks) do n[#n + 1] = t.name end; return table.concat(n, "|") end
local function active(key)
  local list = {}
  for _, t in ipairs(S.tracks) do for _, it in ipairs(t.items) do
    if it.ext.PS_KEY == key and it.p.B_MUTE == 0 then list[#list + 1] = t.name end
  end end
  return list
end
local function item_of(track, key) for _, it in ipairs(Mock.items_of(track)) do if it.ext.PS_KEY == key then return it end end end

------------------------------------------------------------------ overlapping cues -> duplicate tracks
local m1 = Mock.add_marker("bells", 0)
local m2 = Mock.add_marker("bells", 2)      -- 4 s sounds: overlaps the first
local m3 = Mock.add_marker("bells", 10)
settle()
T.eq(names(), "PROTO|bells|a|b|c|a (2)|b (2)|c (2)", "overlap: second set of tracks (voice 2)")
T.eq(#Mock.items_of("a"), 2, "voice 1 carries cues 1 and 3")
T.eq(#Mock.items_of("a (2)"), 1, "voice 2 carries cue 2")
for _, key in ipairs({ "m1", "m2", "m3" }) do T.eq(#active(key), 1, "exactly one active for " .. key) end
local _, bal = Mock.structure(); T.eq(bal, 0, "balanced with voices")
T.eq(Mock.track_named("c (2)").depth, -2, "last duplicate closes group + PROTO")
T.eq(Mock.track_named("c").depth, 0, "voice 1 last track is a plain child")
local rows = app.rows
T.eq(rows[2].voice, 2, "list knows voice 2")
-- items of a cue sit on the tracks of ITS voice only
local on_v2 = 0
for _, n in ipairs({ "a", "b", "c" }) do if item_of(n, "m2") then on_v2 = on_v2 + 1 end end
T.eq(on_v2, 0, "cue 2 has no items on voice-1 tracks")
-- moving cue 2 away removes the duplicate tracks again
m2.pos = 30; Mock.touch(); settle()
T.eq(names(), "PROTO|bells|a|b|c", "no overlap -> duplicates removed")
-- same position twice
local m4 = Mock.add_marker("bells", 10); settle()
T.eq(names(), "PROTO|bells|a|b|c|a (2)|b (2)|c (2)", "two cues at the same position -> voice 2")
Mock.remove_marker(m4); settle()
-- overlapping regions: extent = region length
Mock.remove_marker(m1); Mock.remove_marker(m2); Mock.remove_marker(m3)
local r1 = Mock.add_marker("bells", 0, 2)
local r2 = Mock.add_marker("bells", 1, 3)
local r3 = Mock.add_marker("bells", 3, 5)     -- touches r2's end: no overlap with it, overlaps nothing in voice 1 (ends at 2)
settle()
T.eq(app.rows[1].voice, 1, "R1 voice 1"); T.eq(app.rows[2].voice, 2, "R2 overlaps R1 -> voice 2"); T.eq(app.rows[3].voice, 1, "R3 back on voice 1")
T.eq(item_of("a", "r1").p.D_LENGTH, 2, "region-trimmed length")
for _, key in ipairs({ "r1", "r2", "r3" }) do T.eq(#active(key), 1, "one active " .. key) end
Mock.remove_marker(r1); Mock.remove_marker(r2); Mock.remove_marker(r3); settle()

------------------------------------------------------------------ overrides
local c1 = Mock.add_marker("bells", 0)
local c2 = Mock.add_marker("bells", 20)
local w1 = Mock.add_marker("whistles", 50)
settle()
T.eq(next(app.ov), nil, "a fresh sync has no overrides")
local a_of_c1 = active("m1")[1]
local other = (a_of_c1 == "a") and "b" or "a"
local it_other = item_of(other, "m1")
it_other.p.B_MUTE = 0; Mock.touch(); settle()
T.ok(app.ov.m1 and #app.ov.m1.unmuted == 1 and app.ov.m1.unmuted[1] == other, "unmuting another candidate flags the cue")
T.eq(app.ov.m2, nil, "other cues not flagged")
it_other.p.B_MUTE = 1; Mock.touch(); settle()
T.eq(app.ov.m1, nil, "flag disappears when put back")
local it_pick = item_of(a_of_c1, "m1")
it_pick.p.B_MUTE = 1; Mock.touch(); settle()
T.ok(app.ov.m1 and #app.ov.m1.muted == 1, "muting the picked sound flags the cue")
it_pick.p.B_MUTE = 0; Mock.touch(); settle()
-- moved item
local mv = item_of("c", "m2"); mv.p.D_POSITION = 21.5; Mock.touch(); settle()
T.ok(app.ov.m2 and app.ov.m2.moved[1] == "c", "moving an item flags the cue")
T.eq(mv.p.D_POSITION, 21.5, "the manual move stays")
-- ... unrelated sync keeps it (seed unchanged)
Mock.add_marker("whistles", 70); settle()
T.eq(mv.p.D_POSITION, 21.5, "manual move survives other syncs")
-- reset puts it back
app:reset_cue(app.rows[2]); settle()
T.eq(mv.p.D_POSITION, 20, "Reset restores the position")
T.eq(app.ov.m2, nil, "Reset clears the flag")
-- marker moves -> items follow, no flag
c2.pos = 25; Mock.touch(); settle()
T.eq(mv.p.D_POSITION, 25, "marker move moves the item")
T.eq(next(app.ov), nil, "no flag after a normal move")
-- frozen blocks reset / roll
app:freeze()
app:reset_cue(app.rows[1]); T.ok(app.err and app.err:match("Frozen"), "reset blocked while frozen")
app:reroll_cue(app.rows[1]); T.ok(app.err and app.err:match("Frozen"), "roll blocked while frozen")
app:go_live(); settle()

------------------------------------------------------------------ re-roll one cue
local before = {}
for _, k in ipairs({ "m1", "m2" }) do before[k] = active(k)[1] end
local changed_pick
for _ = 1, 5 do
  app:reroll_cue(app.rows[1]); settle()
  local now = active("m1")
  T.eq(#now, 1, "still exactly one active after roll")
  T.ok(now[1] ~= before.m1, "roll picks a DIFFERENT sound")
  T.eq(active("m2")[1], before.m2, "other cues untouched by roll")
  before.m1 = now[1]
end
T.ok(S.projext["PrototypeSequence/salts"]:match("m1=%d+"), "salt stored in the project: " .. tostring(S.projext["PrototypeSequence/salts"]))
T.eq(app.rows[1].pick.name, active("m1")[1], "list shows the rolled sound")
-- rolling clears a manual unmute of that cue
local x = item_of("c", "m1"); x.p.B_MUTE = 0; Mock.touch(); settle()
app:reroll_cue(app.rows[1]); settle()
T.eq(#active("m1"), 1, "roll re-applies mutes of the whole cue")
-- reload: same picks
local picks = active("m1")[1]
local app2 = App.new()
app2:tick()
T.eq(app2.rows[1].pick.name, picks, "salt survives a reload of the project")
-- single-sound folder
app:reroll_cue(app.rows[3]); T.ok(app.err and app.err:match("Only one sound"), "one-sound folder can't roll")
app.err = nil
-- a new seed still re-rolls everything
local pre = active("m1")[1]
local diffs = 0
for seed = 100, 130 do app:set_seed(seed); settle(); if active("m1")[1] ~= pre then diffs = diffs + 1 end end
T.ok(diffs > 5, "seed still changes rolled cues (" .. diffs .. ")")

------------------------------------------------------------------ marker <-> region
app:set_seed(1); settle()
local c1_row = app.rows[1]
local sound = c1_row.pick.name
local it_before = item_of(sound, "m1")
local prev_items = #Mock.items_of("a") + #Mock.items_of("b") + #Mock.items_of("c")
c1.color = 12345; Mock.touch(); settle()
c1_row = app.rows[1]
app:convert_cue(c1_row)
T.ok(app.err == nil, "convert ok: " .. tostring(app.err))
settle()
local reg
for _, m in ipairs(S.markers) do if m.name == "bells" and m.pos == 0 then reg = m end end
T.ok(reg and reg.isrgn, "marker became a region")
T.eq(reg.rgnend, 4.0, "region as long as the picked sound")
T.eq(reg.color, 12345, "colour kept")
T.eq(reg.idx, 1, "number kept")
T.eq(app.rows[1].pick.name, sound, "same sound after conversion")
T.eq(#active("r1"), 1, "one active for the region key")
T.eq(item_of(sound, "r1"), it_before, "the very same item object (not re-created)")
T.eq(#Mock.items_of("a") + #Mock.items_of("b") + #Mock.items_of("c"), prev_items, "no items lost or duplicated")
T.eq(it_before.p.D_LENGTH, 4.0, "length unchanged (region = sound)")
-- back: region -> marker
app:convert_cue(app.rows[1]); settle()
local back
for _, m in ipairs(S.markers) do if m.name == "bells" and m.pos == 0 then back = m end end
T.ok(back and not back.isrgn, "region became a marker")
T.eq(app.rows[1].pick.name, sound, "same sound after converting back")
T.eq(item_of(sound, "m1"), it_before, "same item again")
-- region -> marker drops a trim
local rr = Mock.add_marker("bells", 100, 101); settle()          -- 1 s region, 4 s sounds -> trimmed
local last = nil
for _, row in ipairs(app.rows) do if row.marker == rr or (row.marker.isrgn and row.marker.pos == 100) then last = row end end
local rname = last.pick.name
local trimmed = item_of(rname, Core.marker_key(last.marker))
T.eq(trimmed.p.D_LENGTH, 1, "region trims the item")
local ridx = last.marker.idx
app:convert_cue(last); settle()
local newm; for _, m in ipairs(S.markers) do if m.pos == 100 then newm = m end end
T.ok(newm and not newm.isrgn, "region at 100 became a marker")
T.eq(item_of(rname, "m" .. newm.idx), trimmed, "same item after region -> marker")
T.eq(trimmed.p.D_LENGTH, 4, "back to natural length without the region")
-- number taken in the other namespace -> new number, same sound
local mk = Mock.add_marker("bells", 200)        -- marker number
local rg2 = Mock.add_marker("bells", 300, 302, mk.idx)   -- region with the SAME number
settle()
local row_m
for _, row in ipairs(app.rows) do if row.marker.pos == 200 then row_m = row end end
local snd_m = row_m.pick.name
app:convert_cue(row_m); settle()
local newreg
for _, m in ipairs(S.markers) do if m.pos == 200 then newreg = m end end
T.ok(newreg.isrgn and newreg.idx ~= mk.idx, "collision -> another number (" .. newreg.idx .. ")")
local row_n
for _, row in ipairs(app.rows) do if row.marker.pos == 200 then row_n = row end end
T.eq(row_n.pick.name, snd_m, "sound kept even though the number changed")
-- non-matching cue can't become a region
local bad = Mock.add_marker("nothing", 400); settle()
local row_bad; for _, row in ipairs(app.rows) do if row.marker.pos == 400 then row_bad = row end end
app:convert_cue(row_bad); T.ok(app.err and app.err:match("matching folder"), "red cue can't become a region")
app.err = nil

------------------------------------------------------------------ follow timeline
S.edit_cursor = 0.5; local i0 = app:current_cue()
T.eq(app.rows[i0].marker.pos, 0, "cursor in first cue")
S.edit_cursor = 10^6; T.eq(app:current_cue(), #app.rows, "after the last cue -> last cue")
S.edit_cursor = -5; T.eq(app:current_cue(), nil, "before the first cue -> none")
S.playing, S.play_pos, S.edit_cursor = true, 60, 0
local ip = app:current_cue(); T.ok(app.rows[ip].marker.pos <= 60 and (app.rows[ip + 1] == nil or app.rows[ip + 1].marker.pos > 60), "playing: uses the play position")
S.playing = false

------------------------------------------------------------------ persistence of frozen + project switch
app:freeze()
local app3 = App.new()
T.eq(app3:live(), false, "frozen state is restored from the project")
T.eq(S.projext["PrototypeSequence/mode"], "frozen", "stored in project ext state")
app:go_live()
S.projext["PrototypeSequence/seed"] = "4242"; S.projext["PrototypeSequence/mode"] = "frozen"
S.proj = "PROJ2"; app:tick()
T.eq(app.cfg.seed, 4242, "switching project tab loads that project's settings")
T.eq(app:live(), false, "... including frozen")

------------------------------------------------------------------ UI
S.proj = "PROJ2"
app.cfg.mode = "live"; app:save()
local ui = UI.new(app)
tick()
T.eq(ui:frame(), true, "frame ok")
T.ok(app.err == nil, "no UI error: " .. tostring(app.err))
local calls = table.concat(st.calls, "|")
T.ok(calls:find("Re-\nscan##scan", 1, true), "square update button drawn")
app.last_sig = "x"
-- (the stub strips everything after the newline of a button label)
st.clicks["Re-"] = true; ui:frame()
T.eq(app.last_sig, nil, "update button forces a re-sync")
st.clicks["Follow timeline"] = true; ui:frame()
T.eq(app.cfg.follow, false, "follow checkbox toggles")
T.eq(S.ext["PrototypeSequence/follow"], "0", "follow preference stored")
app:set_follow(true)
st.clicks["M>R"] = true; local nrows = #app.rows; ui:frame(); tick()
T.ok(app.msg and app.msg:match("%->"), "row button converts: " .. tostring(app.msg))
st.clicks["Roll"] = true; local saltsBefore = Core.encode_salts(app.cfg.salts); ui:frame()
T.ok(Core.encode_salts(app.cfg.salts) ~= saltsBefore, "row Roll button rolls")
T.done("test_v015")
