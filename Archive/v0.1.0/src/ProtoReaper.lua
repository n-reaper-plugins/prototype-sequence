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
