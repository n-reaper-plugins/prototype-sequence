# PrototypeSequence v0.1.5 – marker-driven random sound sequences for REAPER

One action (`PrototypeSequence.lua`) opens a ReaImGui window and keeps one **PROTO** folder track in step with your
markers and regions. Name a marker after a sound folder, get that folder's sounds on the timeline – one of them audible.

## Install
**macOS (or `--portable` anywhere):** close REAPER, then `./install_mac.sh` from this folder (also finds `dist/PrototypeSequence.lua`).
It copies the script to `Scripts/PrototypeSequence/`, removes the download quarantine flag and registers the action in `reaper-kb.ini`
(backed up first; skipped if REAPER is running – use `--no-register` to skip it yourself). `./install_mac.sh --uninstall` removes exactly that.
Your projects are never touched.

**Manual:** load `PrototypeSequence.lua` as a ReaScript (*Actions → Show action list → New action → Load ReaScript…*) and run it.
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
* **Pick** = the sound with the highest `hash(seed : cue number [: re-roll counter] : file name)`. So moving/renaming a marker keeps its sound,
  a new seed re-rolls everything, and adding a file to a folder only changes the markers that switch to it.
  The number is the marker/region number without its type, so **M3 and R3 pick the same sound** – which is what lets a marker become a region and keep its sound.
* **Overlapping cues** of the same folder (a cue's extent = length of its picked sound, trimmed to the region) get a **duplicate set of sound tracks**
  ("bell_a", "bell_b", then "bell_a (2)", "bell_b (2)" …), one set per simultaneous "voice". The list shows `voice 2` for those.
  Cues at the exact same position count as overlapping. Re-rolling a cue can change its voice.
* The window shows every marker/region in timeline order, its folder and the sound picked. Click a name to move the edit cursor there.
* Folder, seed, per-cue re-rolls and mode are saved **with the project** (project extended state, written into the .rpp).

## The list
| | |
|---|---|
| **Follow timeline** | Highlights (`>`) and scrolls to the cue at the play position – or the edit cursor when stopped: the last cue at or before it. Markers → timeline is the main direction; this is timeline → list. |
| **square Re-scan button** (next to the drop zone) | Re-reads the folder (new/removed files, changed file lengths) and re-syncs PROTO, even if nothing looks changed. |
| **M>R / R>M** | Marker → region as long as the **picked sound** / region → marker (length dropped). Name, colour, number (if free) and the sound are kept; the items are re-used, not re-created. Only cues with a matching folder can become regions. |
| **Roll** | New random sound for **this cue only** (never the same one again). LIVE mode. Stored as a counter per cue in the project; a new seed still re-rolls everything. |
| **OVERRIDE** flag | Some item of the cue was **unmuted / the picked one muted / moved** by hand (hover for which tracks). Positions and lengths are only re-applied when the *wanted* value changes (marker moved, region resized), the mute state only when seed or Roll changes – so hand edits survive until then. |
| **Reset** (shown when flagged) | Drops the manual changes of that cue and puts its items back as planned. LIVE mode. |

## Modes
| | |
|---|---|
| **LIVE** | Marker/region/seed/folder changes are synced ~0.35 s after the last change (dragging a marker does not spam). **Live only runs while the window/script is open.** |
| **Freeze** | Stops following; PROTO is left exactly as it is. *Sync once* and *Go live* are available. |
| **Freeze & clean** | Asks for confirmation, then deletes all muted PROTO items and the tracks/folders that become empty, and freezes. |
| **Sync now** | Forces one sync. Also use it after re-creating tracks by hand. |

## What the script touches – and what it doesn't
* Only tracks/items it created (tagged with `PS_*` P_EXT data) – your other tracks and items are never modified.
* In live mode PROTO items follow the markers: when a marker moves, its items move to it (a manual move of those items is replaced then).
  Hand edits made otherwise stay and are flagged as OVERRIDE (see above).
* Tracks that are no longer needed (marker deleted, file removed) are deleted; if you put your own items on one, it is released
  (tags removed, kept in the project) instead of deleted.
* Each sync is one undo step.

## Development
`src/` holds the modules, `tools/build.lua` bundles them into `dist/PrototypeSequence.lua` (the one file users need).
`tools/run_tests.sh` builds and runs the offline tests (Lua 5.3+): core (hash, pick, planning), and against an in-memory fake of
the REAPER API the whole sync (structure, depths, geometry, seed/move/rename/delete, freeze, freeze & clean, debounce),
the UI with a stubbed ImGui (drop, typing, buttons, colours) and the built bundle's real main loop.

## Verified vs. NOT verified
Verified offline: everything above, against a **fake** REAPER (about 370 checks). **Not run inside REAPER – I could not.** Please check, in this order:
1. **Track reordering & folders**: `ReorderSelectedTracks` (used to bring new tracks into group order) and the `I_FOLDERDEPTH` values
   (`PROTO`=1, group=1, last sound of a group = -1, last sound of the last group = -2). If the nesting looks wrong, tell me what you see.
2. **Collapsed groups**: `I_FOLDERCOMPACT`=2 should show the groups minimised.
3. **Marker <-> region conversion** (`AddProjectMarker2` / `DeleteProjectMarker`): the new cue should keep name, colour and (if free) number; check undo restores it.
3b. **Overlap voices**: two overlapping cues of one folder should give a second set of tracks with the folder structure still balanced.
3c. **Follow timeline**: highlight while playing, `SetScrollHereY` inside the table.
3d. **Project tabs**: switching tabs while the window is open loads that project's folder/seed/mode.
3e. **Drag & drop of a folder** from Finder/Explorer onto the big button (`ImGui_AcceptDragDropPayloadFiles`) – ReaImGui versions differ; both return shapes are handled.
   And `JS_Dialog_BrowseForFolder` when js_ReaScriptAPI is installed.
4. **ReaImGui calls not used in Spike_Leveler/Granular**: `SmallButton`, `Checkbox`, `BeginDisabled`, `SetTooltip`, `TableSetBgColor`, `SetScrollHereY`, `InputInt`, `IsItemDeactivatedAfterEdit`, `BeginDragDropTarget`, `TableSetupScrollFreeze`,
   `GetContentRegionAvail`, `IsItemClicked`. A red line at the bottom of the window = send it to me.
5. **Marker lanes**: `EnumProjectMarkers3` should list markers/regions of *all* ruler lanes; check with markers in a second lane.
6. **Items**: `PCM_Source_CreateFromFile` items appear with the right take name/length; trimmed region items get their fade-out.
7. **Installer** (`SCR 4 0 RS<sha1> …` line format in `reaper-kb.ini`, tested only against a fake folder): after installing, the action should appear in the action list; if not, use *Load ReaScript…*.
8. **Undo**: one "PrototypeSequence: sync" step per update.
