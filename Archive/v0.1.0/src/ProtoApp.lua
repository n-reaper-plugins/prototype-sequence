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
