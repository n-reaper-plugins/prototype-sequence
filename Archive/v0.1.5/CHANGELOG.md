# Changelog
## 0.1.5
* Square re-scan button beside the drop zone (re-reads the folder, forces a re-sync).
* "Follow timeline": list highlights/scrolls to the cue at the play position / edit cursor.
* Marker <-> Region buttons in the list (region length = picked sound; keeps name, colour, number, sound and items).
* OVERRIDE flag for cues whose items were unmuted / moved by hand, with a per-cue Reset.
  Positions/lengths/mutes are now only re-applied when the wanted value changes.
* Roll: new random sound for a single cue, stored per project.
* Fix: overlapping cues of the same folder get duplicate sets of sound tracks ("voices").
* Projects: switching project tabs loads that project's settings (folder, seed, re-rolls, mode).
* Pick is now hashed from the cue NUMBER (not "m2"/"r2"), so picks differ from 0.1.0 once; M3/R3 share a pick.
## 0.1.0
* First version: PROTO folder, per-folder groups with one track per sound, seeded pick, LIVE / Freeze / Freeze & clean, marker list with green/red status, folder drop / browse / type.
