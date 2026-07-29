# DONE

Completed tasks, newest first. Moved here from [TODO.md](TODO.md).

## 2026-07-29
- **Minimum loop time** (`feat/loop-min-time`) — "Min loop s" field in the Loop row;
  `loopfind.py --min-s N` grows periodic loops by whole cycles and widens texture
  plateaus, capped by the file (reported as `short`). UAT passed; merged to master.
  Shipped with it: the `tool.exe` staleness guard (`_tool_exe` falls back to `py`
  when an indexer source is newer than the frozen build) — without it the app ran a
  July snapshot that ignored `--min-s`.
