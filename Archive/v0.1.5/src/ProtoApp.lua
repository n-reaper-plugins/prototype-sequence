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

function App:set_follow(on) self.cfg.follow = on and true or false; self:save() end

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
  end
  if self.force then
    self:run_sync()
  elseif self:live() and self.pending_t and now - self.pending_t >= DEBOUNCE then
    self:run_sync()
  end
end

return App
