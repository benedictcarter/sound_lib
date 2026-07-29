"""
Cooperative cancellation for the long-running indexer jobs.

The app runs these scripts as CHILD PROCESSES from worker threads, and some of them
(analyse / fingerprint / embed / CLAP over ~7,000 files) run for minutes. When the
user closes the window the app creates the file named by the ``SOUNDLIB_CANCEL``
environment variable and waits a moment before killing anything: a job that notices
the flag checkpoints what it has and exits, so the shutdown is quick *and* nothing is
left half-written. Jobs that never check it just get terminated instead.

Check it where a job is already at a safe point — between files, next to the progress
write — never mid-write of a result file. ``index.py`` is the exception: a partial
scan would DROP files from index.json, so there it aborts without writing at all.

Outside the app (plain CLI runs) the env var is unset and ``stop_requested()`` is a
constant False.
"""

from __future__ import annotations

import os

_PATH = os.environ.get("SOUNDLIB_CANCEL", "")


def stop_requested() -> bool:
    """True once the app has asked running jobs to wind up."""
    if not _PATH:
        return False
    try:
        return os.path.exists(_PATH)
    except OSError:
        return False
