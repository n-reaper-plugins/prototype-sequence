-- @description PrototypeSequence: random sound sequences on one PROTO folder track, driven by markers & regions
-- @author _n_plugins
-- @version 0.1.6
-- @about
--   Run this action to open the PrototypeSequence window (needs ReaImGui: ReaPack > ReaTeam Extensions;
--   a folder dialog additionally needs js_ReaScriptAPI, otherwise a file dialog / drag&drop / typing is used).
--   Choose a sounds root folder with one sub-folder per sound group (root/bells, root/whistles).
--   Every marker or region NAMED like a sub-folder gets that group: one track per sound, all items placed,
--   one picked by the seed (from seed + marker number + file name) and the others muted.
--   Run the action again while the window is open to close it.
-- BUNDLED BUILD of PrototypeSequence v0.1.6 - edit the files in src/, not this one.
local __preload = package.preload
__preload["ProtoCore"] = function(...)
-- ProtoCore.lua
-- Pure Lua (5.3/5.4). NO reaper.* calls in here, so it can be tested offline.
--
-- Everything random is a pure function of (seed, marker number, sound file name):
-- the sound for a marker is the one whose hash(seed:marker:file) is highest
-- ("rendezvous hashing"). Moving/renaming a marker, or adding/removing files in a folder,
-- therefore only changes the picks that are actually affected.

local Core = {}
Core.VERSION = "0.1.6"

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

-- index (1-based) of the winning sound, or nil when the list is empty.
-- `num` is the marker/region NUMBER (type-less, so converting a marker to a region and back keeps the sound),
-- `salt` is the per-cue re-roll counter (0 = none).
function Core.pick(seed, num, sounds, salt)
  local base = tostring(seed) .. ":" .. tostring(num) .. ((salt and salt > 0) and (":s" .. salt) or "") .. ":"
  local best, bi = -1, nil
  for i, s in ipairs(sounds) do
    local h = Core.hash32(base .. s.file:lower())
    if h > best then best, bi = h, i end
  end
  return bi
end

-- smallest salt >= 0 that makes `file` win for this cue number (used to keep a sound when a cue gets a new number)
function Core.salt_for(seed, num, sounds, file)
  for salt = 0, 5000 do
    local i = Core.pick(seed, num, sounds, salt)
    if i and sounds[i].file == file then return salt end
  end
end

-- salts: { ["m2"] = 3, ["r1"] = 1 }  <->  "m2=3;r1=1"
function Core.encode_salts(t)
  local keys = {}
  for k, v in pairs(t or {}) do if v and v > 0 then keys[#keys + 1] = k end end
  table.sort(keys)
  for i, k in ipairs(keys) do keys[i] = k .. "=" .. t[k] end
  return table.concat(keys, ";")
end
function Core.decode_salts(str)
  local t = {}
  for k, v in tostring(str or ""):gmatch("([mr]%d+)=(%d+)") do t[k] = tonumber(v) end
  return t
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
--   order[] : groups in order of their FIRST marker:
--             { id, name, sounds, voices, entries={ {key,marker,pos,len,sel,salt,voice} } }
--   rows[]  : classify() rows in timeline order; "ok" rows also have .pick (sound), .voice
-- opts.salts : { [key]=n } per-cue re-roll counters
-- opts.lenfn : function(path) -> seconds|nil. With it, cues of one group that overlap in time get separate
--              "voices" (= duplicate sets of sound tracks). A cue's extent is the length of its picked sound
--              (trimmed to the region for regions).
function Core.plan(markers, groups, seed, opts)
  opts = opts or {}
  local salts = opts.salts or {}
  local rows = Core.classify(markers, groups)
  table.sort(rows, function(a, b) return marker_less(a.marker, b.marker) end)
  local ok = {}
  for _, row in ipairs(rows) do if row.status == "ok" then ok[#ok + 1] = row end end

  local byid, order = {}, {}
  for _, row in ipairs(ok) do
    local pg = byid[row.gid]
    if not pg then
      pg = { id = row.gid, name = row.group.name, sounds = row.group.sounds, entries = {}, vend = {} }
      byid[row.gid] = pg; order[#order + 1] = pg
    end
    local m = row.marker
    local key = Core.marker_key(m)
    local e = { key = key, marker = m, pos = m.pos, salt = salts[key] or 0 }
    if m.isrgn and m.rgnend and m.rgnend - m.pos > 1e-4 then e.len = m.rgnend - m.pos end
    e.sel = Core.pick(seed, m.idx, pg.sounds, e.salt)
    row.pick = pg.sounds[e.sel]

    -- voice: first set of tracks whose last cue has ended
    local ext = opts.lenfn and opts.lenfn(row.pick.path) or nil
    if e.len and (not ext or e.len < ext) then ext = e.len end
    ext = ext or 0
    local v = 1
    while pg.vend[v] and pg.vend[v] > m.pos + 1e-6 do v = v + 1 end
    pg.vend[v] = m.pos + ext
    e.voice, row.voice = v, v
    pg.entries[#pg.entries + 1] = e
  end
  for _, pg in ipairs(order) do pg.voices = #pg.vend; pg.vend = nil end
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
  local p = { tostring(cfg.root), tostring(cfg.seed), gsig or "", Core.encode_salts(cfg.salts), tostring(cfg.fade) }
  for _, m in ipairs(markers) do
    p[#p + 1] = string.format("%s%d@%.6f-%.6f:%s", m.isrgn and "r" or "m", m.idx, m.pos, m.rgnend or 0, m.name or "")
  end
  local s = table.concat(p, "\n")
  return string.format("%08x%08x%d", Core.hash32(s), Core.hash32("x" .. s), #s)
end

return Core

end
__preload["ProtoReaper"] = function(...)
-- ProtoReaper.lua
-- Everything that touches REAPER: folder scan, marker reading, track/item sync, freeze & clean.
-- Managed objects carry P_EXT tags so the script only ever touches what it created:
--   tracks: PS_ROLE = root|group|snd, PS_ID = (group: normalised folder name | snd: file path)
--   items : PS_KEY  = m<n>|r<n> (marker / region number)
--            PS_SEL  = "<seed>:<salt>:<1|0>"  last applied choice (1 = picked/unmuted)
--            PS_POS / PS_LEN / PS_FADE = position / length / fade we last applied.
--   Track NAMES are only written when a track is created: renaming any managed track is safe (identity = tags).
--   A value is only re-applied when the WANTED value changed, so manual edits (unmute, move, trim) survive until then;
--   RA.detect_overrides() reads the difference between the tags and the item to flag those cues.

local r = reaper
local Core = require("ProtoCore")

local RA = {}
local SECTION = "PrototypeSequence"
local E_ROLE, E_ID, E_KEY, E_SEL = "P_EXT:PS_ROLE", "P_EXT:PS_ID", "P_EXT:PS_KEY", "P_EXT:PS_SEL"
local E_POS, E_LEN, E_FADE = "P_EXT:PS_POS", "P_EXT:PS_LEN", "P_EXT:PS_FADE"
local EPS = 1e-7

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------
local function tget(tr, k) local ok, v = r.GetSetMediaTrackInfo_String(tr, k, "", false); return ok and v or "" end
local function tset(tr, k, v) r.GetSetMediaTrackInfo_String(tr, k, v, true) end
local function iget(it, k) local ok, v = r.GetSetMediaItemInfo_String(it, k, "", false); return ok and v or "" end
local function iset(it, k, v) r.GetSetMediaItemInfo_String(it, k, v, true) end
local function tidx0(tr) return math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") + 0.5) - 1 end

local function set_track_val(tr, k, v)
  if r.GetMediaTrackInfo_Value(tr, k) ~= v then r.SetMediaTrackInfo_Value(tr, k, v) end
end

local function set_name(tr, name)
  local ok, cur = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if not ok or cur ~= name then r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true) end
end

local function new_track(role, id, name)
  local idx = r.CountTracks(0)
  r.InsertTrackAtIndex(idx, false)
  local tr = r.GetTrack(0, idx)
  tset(tr, E_ROLE, role); tset(tr, E_ID, id)
  set_name(tr, name)
  return tr
end

--------------------------------------------------------------------------------
-- settings
--   PROJECT (saved in the .rpp): root, seed, mode, fade, salts, sig
--   GLOBAL  (REAPER's reaper-extstate.ini): default_root (folder new projects start with), follow (UI pref)
-- Values are only written when they differ from what is stored, so opening the window or toggling a
-- UI option does not mark the project as modified.
--------------------------------------------------------------------------------
local written = {}                                -- what the project currently holds, per key

local function pset(k, v)
  v = v or ""
  if written[k] ~= v then r.SetProjExtState(0, SECTION, k, v); written[k] = v end
end
local function gset(k, v)
  if r.GetExtState(SECTION, k) ~= v then r.SetExtState(SECTION, k, v, true) end
end

function RA.load_cfg()
  written = {}
  local function pget(k) local _, v = r.GetProjExtState(0, SECTION, k); written[k] = v; return v end
  local cfg = { root = pget("root"), seed = tonumber(pget("seed")), mode = pget("mode"), fade = tonumber(pget("fade")),
                salts = Core.decode_salts(pget("salts")) }
  cfg.follow = (r.GetExtState(SECTION, "follow") ~= "0")
  cfg.default_root = r.GetExtState(SECTION, "default_root")
  if cfg.default_root == "" then cfg.default_root = r.GetExtState(SECTION, "root") end   -- 0.1.x used this key
  -- a project without a folder starts with the default one (and keeps it once it has been used)
  cfg.inherited = false
  if cfg.root == "" and cfg.default_root ~= "" then cfg.root = cfg.default_root; cfg.inherited = true end
  cfg.seed = cfg.seed or 1
  cfg.mode = (cfg.mode == "frozen") and "frozen" or "live"
  cfg.fade = cfg.fade or 0.05
  return cfg
end

function RA.save_cfg(cfg)
  if not cfg.inherited then pset("root", cfg.root) end       -- an inherited folder is not written until it is used
  pset("seed", tostring(cfg.seed))
  pset("mode", cfg.mode)
  pset("fade", tostring(cfg.fade))
  pset("salts", Core.encode_salts(cfg.salts))
  RA.save_prefs(cfg)
end

function RA.save_prefs(cfg)
  gset("follow", cfg.follow and "1" or "0")
  if cfg.default_root and cfg.default_root ~= "" then gset("default_root", cfg.default_root) end
end

function RA.load_sig() local _, v = r.GetProjExtState(0, SECTION, "sig"); written.sig = v; return v ~= "" and v or nil end
function RA.save_sig(s) pset("sig", s or "") end

--------------------------------------------------------------------------------
-- folders
--------------------------------------------------------------------------------
function RA.clean_path(p)
  p = tostring(p or ""):gsub("^%s+", ""):gsub("%s+$", "")
  p = p:gsub('^"(.*)"$', "%1")
  if #p > 1 then p = p:gsub("[/\\]+$", "") end
  return p
end

local function is_dir(p)
  if r.EnumerateSubdirectories(p, 0) or r.EnumerateFiles(p, 0) then return true end
  if r.file_exists and r.file_exists(p) then return false end
  return not Core.is_audio(p)       -- empty folder vs. unknown file
end

-- a dropped/picked path may be a file: use its folder then
function RA.resolve_root(p)
  p = RA.clean_path(p)
  if p == "" then return "" end
  if is_dir(p) then return p end
  return (p:gsub("[/\\][^/\\]*$", ""))
end

-- root/<group>/<sounds>. One level only.
function RA.scan(root)
  local groups, n = {}, 0
  if not root or root == "" then return groups, 0 end
  r.EnumerateSubdirectories(root, -1)                    -- -1 = drop REAPER's directory cache
  local i = 0
  while true do
    local d = r.EnumerateSubdirectories(root, i)
    if not d then break end
    i = i + 1
    if d:sub(1, 1) ~= "." then
      local id = Core.norm(d)
      if id ~= "" and not groups[id] then
        local path = root .. "/" .. d
        r.EnumerateFiles(path, -1)
        local sounds, j = {}, 0
        while true do
          local f = r.EnumerateFiles(path, j)
          if not f then break end
          j = j + 1
          if Core.is_audio(f) and f:sub(1, 1) ~= "." then
            sounds[#sounds + 1] = { file = f, name = Core.strip_ext(f), path = path .. "/" .. f }
          end
        end
        table.sort(sounds, function(a, b) return a.file:lower() < b.file:lower() end)
        groups[id] = { name = d, sounds = sounds, path = path }
        n = n + 1
      end
    end
  end
  return groups, n
end

--------------------------------------------------------------------------------
-- markers / regions (EnumProjectMarkers3 returns those of ALL ruler lanes)
--------------------------------------------------------------------------------
function RA.read_markers()
  local out, i = {}, 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx, color = r.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    out[#out + 1] = { isrgn = isrgn and true or false, pos = pos, rgnend = isrgn and rgnend or nil,
                      name = name or "", idx = idx, color = color }
    i = i + 1
  end
  table.sort(out, Core.marker_less)
  return out
end

-- length (seconds) of a sound file, cached until RA.clear_len_cache() (folder rescan)
local len_cache = {}
function RA.clear_len_cache() len_cache = {} end
function RA.file_len(path)
  local v = len_cache[path]
  if v == nil then
    v = false
    local src = r.PCM_Source_CreateFromFile(path)
    if src then
      local len, is_qn = r.GetMediaSourceLength(src)
      if len and not is_qn and len > 0 then v = len end
      if r.PCM_Source_Destroy then r.PCM_Source_Destroy(src) end
    end
    len_cache[path] = v
  end
  return v or nil
end

--------------------------------------------------------------------------------
-- track bookkeeping
--------------------------------------------------------------------------------
-- managed tracks in project order + lookups by id (first one wins, later ones are "extra")
function RA.index_tracks()
  local ex = { list = {}, groups = {}, snds = {} }
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local role = tget(tr, E_ROLE)
    if role ~= "" then
      local id = tget(tr, E_ID)
      ex.list[#ex.list + 1] = { tr = tr, role = role, id = id }
      local rec = ex.list[#ex.list]
      if role == "root" then
        if ex.root then rec.dup = true else ex.root = tr end
      elseif role == "group" then
        if ex.groups[id] then rec.dup = true else ex.groups[id] = tr end
      elseif role == "snd" then
        if ex.snds[id] then rec.dup = true else ex.snds[id] = tr end
      end
    end
  end
  return ex
end

-- items of a managed track: tagged items by key, plus a count of items we did not create
local function track_items(tr)
  local m, dups, foreign = {}, {}, 0
  for i = 0, r.CountTrackMediaItems(tr) - 1 do
    local it = r.GetTrackMediaItem(tr, i)
    local key = iget(it, E_KEY)
    if key == "" then foreign = foreign + 1
    elseif m[key] then dups[#dups + 1] = it
    else m[key] = it end
  end
  return m, dups, foreign
end

local function save_selection()
  local s = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do s[r.GetSelectedTrack(0, i)] = true end
  return s
end
local function restore_selection(s)
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    r.SetTrackSelected(tr, s[tr] == true)
  end
end

-- Puts the wanted tracks directly under each other, starting at the root track.
local function order_tracks(D)
  for _ = 1, 4 do
    local moved = false
    for i = 2, #D do
      local want = tidx0(D[1]) + i - 1
      local cur = tidx0(D[i])
      if cur ~= want then
        r.SetOnlyTrackSelected(D[i])
        r.ReorderSelectedTracks((cur > want) and want or (want + 1), 0)
        moved = true
      end
    end
    if not moved then break end
  end
end

-- layout = { {track=, kids={tracks}}, ... }
function RA.apply_depths(root, layout)
  if #layout == 0 then set_track_val(root, "I_FOLDERDEPTH", 0); return end
  set_track_val(root, "I_FOLDERDEPTH", 1)
  for gi, L in ipairs(layout) do
    set_track_val(L.track, "I_FOLDERDEPTH", 1)
    set_track_val(L.track, "I_FOLDERCOMPACT", 2)         -- collapsed / minimised
    for ki, kt in ipairs(L.kids) do
      local d = 0
      if ki == #L.kids then d = (gi == #layout) and -2 or -1 end
      set_track_val(kt, "I_FOLDERDEPTH", d)
    end
  end
end

-- hand a track (and its items) back to the user: no tags, plain track
local function release_track(tr)
  for i = 0, r.CountTrackMediaItems(tr) - 1 do
    local it = r.GetTrackMediaItem(tr, i)
    for _, k in ipairs({ E_KEY, E_SEL, E_POS, E_LEN, E_FADE }) do
      if iget(it, k) ~= "" then iset(it, k, "") end
    end
  end
  tset(tr, E_ROLE, ""); tset(tr, E_ID, "")
  set_track_val(tr, "I_FOLDERDEPTH", 0)
end

local function with_undo(label, fn)
  local sel = save_selection()
  r.PreventUIRefresh(1)
  r.Undo_BeginBlock2(0)
  local ok, res = pcall(fn)
  restore_selection(sel)
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.Undo_EndBlock2(0, label, -1)
  if not ok then return nil, res end
  return res
end

--------------------------------------------------------------------------------
-- SYNC: make the PROTO tracks/items match markers + folders + seed
--------------------------------------------------------------------------------
local function fmt(v) return string.format("%.6f", v) end
local function voice_id(path, v) return v == 1 and path or (path .. "#" .. v) end
local function voice_name(name, v) return v == 1 and name or (name .. " (" .. v .. ")") end

-- app = { cfg={root,seed,fade,salts}, groups=, markers= }
function RA.sync(app)
  local cfg = app.cfg
  local plan = Core.plan(app.markers or RA.read_markers(), app.groups, cfg.seed,
    { salts = cfg.salts, lenfn = RA.file_len })
  local st = { tracks_new = 0, tracks_del = 0, items_new = 0, items_upd = 0, items_del = 0, bad = {} }

  local res, err = with_undo("PrototypeSequence: sync", function()
    local ex = RA.index_tracks()
    local root = ex.root
    if not root then root = new_track("root", "PROTO", "PROTO"); st.tracks_new = st.tracks_new + 1 end

    -- 1. wanted tracks: group folder, then one set of sound tracks per voice --------------
    local D, layout, want_tr = { root }, {}, { [root] = true }
    for _, pg in ipairs(plan.order) do
      local gt = ex.groups[pg.id]
      if not gt then gt = new_track("group", pg.id, pg.name); st.tracks_new = st.tracks_new + 1 end
      want_tr[gt] = true; D[#D + 1] = gt
      local L = { track = gt, kids = {} }
      pg.tracks = {}
      for v = 1, pg.voices do
        pg.tracks[v] = {}
        for k, s in ipairs(pg.sounds) do
          local id = voice_id(s.path, v)
          local tr = ex.snds[id]
          if not tr then tr = new_track("snd", id, voice_name(s.name, v)); st.tracks_new = st.tracks_new + 1 end
          want_tr[tr] = true; D[#D + 1] = tr; L.kids[#L.kids + 1] = tr; pg.tracks[v][k] = tr
        end
      end
      layout[#layout + 1] = L
    end

    -- 2. items ----------------------------------------------------------------
    local wanted, have_of = {}, {}
    local function have(tr)
      local h = have_of[tr]
      if not h then
        local dups
        h, dups = track_items(tr)
        for _, it in ipairs(dups) do r.DeleteTrackMediaItem(tr, it); st.items_del = st.items_del + 1 end
        have_of[tr] = h
      end
      return h
    end
    for _, pg in ipairs(plan.order) do
      for _, e in ipairs(pg.entries) do
        for k, s in ipairs(pg.sounds) do
          local tr = pg.tracks[e.voice][k]
          wanted[tr] = wanted[tr] or {}
          local it = have(tr)[e.key]
          local fresh = false
          if not it then
            local src = r.PCM_Source_CreateFromFile(s.path)
            if not src then
              st.bad[s.path] = true
            else
              it = r.AddMediaItemToTrack(tr)
              local take = r.AddTakeToMediaItem(it)
              r.SetMediaItemTake_Source(take, src)
              r.GetSetMediaItemTakeInfo_String(take, "P_NAME", s.name, true)
              iset(it, E_KEY, e.key)
              st.items_new = st.items_new + 1
              fresh = true
            end
          end
          if it then
            wanted[tr][e.key] = true
            local changed = false
            -- position: only when the WANTED position changed (a manual move stays until the marker moves)
            if iget(it, E_POS) ~= fmt(e.pos) then
              r.SetMediaItemInfo_Value(it, "D_POSITION", e.pos); iset(it, E_POS, fmt(e.pos)); changed = true
            end
            -- length: natural length, trimmed to the region, never stretched
            local slen = RA.file_len(s.path)
            if slen then
              local len = slen
              if e.len and e.len < slen then len = e.len end
              if iget(it, E_LEN) ~= fmt(len) then
                r.SetMediaItemInfo_Value(it, "D_LENGTH", len)
                iset(it, E_LEN, fmt(len)); iset(it, E_FADE, ""); changed = true
              end
              -- fade-out of trimmed items: when the setting or the trim changed
              if len < slen - EPS and (cfg.fade or 0) > 0 and iget(it, E_FADE) ~= fmt(cfg.fade) then
                r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", math.min(cfg.fade, len))
                iset(it, E_FADE, fmt(cfg.fade)); changed = true
              end
            end
            -- mute: only when seed / re-roll changed (a manual unmute stays until then)
            local is_sel = (k == e.sel)
            local tag = tostring(cfg.seed) .. ":" .. e.salt .. ":" .. (is_sel and "1" or "0")
            if iget(it, E_SEL) ~= tag then
              r.SetMediaItemInfo_Value(it, "B_MUTE", is_sel and 0 or 1)
              iset(it, E_SEL, tag); changed = true
            end
            if changed and not fresh then st.items_upd = st.items_upd + 1 end
          end
        end
      end
    end

    -- 3. stale items on all managed tracks, obsolete tracks ------------------------
    for _, rec in ipairs(ex.list) do
      local tr = rec.tr
      if rec.dup then
        release_track(tr)                              -- a copy of a managed track: keep it, just not managed
        st.released = (st.released or 0) + 1
      elseif rec.role == "snd" then
        local h, dups = track_items(tr)
        local w = wanted[tr] or {}
        for key, it in pairs(h) do
          if not w[key] then r.DeleteTrackMediaItem(tr, it); st.items_del = st.items_del + 1 end
        end
        if not want_tr[tr] then
          for _, it in ipairs(dups) do r.DeleteTrackMediaItem(tr, it) end
        end
      end
      if not rec.dup and not want_tr[tr] then
        if r.CountTrackMediaItems(tr) == 0 and rec.role ~= "root" then
          r.DeleteTrack(tr); st.tracks_del = st.tracks_del + 1
        else                                             -- has foreign content: hand it back to the user
          tset(tr, E_ROLE, ""); tset(tr, E_ID, "")
          r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", 0)
        end
      end
    end

    -- 4. order + folder structure ----------------------------------------------
    order_tracks(D)
    RA.apply_depths(root, layout)
    return st
  end)
  if not res then return nil, err end
  return st
end

--------------------------------------------------------------------------------
-- OVERRIDES: cues whose items were changed by hand (unmuted / muted / moved)
--------------------------------------------------------------------------------
-- -> { [key] = { unmuted = {track names}, muted = {..}, moved = {..} } }   (only cues with a difference)
function RA.detect_overrides()
  local ov = {}
  local ex = RA.index_tracks()
  for _, rec in ipairs(ex.list) do
    if rec.role == "snd" then
      local tname
      for i = 0, r.CountTrackMediaItems(rec.tr) - 1 do
        local it = r.GetTrackMediaItem(rec.tr, i)
        local key = iget(it, E_KEY)
        if key ~= "" then
          local sel, kind = iget(it, E_SEL), nil
          if sel ~= "" then
            local want_muted = (sel:sub(-1) ~= "1") and 1 or 0
            if r.GetMediaItemInfo_Value(it, "B_MUTE") ~= want_muted then kind = (want_muted == 1) and "unmuted" or "muted" end
          end
          local applied = tonumber(iget(it, E_POS))
          local moved = applied and math.abs(r.GetMediaItemInfo_Value(it, "D_POSITION") - applied) > 1e-3
          if kind or moved then
            if not tname then
              local _, n = r.GetSetMediaTrackInfo_String(rec.tr, "P_NAME", "", false); tname = n or "?"
            end
            local o = ov[key] or { unmuted = {}, muted = {}, moved = {} }
            ov[key] = o
            if kind then o[kind][#o[kind] + 1] = tname end
            if moved then o.moved[#o.moved + 1] = tname end
          end
        end
      end
    end
  end
  return ov
end

-- forget what we applied to this cue's items, so the next sync puts them back as planned
function RA.reset_cue(key)
  local n = 0
  local ex = RA.index_tracks()
  for _, rec in ipairs(ex.list) do
    if rec.role == "snd" then
      for i = 0, r.CountTrackMediaItems(rec.tr) - 1 do
        local it = r.GetTrackMediaItem(rec.tr, i)
        if iget(it, E_KEY) == key then
          iset(it, E_SEL, ""); iset(it, E_POS, ""); iset(it, E_LEN, ""); iset(it, E_FADE, ""); n = n + 1
        end
      end
    end
  end
  return n
end

--------------------------------------------------------------------------------
-- MARKER <-> REGION
--------------------------------------------------------------------------------
-- marker -> region needs `len` (the picked sound's length); region -> marker just drops the length.
-- The new cue keeps the number if it is free in the other namespace. Item tags follow the cue.
-- returns { idx=, key= } or nil, err
function RA.convert_cue(m, len)
  return with_undo("PrototypeSequence: convert " .. (m.isrgn and "region to marker" or "marker to region"), function()
    local newidx
    if m.isrgn then newidx = r.AddProjectMarker2(0, false, m.pos, 0, m.name, m.idx, m.color or 0)
    else newidx = r.AddProjectMarker2(0, true, m.pos, m.pos + len, m.name, m.idx, m.color or 0) end
    if not newidx or newidx < 0 then error("REAPER refused to create the " .. (m.isrgn and "marker" or "region")) end
    r.DeleteProjectMarker(0, m.idx, m.isrgn)                 -- only after the new one exists
    local oldkey, newkey = Core.marker_key(m), (m.isrgn and "m" or "r") .. newidx
    local ex = RA.index_tracks()
    for _, rec in ipairs(ex.list) do
      if rec.role == "snd" then
        for i = 0, r.CountTrackMediaItems(rec.tr) - 1 do
          local it = r.GetTrackMediaItem(rec.tr, i)
          if iget(it, E_KEY) == oldkey then iset(it, E_KEY, newkey) end
        end
      end
    end
    return { idx = newidx, key = newkey }
  end)
end

--------------------------------------------------------------------------------
-- INFO / SHOW / DETACH
--------------------------------------------------------------------------------
-- { root_name=, tracks= } of what the script manages (identified by tags, whatever the tracks are called)
function RA.managed_info()
  local ex = RA.index_tracks()
  local info = { tracks = 0 }
  for _, rec in ipairs(ex.list) do
    if not rec.dup then
      if rec.role == "root" then
        local _, n = r.GetSetMediaTrackInfo_String(rec.tr, "P_NAME", "", false); info.root_name = n or ""
      else info.tracks = info.tracks + 1 end
    end
  end
  return info
end

function RA.show_root()
  local ex = RA.index_tracks()
  if not ex.root then return false end
  r.SetOnlyTrackSelected(ex.root)
  r.Main_OnCommand(40913, 0)             -- Track: vertical scroll selected tracks into view
  return true
end

-- Remove every tag: PROTO tracks and items stay as they are but are ordinary tracks/items from now on.
function RA.detach()
  local st = { tracks = 0 }
  local res, err = with_undo("PrototypeSequence: detach", function()
    local ex = RA.index_tracks()
    for _, rec in ipairs(ex.list) do
      local depth = r.GetMediaTrackInfo_Value(rec.tr, "I_FOLDERDEPTH")
      release_track(rec.tr)
      r.SetMediaTrackInfo_Value(rec.tr, "I_FOLDERDEPTH", depth)     -- keep the folder structure
      st.tracks = st.tracks + 1
    end
    return st
  end)
  if not res then return nil, err end
  return st
end

--------------------------------------------------------------------------------
-- FREEZE & CLEAN: keep only the un-muted items; drop empty tracks / folders
--------------------------------------------------------------------------------
function RA.freeze_clean()
  local st = { items_del = 0, tracks_del = 0 }
  local res, err = with_undo("PrototypeSequence: freeze & clean", function()
    local ex = RA.index_tracks()
    if not ex.root then return st end
    for _, rec in ipairs(ex.list) do
      if rec.role == "snd" then
        local have = track_items(rec.tr)
        for _, it in pairs(have) do
          if r.GetMediaItemInfo_Value(it, "B_MUTE") ~= 0 then
            r.DeleteTrackMediaItem(rec.tr, it); st.items_del = st.items_del + 1
          end
        end
        if r.CountTrackMediaItems(rec.tr) == 0 then r.DeleteTrack(rec.tr); st.tracks_del = st.tracks_del + 1 end
      end
    end
    -- rebuild the structure from what is left
    ex = RA.index_tracks()
    local layout, cur = {}, nil
    for _, rec in ipairs(ex.list) do
      if rec.role == "group" then cur = { track = rec.tr, kids = {} }; layout[#layout + 1] = cur
      elseif rec.role == "snd" and cur then cur.kids[#cur.kids + 1] = rec.tr end
    end
    local keep = {}
    for _, L in ipairs(layout) do
      if #L.kids == 0 then r.DeleteTrack(L.track); st.tracks_del = st.tracks_del + 1
      else keep[#keep + 1] = L end
    end
    RA.apply_depths(ex.root, keep)
    return st
  end)
  if not res then return nil, err end
  return st
end

return RA

end
__preload["ProtoApp"] = function(...)
-- ProtoApp.lua
-- State + main tick. No drawing in here. The UI only calls the methods below.
--
--   live   : every change of markers / regions / seed / folder content is synced (after DEBOUNCE seconds)
--   frozen : nothing is touched any more (buttons: Sync once, Go live)

local r = reaper
local Core = require("ProtoCore")
local RA = require("ProtoReaper")

local App = {}
App.__index = App

local DEBOUNCE = 0.35

function App.new()
  local self = setmetatable({}, App)
  self.proj = r.EnumProjects(-1)
  self.cfg = RA.load_cfg()
  self.groups, self.ngroups = {}, 0
  self.ov, self.ov_dirty, self.ov_t = {}, true, -1e9
  self.info = { tracks = 0 }
  self.gsig = ""
  self.markers, self.rows = {}, {}
  self.last_count = -1
  self.last_sig = RA.load_sig()      -- what the project was last synced to (skips the start-up sync if unchanged)
  self.pending_t = nil
  self.force = false
  self.msg, self.err = nil, nil
  self.last_stats = nil
  if self.cfg.root ~= "" then self:rescan() end
  return self
end

function App:save() RA.save_cfg(self.cfg) end

function App:live() return self.cfg.mode == "live" end

--------------------------------------------------------------------------------
-- folder / seed / mode
--------------------------------------------------------------------------------
function App:rescan()
  RA.clear_len_cache()
  self.groups, self.ngroups = RA.scan(self.cfg.root)
  self.gsig = Core.groups_sig(self.groups)
  self.last_count = -1                -- refresh the marker list and the signature
  if self.cfg.root == "" then self.msg = nil
  elseif self.ngroups == 0 then self.err = "No sub-folders found in " .. self.cfg.root; return
  end
  self.err = nil
end

-- the square button: re-read the folder AND make sure PROTO matches it again (also new file lengths)
function App:update_folder()
  self:rescan()
  self.last_sig = nil
  if self.err == nil then self.msg = string.format("Folder re-read: %d groups.", self.ngroups) end
end

function App:set_root(path)
  local p = RA.resolve_root(path)
  if p == "" then return end
  self.cfg.root = p
  self.cfg.inherited = false
  if self.cfg.default_root == "" then self.cfg.default_root = p end     -- the first folder ever chosen becomes the default
  self:rescan()
  self:save()
end

-- "common" folder that new projects start with (each project keeps its own once it has used one)
function App:make_default()
  if self.cfg.root == "" then return end
  self.cfg.default_root = self.cfg.root
  RA.save_prefs(self.cfg)
  self.msg = "Default folder for new projects: " .. self.cfg.root
end

function App:use_default()
  if self.cfg.default_root == "" then return end
  self:set_root(self.cfg.default_root)
end

function App:set_fade(ms)
  ms = math.max(0, math.min(5000, math.floor(tonumber(ms) or 0)))
  if math.abs(ms / 1000 - self.cfg.fade) < 1e-9 then return end
  self.cfg.fade = ms / 1000
  self:save()
  self.last_count = -1
end

function App:set_seed(n)
  n = math.floor(tonumber(n) or 1)
  if n < 0 then n = -n end
  if n == self.cfg.seed then return end
  self.cfg.seed = n
  self:save()
  self.last_count = -1
end

function App:reroll()
  local s
  repeat s = math.random(1, 999999) until s ~= self.cfg.seed
  self:set_seed(s)
end

function App:freeze()
  self.cfg.mode = "frozen"; self.pending_t = nil; self:save()
  self.msg = "Frozen: PROTO is left alone."
end

function App:go_live()
  self.cfg.mode = "live"; self.last_sig = nil; self.last_count = -1; self:save()
  self.msg = nil
end

function App:freeze_clean()
  local st, err = RA.freeze_clean()
  self.cfg.mode = "frozen"; self.pending_t = nil; self:save()
  self.last_sig = nil; RA.save_sig(nil)
  if not st then self.err = tostring(err); return end
  self.err = nil
  self.msg = string.format("Frozen & cleaned: removed %d muted items, %d empty tracks.", st.items_del, st.tracks_del)
end

function App:sync_now() self.force = true end

-- Stop managing PROTO for good: tags removed, tracks and items stay as ordinary ones.
function App:detach()
  local st, err = RA.detach()
  self.cfg.mode = "frozen"; self.pending_t = nil; self.last_sig = nil; RA.save_sig(nil)
  self:save()
  self.ov, self.ov_dirty = {}, true
  if not st then self.err = tostring(err); return end
  self.err = nil
  self.msg = string.format("Detached %d tracks: they are ordinary tracks now. Going live again creates a new PROTO.", st.tracks)
end

function App:show_root() RA.show_root() end

function App:set_follow(on) self.cfg.follow = on and true or false; RA.save_prefs(self.cfg) end

-- the cue the play position (while playing) or the edit cursor (otherwise) is in: the last cue at or before it
function App:current_cue()
  local pos
  if (r.GetPlayState() & 1) ~= 0 then pos = r.GetPlayPosition() else pos = r.GetCursorPosition() end
  local cur
  for i, row in ipairs(self.rows) do
    if row.marker.pos <= pos + 1e-9 then cur = i else break end
  end
  return cur
end

--------------------------------------------------------------------------------
-- per-cue actions (used by the buttons in the list)
--------------------------------------------------------------------------------
-- new random sound for ONE cue. Stored as a per-cue counter ("salt") in the project, so it survives
-- reloading, and a new seed still re-rolls everything (the counter just adds to the hash).
function App:reroll_cue(row)
  if row.status ~= "ok" or not row.pick then return end
  if not self:live() then self.err = "Frozen: go live (or use Sync once) to change picks."; return end
  local sounds, m = row.group.sounds, row.marker
  if #sounds < 2 then self.err = "Only one sound in '" .. row.group.name .. "'."; return end
  local key = Core.marker_key(m)
  local cur = Core.pick(self.cfg.seed, m.idx, sounds, self.cfg.salts[key] or 0)
  local salt = self.cfg.salts[key] or 0
  for s = salt + 1, salt + 500 do
    if Core.pick(self.cfg.seed, m.idx, sounds, s) ~= cur then self.cfg.salts[key] = s; break end
  end
  self.err = nil
  self:save()
  self.last_count = -1
  self.force = true
end

-- put this cue's items back the way the plan wants them (unmute/move overrides are dropped)
function App:reset_cue(row)
  if not self:live() then self.err = "Frozen: go live (or use Sync once) to reset a cue."; return end
  RA.reset_cue(Core.marker_key(row.marker))
  self.err = nil
  self.force = true
  self.ov_dirty = true
end

-- Marker -> Region (length = the picked sound) or Region -> Marker (length dropped); keeps name, colour, sound, items.
function App:convert_cue(row)
  local m = row.marker
  local len
  if not m.isrgn then
    if row.status ~= "ok" or not row.pick then self.err = "Only cues with a matching folder can become regions."; return end
    len = RA.file_len(row.pick.path)
    if not len then self.err = "Could not read the length of " .. row.pick.file; return end
  end
  local oldkey = Core.marker_key(m)
  local res, err = RA.convert_cue(m, len)
  if not res then self.err = "Convert failed: " .. tostring(err); return end
  local salts = self.cfg.salts
  if row.status == "ok" and row.pick then
    -- keep the sound: same number -> nothing to do; new number -> find a salt that yields the same file
    local cur = salts[oldkey] or 0
    if res.idx == m.idx then
      salts[res.key] = (cur > 0) and cur or nil
    else
      local s = Core.salt_for(self.cfg.seed, res.idx, row.group.sounds, row.pick.file)
      salts[res.key] = (s and s > 0) and s or nil
    end
  end
  salts[oldkey] = nil
  self.err = nil
  self.msg = string.format("%s %s%d -> %s%d", m.isrgn and "Region" or "Marker", m.isrgn and "R" or "M", m.idx,
    res.key:sub(1, 1):upper(), res.idx)
  self:save()
  self.last_count = -1
end

--------------------------------------------------------------------------------
-- sync
--------------------------------------------------------------------------------
function App:run_sync()
  self.force = false
  self.pending_t = nil
  if self.cfg.root == "" then self.err = "Choose a sounds folder first."; return end
  if self.ngroups == 0 then return end
  local st, err = RA.sync(self)
  if not st then self.err = "Sync failed: " .. tostring(err); return end
  self.err = nil
  self.last_stats = st
  local bad = 0
  for _ in pairs(st.bad) do bad = bad + 1 end
  if bad > 0 then self.err = bad .. " sound file(s) could not be loaded." end
  self.last_sig = self.sig
  RA.save_sig(self.sig)
  if self.cfg.inherited then self.cfg.inherited = false; self:save() end     -- the project keeps this folder now
  self.last_count = r.GetProjectStateChangeCount(0)   -- our own edits are not a reason to sync again
  self.ov_dirty = true
  self.msg = string.format("Synced: +%d items, ~%d moved/changed, -%d items; +%d/-%d tracks.",
    st.items_new, st.items_upd, st.items_del, st.tracks_new, st.tracks_del)
end

function App:refresh_markers()
  self.markers = RA.read_markers()
  self.plan = Core.plan(self.markers, self.groups, self.cfg.seed, { salts = self.cfg.salts, lenfn = RA.file_len })
  self.rows = self.plan.rows
  self.sig = Core.signature(self.markers, self.cfg, self.gsig)
  if self.sig ~= self.last_sig then self.pending_t = r.time_precise() end   -- restarts while a marker is dragged
end

-- another project tab became active: every setting is per project, so load that project's
function App:switch_project(proj)
  self.proj = proj
  self.cfg = RA.load_cfg()
  self.last_sig = RA.load_sig()
  self.pending_t, self.force = nil, false
  self.msg, self.err = nil, nil
  self.ov, self.ov_dirty = {}, true
  self:rescan()
end

function App:tick()
  local now = r.time_precise()
  local proj = r.EnumProjects(-1)
  if proj ~= self.proj then self:switch_project(proj) end
  local cnt = r.GetProjectStateChangeCount(0)
  if cnt ~= self.last_count then
    self.last_count = cnt
    self:refresh_markers()
    self.ov_dirty = true
    if self.sig == self.last_sig then self.pending_t = nil end
  end
  -- override flags: reads every managed item, so at most a few times per second
  if self.ov_dirty and now - self.ov_t >= 0.4 then
    self.ov, self.ov_dirty, self.ov_t = RA.detect_overrides(), false, now
    self.info = RA.managed_info()
  end
  if self.force then
    self:run_sync()
  elseif self:live() and self.pending_t and now - self.pending_t >= DEBOUNCE then
    self:run_sync()
  end
end

return App

end
__preload["ProtoUI"] = function(...)
-- ProtoUI.lua
-- ReaImGui front-end. Only reads app state and calls App methods.
-- Style/API follows Spike_Leveler.lua and Granular (r.ImGui_* functions, colours as 0xRRGGBBAA).

local r = reaper
local Core = require("ProtoCore")
local RA = require("ProtoReaper")

local UI = {}
UI.__index = UI

local COL_HEAD = 0xFFCC44FF
local COL_OK   = 0x5FE07FFF
local COL_BAD  = 0xFF5F5FFF
local COL_WARN = 0xFFAA33FF
local COL_DIM  = 0x999999FF
local COL_LIVE = 0x5FE07FFF
local COL_FROZ = 0x6FB7FFFF

function UI.new(app, host)
  local self = setmetatable({}, UI)
  self.A = app
  self.host = host or {}
  self.ctx = r.ImGui_CreateContext("PrototypeSequence")
  self.title = "PrototypeSequence v" .. Core.VERSION .. "###prototype_sequence_main"
  self.path_buf = nil
  self.seed_buf = nil
  self.confirm_clean = false
  self.confirm_detach = false
  self.fade_buf = nil
  return self
end

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function fmt_pos(p)
  local ok, s = pcall(r.format_timestr_pos, p, "", -1)
  return (ok and s and s ~= "") and s or string.format("%.3f", p)
end

function UI:tip(text)
  local ctx = self.ctx
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_SetTooltip then r.ImGui_SetTooltip(ctx, text) end
end

-- greys out (and blocks) the widgets drawn until the returned closer is called; no-op on old ReaImGui
function UI:disable_if(cond)
  if cond and r.ImGui_BeginDisabled then
    r.ImGui_BeginDisabled(self.ctx, true)
    return function() r.ImGui_EndDisabled(self.ctx) end
  end
  return function() end
end

function UI:heading(text)
  local ctx = self.ctx
  r.ImGui_Spacing(ctx)
  r.ImGui_TextColored(ctx, COL_HEAD, text)
  r.ImGui_Separator(ctx)
end

-- folder(s) dropped from the OS onto the last item; returns the first path or nil
-- (handles the 0.9+ and the older ReaImGui return shapes)
function UI:dropped_path()
  local ctx = self.ctx
  local path
  if r.ImGui_BeginDragDropTarget(ctx) then
    local a, b = r.ImGui_AcceptDragDropPayloadFiles(ctx)
    local rv, count = a, b
    if type(a) ~= "boolean" then count = a; rv = (a or 0) > 0 end
    if rv and (count or 0) > 0 then
      local x, y = r.ImGui_GetDragDropPayloadFile(ctx, 0)
      path = (type(x) == "string") and x or y
    end
    r.ImGui_EndDragDropTarget(ctx)
  end
  return path
end

function UI:browse()
  local A = self.A
  if r.JS_Dialog_BrowseForFolder then
    local rv, folder = r.JS_Dialog_BrowseForFolder("Sounds root folder (contains one sub-folder per sound group)", A.cfg.root or "")
    if rv == 1 and folder and folder ~= "" then A:set_root(folder); self.path_buf = nil end
  else
    local ok, file = r.GetUserFileNameForRead(A.cfg.root or "", "Pick any file inside the sounds root folder", "")
    if ok and file and file ~= "" then A:set_root(file); self.path_buf = nil end
  end
end

--------------------------------------------------------------------------------
-- sections
--------------------------------------------------------------------------------
function UI:draw_folder()
  local ctx, A = self.ctx, self.A
  self:heading("Sounds folder")

  local w = select(1, r.ImGui_GetContentRegionAvail(ctx))
  local SQ = 46
  local label = (A.cfg.root ~= "") and (A.cfg.root .. "\n(click to change, or drop another folder here)")
    or "Drop the sounds root folder here\n(click to browse)"
  if r.ImGui_Button(ctx, label .. "##drop", w - SQ - 6, SQ) then self:browse() end
  local dropped = self:dropped_path()                -- must come right after the drop-zone button
  if dropped then A:set_root(dropped); self.path_buf = nil end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Re-\nscan##scan", SQ, SQ) then A:update_folder(); self.path_buf = nil end
  self:tip("Re-read the sounds folder (new / removed files, changed lengths) and update PROTO")

  r.ImGui_SetNextItemWidth(ctx, w)
  self.path_buf = self.path_buf or A.cfg.root
  local changed, buf = r.ImGui_InputText(ctx, "##path", self.path_buf, r.ImGui_InputTextFlags_EnterReturnsTrue())
  if changed then self.path_buf = buf; A:set_root(buf); self.path_buf = nil
  else self.path_buf = buf end

  -- project folder vs. common default
  local cfg = A.cfg
  if cfg.inherited then r.ImGui_TextColored(ctx, COL_DIM, "This project uses the default folder (saved into the project on its first sync).")
  elseif cfg.root ~= "" then r.ImGui_TextColored(ctx, COL_DIM, "Saved with this project.") end
  local same = (cfg.default_root == cfg.root)
  r.ImGui_TextColored(ctx, COL_DIM, "Default for new projects: " .. (cfg.default_root ~= "" and cfg.default_root or "(none yet)"))
  local done = self:disable_if(cfg.root == "" or same)
  if r.ImGui_SmallButton(ctx, "Make this the default") then A:make_default() end
  done()
  self:tip("New projects will start with this project's folder")
  r.ImGui_SameLine(ctx)
  done = self:disable_if(cfg.default_root == "" or same)
  if r.ImGui_SmallButton(ctx, "Use the default here") then A:use_default(); self.path_buf = nil end
  done()
  self:tip("Switch this project to the default folder")

  -- groups found
  if A.ngroups > 0 then
    local ids = {}
    for id in pairs(A.groups) do ids[#ids + 1] = id end
    table.sort(ids)
    for i, id in ipairs(ids) do
      local g = A.groups[id]
      if i > 1 then r.ImGui_SameLine(ctx) end
      r.ImGui_TextColored(ctx, #g.sounds > 0 and COL_OK or COL_WARN, string.format("%s (%d)", g.name, #g.sounds))
    end
  elseif A.cfg.root ~= "" then
    r.ImGui_TextColored(ctx, COL_BAD, "no sub-folders found")
  end
end

function UI:draw_controls()
  local ctx, A = self.ctx, self.A
  self:heading("Seed & mode")

  self.seed_buf = self.seed_buf or A.cfg.seed
  r.ImGui_SetNextItemWidth(ctx, 120)
  local _, v = r.ImGui_InputInt(ctx, "Seed", self.seed_buf, 0, 0)
  self.seed_buf = v
  if r.ImGui_IsItemDeactivatedAfterEdit(ctx) then A:set_seed(v) end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Re-roll") then A:reroll(); self.seed_buf = A.cfg.seed end

  r.ImGui_Spacing(ctx)
  if A:live() then
    r.ImGui_TextColored(ctx, COL_LIVE, "LIVE")
    r.ImGui_SameLine(ctx); r.ImGui_TextColored(ctx, COL_DIM, "- following markers & regions")
    if r.ImGui_Button(ctx, "Freeze") then A:freeze() end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Freeze & clean") then self.confirm_clean = true end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Sync now") then A:sync_now() end
  else
    r.ImGui_TextColored(ctx, COL_FROZ, "FROZEN")
    r.ImGui_SameLine(ctx); r.ImGui_TextColored(ctx, COL_DIM, "- PROTO is not touched")
    if r.ImGui_Button(ctx, "Go live") then A:go_live() end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Sync once") then A:sync_now() end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Freeze & clean") then self.confirm_clean = true end
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, COL_DIM, "Freeze & clean keeps only the un-muted items")

  -- fade-out of trimmed (region) items
  self.fade_buf = self.fade_buf or math.floor(A.cfg.fade * 1000 + 0.5)
  r.ImGui_SetNextItemWidth(ctx, 80)
  local _, fv = r.ImGui_InputInt(ctx, "ms fade-out on trimmed items", self.fade_buf, 0, 0)
  self.fade_buf = fv
  if r.ImGui_IsItemDeactivatedAfterEdit(ctx) then A:set_fade(fv) end

  -- what is managed (found by tags, so renaming tracks is fine)
  local info = A.info or { tracks = 0 }
  if info.root_name then
    r.ImGui_TextColored(ctx, COL_DIM, string.format("Managed: '%s' + %d tracks", info.root_name, info.tracks))
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Show") then A:show_root() end
    self:tip("Select the PROTO track and scroll to it")
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Detach...") then self.confirm_detach = true end
    self:tip("Stop managing PROTO for good: tracks and items stay, as ordinary ones")
  end
  if self.confirm_detach then
    r.ImGui_TextColored(ctx, COL_WARN, "Detach: all PROTO tracks and items become ordinary. The script will never touch them again.")
    if r.ImGui_Button(ctx, "Yes, detach") then A:detach(); self.confirm_detach = false end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel##detach") then self.confirm_detach = false end
  end

  if self.confirm_clean then
    r.ImGui_TextColored(ctx, COL_WARN, "Delete all muted PROTO items and the tracks that become empty?")
    if r.ImGui_Button(ctx, "Yes, freeze & clean") then A:freeze_clean(); self.confirm_clean = false end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel") then self.confirm_clean = false end
  end
end

local COL_CUR = 0x2E5E8A80

local function override_text(o)
  local t = {}
  if #o.unmuted > 0 then t[#t + 1] = "unmuted by hand: " .. table.concat(o.unmuted, ", ") end
  if #o.muted > 0 then t[#t + 1] = "picked sound muted by hand: " .. table.concat(o.muted, ", ") end
  if #o.moved > 0 then t[#t + 1] = "moved by hand: " .. table.concat(o.moved, ", ") end
  return table.concat(t, "\n")
end

function UI:draw_row_actions(i, row, ov)
  local ctx, A = self.ctx, self.A
  local m, ok, live = row.marker, (row.status == "ok"), A:live()
  if m.isrgn then
    if r.ImGui_SmallButton(ctx, "R>M##c" .. i) then A:convert_cue(row) end
    self:tip("Region -> marker (drops the length)")
  else
    local done = self:disable_if(not ok)
    if r.ImGui_SmallButton(ctx, "M>R##c" .. i) then A:convert_cue(row) end
    done()
    self:tip("Marker -> region as long as the picked sound")
  end
  r.ImGui_SameLine(ctx)
  local done = self:disable_if(not ok or not live)
  if r.ImGui_SmallButton(ctx, "Roll##r" .. i) then A:reroll_cue(row) end
  done()
  self:tip("Pick another random sound for this cue only (LIVE mode)")
  if ov then
    r.ImGui_SameLine(ctx)
    done = self:disable_if(not live)
    if r.ImGui_SmallButton(ctx, "Reset##x" .. i) then A:reset_cue(row) end
    done()
    self:tip("Drop the manual changes of this cue and put its items back as planned (LIVE mode)")
  end
end

function UI:draw_markers()
  local ctx, A = self.ctx, self.A
  self:heading(string.format("Markers & regions (%d)", #A.rows))

  local ch, v = r.ImGui_Checkbox(ctx, "Follow timeline", A.cfg.follow)
  if ch then A:set_follow(v) end
  self:tip("Highlight and scroll to the cue at the play position (edit cursor when stopped)")
  local cur = A.cfg.follow and A:current_cue() or nil

  local _, avail_h = r.ImGui_GetContentRegionAvail(ctx)
  local flags = r.ImGui_TableFlags_RowBg() | r.ImGui_TableFlags_ScrollY() | r.ImGui_TableFlags_Resizable()
  if r.ImGui_BeginTable(ctx, "markers", 8, flags, 0, math.max(120, (avail_h or 200) - 46)) then
    r.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
    r.ImGui_TableSetupColumn(ctx, "#", r.ImGui_TableColumnFlags_WidthFixed(), 46)
    r.ImGui_TableSetupColumn(ctx, "Name", r.ImGui_TableColumnFlags_WidthStretch(), 2)
    r.ImGui_TableSetupColumn(ctx, "Position", r.ImGui_TableColumnFlags_WidthFixed(), 90)
    r.ImGui_TableSetupColumn(ctx, "Length", r.ImGui_TableColumnFlags_WidthFixed(), 60)
    r.ImGui_TableSetupColumn(ctx, "Folder", r.ImGui_TableColumnFlags_WidthFixed(), 90)
    r.ImGui_TableSetupColumn(ctx, "Sound", r.ImGui_TableColumnFlags_WidthStretch(), 2)
    r.ImGui_TableSetupColumn(ctx, "Flags", r.ImGui_TableColumnFlags_WidthFixed(), 80)
    r.ImGui_TableSetupColumn(ctx, "", r.ImGui_TableColumnFlags_WidthFixed(), 150)
    r.ImGui_TableHeadersRow(ctx)
    for i, row in ipairs(A.rows) do
      local m = row.marker
      local ok = (row.status == "ok")
      local ov = A.ov and A.ov[Core.marker_key(m)]
      r.ImGui_TableNextRow(ctx)
      if cur == i then r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg0(), COL_CUR) end
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, (cur == i and ">" or " ") .. (m.isrgn and "R" or "M") .. m.idx)
      if cur == i and self.last_cur ~= i then r.ImGui_SetScrollHereY(ctx, 0.5) end
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_TextColored(ctx, ok and COL_OK or COL_BAD, (m.name ~= "" and m.name) or "(unnamed)")
      if r.ImGui_IsItemClicked(ctx) then r.SetEditCurPos(m.pos, true, false) end
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, fmt_pos(m.pos))
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, m.isrgn and string.format("%.2fs", m.rgnend - m.pos) or "-")
      r.ImGui_TableNextColumn(ctx)
      if ok then r.ImGui_TextColored(ctx, COL_OK, row.group.name)
      elseif row.status == "empty" then r.ImGui_TextColored(ctx, COL_WARN, "no sounds")
      else r.ImGui_TextColored(ctx, COL_BAD, "no such folder") end
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, (ok and row.pick) and row.pick.name or "")
      r.ImGui_TableNextColumn(ctx)
      if ov then
        r.ImGui_TextColored(ctx, COL_WARN, "OVERRIDE")
        self:tip(override_text(ov))
      elseif ok and (row.voice or 1) > 1 then
        r.ImGui_TextColored(ctx, COL_DIM, "voice " .. row.voice)
        self:tip("Overlaps an earlier cue of this folder, so it uses a duplicate set of tracks")
      end
      r.ImGui_TableNextColumn(ctx)
      self:draw_row_actions(i, row, ov)
    end
    r.ImGui_EndTable(ctx)
  end
  self.last_cur = cur
  if #A.rows > 0 then
    r.ImGui_TextColored(ctx, COL_DIM, "green = name matches a sub-folder, red = ignored.  Click a name to move the edit cursor.")
  else
    r.ImGui_TextColored(ctx, COL_DIM, "No markers or regions in the project yet. Name them after your sound folders.")
  end
end

--------------------------------------------------------------------------------
-- frame
--------------------------------------------------------------------------------
function UI:draw()
  local A = self.A
  self:draw_folder()
  self:draw_controls()
  self:draw_markers()
  local ctx = self.ctx
  if A.err then r.ImGui_TextColored(ctx, COL_BAD, A.err)
  elseif A.msg then r.ImGui_TextColored(ctx, COL_DIM, A.msg) end
end

-- returns false when the window has been closed
function UI:frame()
  local ctx = self.ctx
  r.ImGui_SetNextWindowSize(ctx, 760, 620, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, self.title, true)
  if visible then
    local ok, e = pcall(self.draw, self)
    if not ok then
      self.A.err = "UI error: " .. tostring(e)
    end
    r.ImGui_End(ctx)
  end
  return open
end

return UI

end

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

