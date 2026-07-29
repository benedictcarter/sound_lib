# DONE

Completed tasks, newest first. Moved here from [TODO.md](TODO.md).

## 2026-07-29
- **Crossfaded region in its own colour** (`feat/crossfade-region-colour`) — the two
  blended ends of a loop region shade violet with an "xfade N ms" label, clamped at
  half the region each (the clamp `loopify` bakes with). UAT passed; merged to master.
- **Draggable chop boundaries** (`feat/chop-edge-handles`) — the blue detector edges
  drag like the region ones, clamped between their partner and the neighbouring
  piece; `_effective_segments` reads the same array so Make/Play chops follow.
  UAT passed; merged to master.
- **Draggable handles on the yellow region edges** (`feat/region-drag-handles`) —
  arrow tabs on both edges of the manual region, each dragging one end only; brought
  with it the headless `tests/test_wavegraph_handles.gd` input harness.
  UAT passed; merged to master.
- **ms precision on GUI times** (`feat/ms-precision-times`) — `_fmt_time` renders
  `m:ss.mmm` everywhere (transport, status lines, chop cells, slider labels); the
  Duration filter slider keeps compact `m:ss`, its ticks have no room for ms.
  UAT passed; merged to master.
- **Minimum loop time** (`feat/loop-min-time`) — "Min loop s" field in the Loop row;
  `loopfind.py --min-s N` grows periodic loops by whole cycles and widens texture
  plateaus, capped by the file (reported as `short`). UAT passed; merged to master.
  Shipped with it: the `tool.exe` staleness guard (`_tool_exe` falls back to `py`
  when an indexer source is newer than the frozen build) — without it the app ran a
  July snapshot that ignored `--min-s`.
