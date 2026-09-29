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
