package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Core = require("ProtoCore")

T.eq(Core.hash32("abc"), Core.hash32("abc"), "hash deterministic")
T.ok(Core.hash32("abc") ~= Core.hash32("abd"), "hash differs")
T.ok(Core.hash32("x") >= 0 and Core.hash32("x") <= 0xFFFFFFFF, "hash range")
T.ok(Core.is_audio("a.WAV") and Core.is_audio("b.flac") and not Core.is_audio("c.txt") and not Core.is_audio("noext"), "is_audio")
T.eq(Core.norm("  Bells "), "bells", "norm")

local function snd(...) local t = {} for _, f in ipairs({...}) do t[#t+1] = { file = f, name = Core.strip_ext(f), path = "/r/x/" .. f } end return t end
local groups = {
  bells = { name = "bells", sounds = snd("b1.wav", "b2.wav", "b3.wav", "b4.wav", "b5.wav") },
  whistles = { name = "whistles", sounds = snd("w1.wav", "w2.wav") },
  empty = { name = "empty", sounds = {} },
}
local function mk(isrgn, idx, pos, e, name) return { isrgn = isrgn, idx = idx, pos = pos, rgnend = e, name = name } end
local markers = {
  mk(false, 1, 10, nil, "Whistles"), mk(false, 2, 5, nil, "bells"), mk(true, 1, 20, 24, "bells"),
  mk(false, 3, 30, nil, "nope"), mk(false, 4, 31, nil, "empty"), mk(false, 5, 32, nil, ""),
}

local plan = Core.plan(markers, groups, 42)
T.eq(#plan.order, 2, "two groups planned")
T.eq(plan.order[1].id, "bells", "group order = first appearance (bells at 5s)")
T.eq(plan.order[2].id, "whistles", "second group")
T.eq(#plan.order[1].entries, 2, "bells has 2 entries")
T.eq(plan.order[1].entries[1].key, "m2", "entries sorted by position")
T.eq(plan.order[1].entries[2].key, "r1", "region key")
T.eq(plan.order[1].entries[2].len, 4, "region length")
T.ok(plan.order[1].entries[1].len == nil, "marker has no length")
local st = {}
for _, row in ipairs(plan.rows) do st[#st + 1] = row.status end
T.eq(table.concat(st, ","), "ok,ok,ok,nofolder,empty,nofolder", "row statuses in marker order")

-- determinism + seed dependence
local p2 = Core.plan(markers, groups, 42)
for i, e in ipairs(plan.order[1].entries) do T.eq(e.sel, p2.order[1].entries[i].sel, "same seed same pick") end
local diff = 0
for seed = 1, 200 do
  local a = Core.pick(seed, "m2", groups.bells.sounds)
  if a ~= Core.pick(1, "m2", groups.bells.sounds) then diff = diff + 1 end
end
T.ok(diff > 100, "seed changes the pick (" .. diff .. "/200)")

-- distribution roughly uniform
local counts = {}
for k = 1, 2000 do local i = Core.pick(7, "m" .. k, groups.bells.sounds); counts[i] = (counts[i] or 0) + 1 end
for i = 1, 5 do T.ok(counts[i] > 300 and counts[i] < 500, "uniform-ish pick #" .. i .. " = " .. tostring(counts[i])) end

-- pick is independent of the OTHER markers, and stable when an unrelated file is added
local before = Core.pick(9, "m2", groups.bells.sounds)
local more = snd("b1.wav", "b2.wav", "b3.wav", "b4.wav", "b5.wav", "b6.wav")
local after = Core.pick(9, "m2", more)
T.ok(after == before or after == 6, "adding a file only changes picks that switch to the new file")
T.eq(Core.pick(1, "m1", {}), nil, "empty list")

-- signature changes with each input
local cfg = { root = "/r", seed = 1 }
local s0 = Core.signature(markers, cfg, "g")
T.eq(s0, Core.signature(markers, cfg, "g"), "signature stable")
T.ok(s0 ~= Core.signature(markers, { root = "/r", seed = 2 }, "g"), "signature: seed")
T.ok(s0 ~= Core.signature(markers, cfg, "h"), "signature: folder content")
markers[1].pos = 11
T.ok(s0 ~= Core.signature(markers, cfg, "g"), "signature: marker moved")
T.done("test_core")
