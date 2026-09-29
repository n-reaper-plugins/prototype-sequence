# PrototypeSequence v0.1.0 – marker-driven random sound sequences for REAPER

One action (`PrototypeSequence.lua`) opens a ReaImGui window and keeps one **PROTO** folder track in step with your
markers and regions. Name a marker after a sound folder, get that folder's sounds on the timeline – one of them audible.

## Install
Load `PrototypeSequence.lua` as a ReaScript (*Actions → Show action list → New action → Load ReaScript…*) and run it.
Needs **ReaImGui** (ReaPack → ReaTeam Extensions). Optional: **js_ReaScriptAPI** for a real folder dialog
(without it the button opens a file dialog – pick any file inside the root – or just drop/type the folder).
Running the action again while the window is open closes it.

## How it works
```
sounds root/            markers & regions (any ruler lane)         PROTO (folder)
  bells/    a.wav b.wav   "whistles" @ 8 s                           whistles (folder, collapsed)   <- first marker
  whistles/ w1.wav w2.wav "bells"    @ 10 s                            w1     item @8 (muted or not)
                          "bells"    region 20-24 s                    w2     item @8
                          "boom"     (red: no such folder, ignored)  bells (folder, collapsed)
                                                                       a      items @10, @20
                                                                       b      items @10, @20
```
* **Marker name = folder name** (one level, trimmed, case-insensitive). Green in the list = folder exists, red = ignored
  ("no sounds in folder" = orange).
* **Groups** are ordered by their first marker on the timeline; inside a group there is **one track per sound**.
  Group tracks are named after the folder and collapsed (`I_FOLDERCOMPACT` = 2).
* Every marker puts **one item on every track of its group**. The seed picks the one that stays **unmuted**, the others are muted.
* **Marker** → item has the sound's natural length. **Region** → item is trimmed to the region (short fade-out, default 50 ms);
  shorter sounds are never stretched or looped.
* **Pick** = the sound with the highest `hash(seed : marker-or-region number : file name)`. So moving/renaming a marker keeps its sound,
  a new seed re-rolls everything, and adding a file to a folder only changes the markers that switch to it. Markers and regions have separate numbers (M1, R1).
* The window shows every marker/region, its folder and the sound picked. Click a name to move the edit cursor there.
* Folder, seed and mode are saved **with the project**.

## Modes
| | |
|---|---|
| **LIVE** | Marker/region/seed/folder changes are synced ~0.35 s after the last change (dragging a marker does not spam). **Live only runs while the window/script is open.** |
| **Freeze** | Stops following; PROTO is left exactly as it is. *Sync once* and *Go live* are available. |
| **Freeze & clean** | Asks for confirmation, then deletes all muted PROTO items and the tracks/folders that become empty, and freezes. |
| **Sync now** | Forces one sync. Also use it after re-creating tracks by hand. |

## What the script touches – and what it doesn't
* Only tracks/items it created (tagged with `PS_*` P_EXT data) – your other tracks and items are never modified.
* In live mode positions and lengths of PROTO items follow the markers (manual moves are undone).
  **Mute state** is only re-applied when the pick changes (new seed, new marker), so if you unmute another candidate by hand it stays until then.
* Tracks that are no longer needed (marker deleted, file removed) are deleted; if you put your own items on one, it is released
  (tags removed, kept in the project) instead of deleted.
* Each sync is one undo step.

## Development
`src/` holds the modules, `tools/build.lua` bundles them into `dist/PrototypeSequence.lua` (the one file users need).
`tools/run_tests.sh` builds and runs the offline tests (Lua 5.3+): core (hash, pick, planning), and against an in-memory fake of
the REAPER API the whole sync (structure, depths, geometry, seed/move/rename/delete, freeze, freeze & clean, debounce),
the UI with a stubbed ImGui (drop, typing, buttons, colours) and the built bundle's real main loop.

## Verified vs. NOT verified
Verified offline: everything above, against a **fake** REAPER. **Not run inside REAPER – I could not.** Please check, in this order:
1. **Track reordering & folders**: `ReorderSelectedTracks` (used to bring new tracks into group order) and the `I_FOLDERDEPTH` values
   (`PROTO`=1, group=1, last sound of a group = -1, last sound of the last group = -2). If the nesting looks wrong, tell me what you see.
2. **Collapsed groups**: `I_FOLDERCOMPACT`=2 should show the groups minimised.
3. **Drag & drop of a folder** from Finder/Explorer onto the big button (`ImGui_AcceptDragDropPayloadFiles`) – ReaImGui versions differ; both return shapes are handled.
   And `JS_Dialog_BrowseForFolder` when js_ReaScriptAPI is installed.
4. **ReaImGui calls not used in Spike_Leveler/Granular**: `InputInt`, `IsItemDeactivatedAfterEdit`, `BeginDragDropTarget`, `TableSetupScrollFreeze`,
   `GetContentRegionAvail`, `IsItemClicked`. A red line at the bottom of the window = send it to me.
5. **Marker lanes**: `EnumProjectMarkers3` should list markers/regions of *all* ruler lanes; check with markers in a second lane.
6. **Items**: `PCM_Source_CreateFromFile` items appear with the right take name/length; trimmed region items get their fade-out.
7. **Undo**: one "PrototypeSequence: sync" step per update.
