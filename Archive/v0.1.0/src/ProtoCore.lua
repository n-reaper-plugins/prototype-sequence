-- ProtoCore.lua
-- Pure Lua (5.3/5.4). NO reaper.* calls in here, so it can be tested offline.
--
-- Everything random is a pure function of (seed, marker number, sound file name):
-- the sound for a marker is the one whose hash(seed:marker:file) is highest
-- ("rendezvous hashing"). Moving/renaming a marker, or adding/removing files in a folder,
-- therefore only changes the picks that are actually affected.

local Core = {}
Core.VERSION = "0.1.0"

local AUDIO = { wav = 1, wave = 1, flac = 1, mp3 = 1, ogg = 1, oga = 1, opus = 1,
                aif = 1, aiff = 1, aifc = 1, m4a = 1, wv = 1, caf = 1 }

function Core.is_audio(file)
  local e = tostring(file):match("%.([^%.]+)$")
  return e ~= nil and AUDIO[e:lower()] ~= nil
end

function Core.strip_ext(file) return (tostring(file):gsub("%.[^%.]+$", "")) end

-- marker name -> folder key (trimmed, case-insensitive)
function Core.norm(s)
  s = tostring(s or "")
  s = s:gsub("^%s+", "")
  s = s:gsub("%s+$", "")
  return s:lower()
end

-- 32-bit FNV-1a + murmur3 finaliser
function Core.hash32(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  h = h ~ (h >> 16); h = (h * 0x85ebca6b) & 0xFFFFFFFF
  h = h ~ (h >> 13); h = (h * 0xc2b2ae35) & 0xFFFFFFFF
  h = h ~ (h >> 16)
  return h
end

-- index (1-based) of the winning sound, or nil when the list is empty
function Core.pick(seed, key, sounds)
  local best, bi = -1, nil
  for i, s in ipairs(sounds) do
    local h = Core.hash32(tostring(seed) .. ":" .. key .. ":" .. s.file:lower())
    if h > best then best, bi = h, i end
  end
  return bi
end

function Core.marker_key(m) return (m.isrgn and "r" or "m") .. m.idx end

-- markers: { {isrgn, idx, pos, rgnend, name}, ... }
-- groups : { [normalised folder name] = { name=, sounds={ {file,name,path}, ... } } }
-- -> rows in marker order: { marker=, status="ok"|"nofolder"|"empty", gid=, group= }
function Core.classify(markers, groups)
  local rows = {}
  for i, m in ipairs(markers) do
    local id = Core.norm(m.name)
    local g = (id ~= "") and groups[id] or nil
    local row = { marker = m, gid = id }
    if not g then row.status = "nofolder"
    elseif #g.sounds == 0 then row.status = "empty"; row.group = g
    else row.status = "ok"; row.group = g end
    rows[i] = row
  end
  return rows
end

local function marker_less(a, b)
  if a.pos ~= b.pos then return a.pos < b.pos end
  if a.isrgn ~= b.isrgn then return not a.isrgn end
  return a.idx < b.idx
end
Core.marker_less = marker_less

-- Builds the wanted layout.
--   order[] : groups in order of their FIRST marker: { id, name, sounds, entries={ {key,marker,pos,len,sel} } }
--   rows[]  : classify() rows, with row.pick = chosen sound for the "ok" ones
function Core.plan(markers, groups, seed)
  local rows = Core.classify(markers, groups)
  local ok = {}
  for _, row in ipairs(rows) do if row.status == "ok" then ok[#ok + 1] = row end end
  table.sort(ok, function(a, b) return marker_less(a.marker, b.marker) end)

  local byid, order = {}, {}
  for _, row in ipairs(ok) do
    local pg = byid[row.gid]
    if not pg then
      pg = { id = row.gid, name = row.group.name, sounds = row.group.sounds, entries = {} }
      byid[row.gid] = pg; order[#order + 1] = pg
    end
    local m = row.marker
    local key = Core.marker_key(m)
    local e = { key = key, marker = m, pos = m.pos }
    if m.isrgn and m.rgnend and m.rgnend - m.pos > 1e-4 then e.len = m.rgnend - m.pos end
    e.sel = Core.pick(seed, key, pg.sounds)
    row.pick = pg.sounds[e.sel]
    pg.entries[#pg.entries + 1] = e
  end
  return { order = order, rows = rows }
end

function Core.groups_sig(groups)
  local ids = {}
  for id in pairs(groups) do ids[#ids + 1] = id end
  table.sort(ids)
  local parts = {}
  for _, id in ipairs(ids) do
    local g = groups[id]
    parts[#parts + 1] = id .. "=" .. g.name
    for _, s in ipairs(g.sounds) do parts[#parts + 1] = s.path end
  end
  return table.concat(parts, "|")
end

-- signature of everything a sync depends on
function Core.signature(markers, cfg, gsig)
  local p = { tostring(cfg.root), tostring(cfg.seed), gsig or "" }
  for _, m in ipairs(markers) do
    p[#p + 1] = string.format("%s%d@%.6f-%.6f:%s", m.isrgn and "r" or "m", m.idx, m.pos, m.rgnend or 0, m.name or "")
  end
  local s = table.concat(p, "\n")
  return string.format("%08x%08x%d", Core.hash32(s), Core.hash32("x" .. s), #s)
end

return Core
