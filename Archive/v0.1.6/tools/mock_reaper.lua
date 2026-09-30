-- In-memory fake of the parts of the REAPER API that PrototypeSequence uses.
-- It checks OUR logic (structure, tags, diffing, main loop), not REAPER's behaviour.
package.path = "./src/?.lua;" .. package.path

local M = {}

function M.install()
  local S = {
    tracks = {}, ext = {}, projext = {}, fs = {}, filelen = {}, badfiles = {},
    markers = {}, statecount = 1, undo = 0, clock = 0, deferred = {}, atexit = {},
    console = {}, edit_cursor = 0, next_id = 1,
  }
  M.S = S
  local function bump() S.statecount = S.statecount + 1 end
  local function idx_of(t) for i, x in ipairs(S.tracks) do if x == t then return i end end end

  ---------------------------------------------------------------- scene helpers
  function M.add_dir(path, dirs, files)
    S.fs[path] = { dirs = dirs or {}, files = files or {} }
  end
  -- root/<group>/<files>
  function M.make_sounds(root, groups)
    local names = {}
    for g, files in pairs(groups) do names[#names + 1] = g end
    table.sort(names)
    M.add_dir(root, names, {})
    for _, g in ipairs(names) do M.add_dir(root .. "/" .. g, {}, groups[g]) end
  end
  function M.add_marker(name, pos, rgnend, idx)
    local isrgn = rgnend ~= nil
    if not idx then
      idx = 1
      for _, m in ipairs(S.markers) do if m.isrgn == isrgn and m.idx >= idx then idx = m.idx + 1 end end
    end
    local m = { isrgn = isrgn, pos = pos, rgnend = rgnend or pos, name = name, idx = idx, color = 0 }
    S.markers[#S.markers + 1] = m
    bump()
    return m
  end
  function M.remove_marker(m)
    for i, x in ipairs(S.markers) do if x == m then table.remove(S.markers, i); break end end
    bump()
  end
  function M.touch() bump() end
  function M.new_user_track(name)
    local t = { name = name, ext = {}, items = {}, depth = 0, compact = 0, sel = false, id = S.next_id }
    S.next_id = S.next_id + 1
    S.tracks[#S.tracks + 1] = t
    bump()
    return t
  end

  -- Track > Duplicate: copy right below the original, tags and items included
  function M.duplicate_track(t)
    local c = { name = t.name, ext = {}, items = {}, depth = t.depth, compact = t.compact, sel = false, id = S.next_id }
    S.next_id = S.next_id + 1
    for k, v in pairs(t.ext) do c.ext[k] = v end
    for _, it in ipairs(t.items) do
      local ni = { track = c, p = {}, ext = {}, takes = { { name = it.takes[1].name, src = it.takes[1].src } } }
      for k, v in pairs(it.p) do ni.p[k] = v end
      for k, v in pairs(it.ext) do ni.ext[k] = v end
      c.items[#c.items + 1] = ni
    end
    for i, x in ipairs(S.tracks) do if x == t then table.insert(S.tracks, i + 1, c); break end end
    bump()
    return c
  end

  -- "depth name" for every track, plus a check that the folder nesting is balanced
  function M.structure()
    local out, depth = {}, 0
    for _, t in ipairs(S.tracks) do
      out[#out + 1] = string.rep("  ", depth) .. t.name
      depth = depth + t.depth
    end
    return out, depth
  end
  function M.track_named(name)
    for _, t in ipairs(S.tracks) do if t.name == name then return t end end
  end
  function M.items_of(name)
    local t = M.track_named(name)
    return t and t.items or {}
  end

  ---------------------------------------------------------------- API
  local R = {}
  reaper = R

  R.ShowConsoleMsg = function(s) S.console[#S.console + 1] = s end
  R.MB = function() return 1 end
  R.atexit = function(f) S.atexit[#S.atexit + 1] = f end
  R.defer = function(f) S.deferred[#S.deferred + 1] = f end
  R.time_precise = function() return S.clock end
  R.get_action_context = function() return true, "x", 0, 0, 0, 0 end
  R.SetToggleCommandState = function() end
  R.RefreshToolbar2 = function() end
  R.GetExtState = function(sec, k) return S.ext[sec .. "/" .. k] or "" end
  R.SetExtState = function(sec, k, v) S.ext[sec .. "/" .. k] = v end
  R.GetProjExtState = function(_, sec, k)
    local v = S.projext[sec .. "/" .. k]
    return v and 1 or 0, v or ""
  end
  R.SetProjExtState = function(_, sec, k, v) S.proj_writes = (S.proj_writes or 0) + 1; S.projext[sec .. "/" .. k] = (v ~= "" and v) or nil end
  R.Main_OnCommand = function(id) S.last_command = id end
  R.GetProjectStateChangeCount = function() return S.statecount end
  R.PreventUIRefresh = function() end
  R.Undo_BeginBlock2 = function() end
  R.Undo_EndBlock2 = function() S.undo = S.undo + 1 end
  R.TrackList_AdjustWindows = function() end
  R.UpdateArrange = function() end
  R.SetEditCurPos = function(p) S.edit_cursor = p end
  R.format_timestr_pos = function(p) return string.format("%.3f", p) end

  -- file system
  R.EnumerateSubdirectories = function(path, i)
    local d = S.fs[path]; if not d or i < 0 then return nil end
    return d.dirs[i + 1]
  end
  R.EnumerateFiles = function(path, i)
    local d = S.fs[path]; if not d or i < 0 then return nil end
    return d.files[i + 1]
  end
  R.file_exists = function(p) return p:match("%.%w+$") ~= nil end

  -- markers (REAPER enumerates in timeline order)
  R.EnumProjectMarkers3 = function(_, i)
    local sorted = {}
    for k, m in ipairs(S.markers) do sorted[k] = m end
    table.sort(sorted, function(a, b) if a.pos ~= b.pos then return a.pos < b.pos end return a.idx < b.idx end)
    local m = sorted[i + 1]
    if not m then return 0 end
    return i + 2, m.isrgn, m.pos, m.rgnend, m.name, m.idx, m.color
  end
  R.AddProjectMarker2 = function(_, isrgn, pos, rgnend, name, wantidx, color)
    local used = {}
    for _, m in ipairs(S.markers) do if m.isrgn == isrgn then used[m.idx] = true end end
    local idx = wantidx
    if not idx or idx < 0 or used[idx] then idx = 1; while used[idx] do idx = idx + 1 end end
    S.markers[#S.markers + 1] = { isrgn = isrgn, pos = pos, rgnend = isrgn and rgnend or pos, name = name, idx = idx, color = color or 0 }
    bump()
    return idx
  end
  R.DeleteProjectMarker = function(_, idx, isrgn)
    for i, m in ipairs(S.markers) do
      if m.idx == idx and m.isrgn == isrgn then table.remove(S.markers, i); bump(); return true end
    end
    return false
  end
  R.EnumProjects = function() return S.proj or "PROJ1" end
  R.GetPlayState = function() return S.playing and 1 or 0 end
  R.GetPlayPosition = function() return S.play_pos or 0 end
  R.GetCursorPosition = function() return S.edit_cursor end

  -- tracks
  R.CountTracks = function() return #S.tracks end
  R.GetTrack = function(_, i) return S.tracks[i + 1] end
  R.InsertTrackAtIndex = function(i, _)
    local t = { name = "", ext = {}, items = {}, depth = 0, compact = 0, sel = false, id = S.next_id }
    S.next_id = S.next_id + 1
    table.insert(S.tracks, i + 1, t)
    bump()
  end
  R.DeleteTrack = function(t)
    local i = idx_of(t); assert(i, "DeleteTrack: unknown track")
    table.remove(S.tracks, i); t.deleted = true; bump()
  end
  R.GetMediaTrackInfo_Value = function(t, k)
    assert(not t.deleted, "use of deleted track")
    if k == "IP_TRACKNUMBER" then return idx_of(t) or 0 end
    if k == "I_FOLDERDEPTH" then return t.depth end
    if k == "I_FOLDERCOMPACT" then return t.compact end
    error("GetMediaTrackInfo_Value " .. k)
  end
  R.SetMediaTrackInfo_Value = function(t, k, v)
    assert(not t.deleted, "use of deleted track")
    if k == "I_FOLDERDEPTH" then t.depth = v
    elseif k == "I_FOLDERCOMPACT" then t.compact = v
    else error("SetMediaTrackInfo_Value " .. k) end
    bump()
  end
  R.GetSetMediaTrackInfo_String = function(t, k, v, set)
    assert(not t.deleted, "use of deleted track")
    if k == "P_NAME" then
      if set then t.name = v; bump(); return true end
      return true, t.name
    end
    local ek = k:match("^P_EXT:(.+)$"); assert(ek, "track string " .. k)
    if set then t.ext[ek] = v; bump(); return true end
    return t.ext[ek] ~= nil, t.ext[ek] or ""
  end
  R.CountSelectedTracks = function()
    local n = 0; for _, t in ipairs(S.tracks) do if t.sel then n = n + 1 end end; return n
  end
  R.GetSelectedTrack = function(_, i)
    local n = 0
    for _, t in ipairs(S.tracks) do if t.sel then if n == i then return t end; n = n + 1 end end
  end
  R.SetTrackSelected = function(t, s) t.sel = s and true or false end
  R.SetOnlyTrackSelected = function(t) for _, x in ipairs(S.tracks) do x.sel = (x == t) end end
  -- moves the selected tracks so that they end up directly above the track that is at index `before` now
  R.ReorderSelectedTracks = function(before, _)
    local target = S.tracks[before + 1]                     -- nil = end
    local moving, rest = {}, {}
    for _, t in ipairs(S.tracks) do if t.sel then moving[#moving + 1] = t else rest[#rest + 1] = t end end
    if #moving == 0 then return false end
    local pos = #rest + 1
    if target then for i, t in ipairs(rest) do if t == target then pos = i; break end end end
    if target and target.sel then error("mock: before-track is selected") end
    for i, t in ipairs(moving) do table.insert(rest, pos + i - 1, t) end
    S.tracks = rest; bump()
    return true
  end

  -- items
  R.CountTrackMediaItems = function(t) return #t.items end
  R.GetTrackMediaItem = function(t, i) return t.items[i + 1] end
  R.AddMediaItemToTrack = function(t)
    local it = { track = t, p = { D_POSITION = 0, D_LENGTH = 0, B_MUTE = 0, D_FADEOUTLEN = 0 }, ext = {}, takes = {} }
    t.items[#t.items + 1] = it; bump()
    return it
  end
  R.DeleteTrackMediaItem = function(t, it)
    for i, x in ipairs(t.items) do if x == it then table.remove(t.items, i); it.deleted = true; bump(); return true end end
    error("DeleteTrackMediaItem: item not on track")
  end
  R.GetMediaItemInfo_Value = function(it, k)
    assert(not it.deleted, "use of deleted item"); assert(it.p[k] ~= nil, "item value " .. k); return it.p[k]
  end
  R.SetMediaItemInfo_Value = function(it, k, v) assert(not it.deleted); it.p[k] = v; bump(); return true end
  R.GetSetMediaItemInfo_String = function(it, k, v, set)
    assert(not it.deleted, "use of deleted item")
    local ek = k:match("^P_EXT:(.+)$"); assert(ek, "item string " .. k)
    if set then it.ext[ek] = v; bump(); return true end
    return it.ext[ek] ~= nil, it.ext[ek] or ""
  end
  R.AddTakeToMediaItem = function(it) local tk = { item = it, name = "" }; it.takes[#it.takes + 1] = tk; return tk end
  R.GetActiveTake = function(it) return it.takes[1] end
  R.GetSetMediaItemTakeInfo_String = function(tk, k, v, set)
    if k == "P_NAME" then if set then tk.name = v; return true end; return true, tk.name end
    error("take string " .. k)
  end
  R.PCM_Source_CreateFromFile = function(path)
    if S.badfiles[path] then return nil end
    return { file = path, len = S.filelen[path] or 2.0 }
  end
  R.SetMediaItemTake_Source = function(tk, src) tk.src = src; bump() end
  R.GetMediaItemTake_Source = function(tk) return tk.src end
  R.GetMediaSourceLength = function(src) return src.len, false end
  R.PCM_Source_Destroy = function(src) end

  return S
end

return M
