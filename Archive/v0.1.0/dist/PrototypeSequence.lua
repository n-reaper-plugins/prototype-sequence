-- @description PrototypeSequence: random sound sequences on one PROTO folder track, driven by markers & regions
-- @version 0.1.0
-- @about
--   Run this action to open the PrototypeSequence window (needs ReaImGui: ReaPack > ReaTeam Extensions;
--   a folder dialog additionally needs js_ReaScriptAPI, otherwise a file dialog / drag&drop / typing is used).
--   Choose a sounds root folder with one sub-folder per sound group (root/bells, root/whistles).
--   Every marker or region NAMED like a sub-folder gets that group: one track per sound, all items placed,
--   one picked by the seed (from seed + marker number + file name) and the others muted.
--   Run the action again while the window is open to close it.
-- BUNDLED BUILD of PrototypeSequence v0.1.0 - edit the files in src/, not this one.
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

end
__preload["ProtoReaper"] = function(...)
-- ProtoReaper.lua
-- Everything that touches REAPER: folder scan, marker reading, track/item sync, freeze & clean.
-- Managed objects carry P_EXT tags so the script only ever touches what it created:
--   tracks: PS_ROLE = root|group|snd, PS_ID = (group: normalised folder name | snd: file path)
--   items : PS_KEY  = m<n>|r<n> (marker / region number), PS_SEL = "<seed>:<1|0>" (last applied choice)

local r = reaper
local Core = require("ProtoCore")

local RA = {}
local SECTION = "PrototypeSequence"
local E_ROLE, E_ID, E_KEY, E_SEL = "P_EXT:PS_ROLE", "P_EXT:PS_ID", "P_EXT:PS_KEY", "P_EXT:PS_SEL"
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
-- settings (per project, with a global fallback for the folder)
--------------------------------------------------------------------------------
function RA.load_cfg()
  local function pget(k) local _, v = r.GetProjExtState(0, SECTION, k); return v end
  local cfg = { root = pget("root"), seed = tonumber(pget("seed")), mode = pget("mode"), fade = tonumber(pget("fade")) }
  if cfg.root == "" then cfg.root = r.GetExtState(SECTION, "root") or "" end
  cfg.seed = cfg.seed or 1
  cfg.mode = (cfg.mode == "frozen") and "frozen" or "live"
  cfg.fade = cfg.fade or 0.05
  return cfg
end

function RA.save_cfg(cfg)
  r.SetProjExtState(0, SECTION, "root", cfg.root or "")
  r.SetProjExtState(0, SECTION, "seed", tostring(cfg.seed))
  r.SetProjExtState(0, SECTION, "mode", cfg.mode)
  r.SetProjExtState(0, SECTION, "fade", tostring(cfg.fade))
  if cfg.root and cfg.root ~= "" then r.SetExtState(SECTION, "root", cfg.root, true) end
end

function RA.load_sig() local _, v = r.GetProjExtState(0, SECTION, "sig"); return v ~= "" and v or nil end
function RA.save_sig(s) r.SetProjExtState(0, SECTION, "sig", s or "") end

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
  return out
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
      if role == "root" then ex.root = ex.root or tr
      elseif role == "group" then ex.groups[id] = ex.groups[id] or tr
      elseif role == "snd" then ex.snds[id] = ex.snds[id] or tr end
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

local function source_length(src)
  local len, is_qn = r.GetMediaSourceLength(src)
  if is_qn then return nil end
  return len
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
-- app = { cfg={root,seed,fade}, groups=, markers= }
function RA.sync(app)
  local cfg = app.cfg
  local plan = Core.plan(app.markers or RA.read_markers(), app.groups, cfg.seed)
  local st = { tracks_new = 0, tracks_del = 0, items_new = 0, items_upd = 0, items_del = 0, bad = {} }
  local len_cache = {}

  local res, err = with_undo("PrototypeSequence: sync", function()
    local ex = RA.index_tracks()
    local root = ex.root
    if not root then root = new_track("root", "PROTO", "PROTO"); st.tracks_new = st.tracks_new + 1 end
    set_name(root, "PROTO")

    -- 1. wanted tracks --------------------------------------------------------
    local D, layout, want_tr = { root }, {}, { [root] = true }
    for _, pg in ipairs(plan.order) do
      local gt = ex.groups[pg.id]
      if not gt then gt = new_track("group", pg.id, pg.name); st.tracks_new = st.tracks_new + 1 end
      set_name(gt, pg.name)
      want_tr[gt] = true; D[#D + 1] = gt
      local L = { track = gt, kids = {} }
      pg.tracks = {}
      for k, s in ipairs(pg.sounds) do
        local tr = ex.snds[s.path]
        if not tr then tr = new_track("snd", s.path, s.name); st.tracks_new = st.tracks_new + 1 end
        set_name(tr, s.name)
        want_tr[tr] = true; D[#D + 1] = tr; L.kids[#L.kids + 1] = tr; pg.tracks[k] = tr
      end
      layout[#layout + 1] = L
    end

    -- 2. items ----------------------------------------------------------------
    local wanted = {}
    for _, pg in ipairs(plan.order) do
      for k, s in ipairs(pg.sounds) do
        local tr = pg.tracks[k]
        local have, dups = track_items(tr)
        for _, it in ipairs(dups) do r.DeleteTrackMediaItem(tr, it); st.items_del = st.items_del + 1 end
        wanted[tr] = wanted[tr] or {}
        for _, e in ipairs(pg.entries) do
          local it = have[e.key]
          local fresh = false
          if not it then
            local src = r.PCM_Source_CreateFromFile(s.path)
            if not src then
              st.bad[s.path] = true
            else
              len_cache[s.path] = source_length(src)
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
            local changed = fresh
            -- source length (cached per file)
            local slen = len_cache[s.path]
            if slen == nil then
              local tk = r.GetActiveTake(it)
              local src = tk and r.GetMediaItemTake_Source(tk)
              slen = src and source_length(src) or false
              len_cache[s.path] = slen
            end
            if math.abs(r.GetMediaItemInfo_Value(it, "D_POSITION") - e.pos) > EPS then
              r.SetMediaItemInfo_Value(it, "D_POSITION", e.pos); changed = true
            end
            if slen then
              local len = slen
              if e.len and e.len < slen then len = e.len end          -- trim to region, never stretch
              if math.abs(r.GetMediaItemInfo_Value(it, "D_LENGTH") - len) > EPS then
                r.SetMediaItemInfo_Value(it, "D_LENGTH", len); changed = true
              end
              if len < slen - EPS and (cfg.fade or 0) > 0 then
                local f = math.min(cfg.fade, len)
                if math.abs(r.GetMediaItemInfo_Value(it, "D_FADEOUTLEN") - f) > EPS then
                  r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", f); changed = true
                end
              end
            end
            -- the choice is only (re)applied when it changed, so manual mute edits survive
            local is_sel = (k == e.sel)
            local tag = tostring(cfg.seed) .. ":" .. (is_sel and "1" or "0")
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
      if rec.role == "snd" then
        local have, dups, foreign = track_items(tr)
        local w = wanted[tr] or {}
        for key, it in pairs(have) do
          if not w[key] then r.DeleteTrackMediaItem(tr, it); st.items_del = st.items_del + 1 end
        end
        if not want_tr[tr] then
          for _, it in ipairs(dups) do r.DeleteTrackMediaItem(tr, it) end
        end
      end
      if not want_tr[tr] then
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
  self.cfg = RA.load_cfg()
  self.groups, self.ngroups = {}, 0
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
  self.groups, self.ngroups = RA.scan(self.cfg.root)
  self.gsig = Core.groups_sig(self.groups)
  self.last_count = -1                -- refresh the marker list and the signature
  if self.cfg.root == "" then self.msg = nil
  elseif self.ngroups == 0 then self.err = "No sub-folders found in " .. self.cfg.root; return
  end
  self.err = nil
end

function App:set_root(path)
  local p = RA.resolve_root(path)
  if p == "" then return end
  self.cfg.root = p
  self:rescan()
  self:save()
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
  self.last_count = r.GetProjectStateChangeCount(0)   -- our own edits are not a reason to sync again
  self.msg = string.format("Synced: +%d items, ~%d moved/changed, -%d items; +%d/-%d tracks.",
    st.items_new, st.items_upd, st.items_del, st.tracks_new, st.tracks_del)
end

function App:refresh_markers()
  self.markers = RA.read_markers()
  self.rows = Core.plan(self.markers, self.groups, self.cfg.seed).rows
  self.sig = Core.signature(self.markers, self.cfg, self.gsig)
  if self.sig ~= self.last_sig then self.pending_t = r.time_precise() end   -- restarts while a marker is dragged
end

function App:tick()
  local now = r.time_precise()
  local cnt = r.GetProjectStateChangeCount(0)
  if cnt ~= self.last_count then
    self.last_count = cnt
    self:refresh_markers()
    if self.sig == self.last_sig then self.pending_t = nil end
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
  return self
end

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function fmt_pos(p)
  local ok, s = pcall(r.format_timestr_pos, p, "", -1)
  return (ok and s and s ~= "") and s or string.format("%.3f", p)
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
  local label = (A.cfg.root ~= "") and (A.cfg.root .. "\n(click to change, or drop another folder here)")
    or "Drop the sounds root folder here\n(click to browse)"
  if r.ImGui_Button(ctx, label .. "##drop", w, 46) then self:browse() end
  local dropped = self:dropped_path()
  if dropped then A:set_root(dropped); self.path_buf = nil end

  r.ImGui_SetNextItemWidth(ctx, w - 130)
  self.path_buf = self.path_buf or A.cfg.root
  local changed, buf = r.ImGui_InputText(ctx, "##path", self.path_buf, r.ImGui_InputTextFlags_EnterReturnsTrue())
  if changed then self.path_buf = buf; A:set_root(buf); self.path_buf = nil
  else self.path_buf = buf end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Rescan") then A:rescan() end

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

  if self.confirm_clean then
    r.ImGui_TextColored(ctx, COL_WARN, "Delete all muted PROTO items and the tracks that become empty?")
    if r.ImGui_Button(ctx, "Yes, freeze & clean") then A:freeze_clean(); self.confirm_clean = false end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel") then self.confirm_clean = false end
  end
end

function UI:draw_markers()
  local ctx, A = self.ctx, self.A
  self:heading(string.format("Markers & regions (%d)", #A.rows))

  local _, avail_h = r.ImGui_GetContentRegionAvail(ctx)
  local flags = r.ImGui_TableFlags_RowBg() | r.ImGui_TableFlags_ScrollY() | r.ImGui_TableFlags_Resizable()
  if r.ImGui_BeginTable(ctx, "markers", 6, flags, 0, math.max(120, (avail_h or 200) - 46)) then
    r.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
    r.ImGui_TableSetupColumn(ctx, "#", r.ImGui_TableColumnFlags_WidthFixed(), 42)
    r.ImGui_TableSetupColumn(ctx, "Name", r.ImGui_TableColumnFlags_WidthStretch(), 2)
    r.ImGui_TableSetupColumn(ctx, "Position", r.ImGui_TableColumnFlags_WidthFixed(), 100)
    r.ImGui_TableSetupColumn(ctx, "Length", r.ImGui_TableColumnFlags_WidthFixed(), 70)
    r.ImGui_TableSetupColumn(ctx, "Folder", r.ImGui_TableColumnFlags_WidthFixed(), 110)
    r.ImGui_TableSetupColumn(ctx, "Sound", r.ImGui_TableColumnFlags_WidthStretch(), 2)
    r.ImGui_TableHeadersRow(ctx)
    for i, row in ipairs(A.rows) do
      local m = row.marker
      local ok = (row.status == "ok")
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, (m.isrgn and "R" or "M") .. m.idx)
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_TextColored(ctx, ok and COL_OK or COL_BAD, (m.name ~= "" and m.name) or "(unnamed)")
      if r.ImGui_IsItemClicked(ctx) then r.SetEditCurPos(m.pos, true, false) end
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, fmt_pos(m.pos))
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, m.isrgn and string.format("%.2fs", m.rgnend - m.pos) or "-")
      r.ImGui_TableNextColumn(ctx)
      if ok then r.ImGui_TextColored(ctx, COL_OK, row.group.name)
      elseif row.status == "empty" then r.ImGui_TextColored(ctx, COL_WARN, "no sounds in folder")
      else r.ImGui_TextColored(ctx, COL_BAD, "no such folder") end
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, (ok and row.pick) and row.pick.name or "")
    end
    r.ImGui_EndTable(ctx)
  end
  if #A.rows > 0 then
    r.ImGui_TextColored(ctx, COL_DIM, "green = marker name matches a sub-folder, red = ignored.  Click a name to move the edit cursor.")
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

