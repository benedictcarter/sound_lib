"""
Single entry point for the STANDALONE build. `tool <cmd> [args...]` runs the matching
indexer script exactly as `python <cmd>.py [args]` would. PyInstaller freezes THIS into
one tool.exe that bundles Python + every dependency, so end users need nothing installed.

    tool index [--full]
    tool envelope <audio> <out.json>
    tool analyse_audio --only-missing --progress <f>
    tool fingerprint / embed / clap_embed / search / similar / clap_search / ...

The app finds tool.exe next to the scripts and calls it instead of `py <script>.py`;
it sets SOUNDLIB_REPO so the scripts resolve app/index.json + library.cfg correctly.
"""

from __future__ import annotations

import runpy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Import every subcommand + helper so PyInstaller collects them into the exe.
import index          # noqa: E401,F401
import envelope       # noqa: F401
import analyse_audio  # noqa: F401
import chop           # noqa: F401
import loopify        # noqa: F401
import loopfind       # noqa: F401
import suggest_chops  # noqa: F401
import embed          # noqa: F401
import search         # noqa: F401
import fingerprint    # noqa: F401
import similar        # noqa: F401
import to_wav         # noqa: F401
import to_16bit       # noqa: F401
import gaps           # noqa: F401
import loud           # noqa: F401
try:                  # CLAP is optional (heavy deps); still bundled when present
    import clap_embed  # noqa: F401
    import clap_search  # noqa: F401
except Exception:
    pass

CMDS = {"index", "envelope", "analyse_audio", "chop", "loopify", "loopfind",
        "suggest_chops", "embed", "search", "fingerprint", "similar", "to_wav",
        "to_16bit", "clap_embed", "clap_search"}


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        sys.exit("usage: tool <cmd> [args]\ncmds: " + ", ".join(sorted(CMDS)))
    cmd = sys.argv[1]
    sys.argv = [cmd] + sys.argv[2:]           # each script sees its own argv
    runpy.run_module(cmd, run_name="__main__", alter_sys=True)   # runs its main()


if __name__ == "__main__":
    main()
