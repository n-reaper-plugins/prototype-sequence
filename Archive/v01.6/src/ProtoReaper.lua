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
