#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# deploy-all-parallel: parallel orchestrator for cf-scalable-web infrastructure
# deploys. Spawns each `make deploy-*` sub-target as soon as ITS specific
# dependencies have completed successfully — not via synchronous phase
# barriers. The critical-path tasks (image-builder → AMI build → compute)
# run in parallel with everything else that doesn't depend on them.
#
# Expected wall-clock: ~30-35 min, down from ~45-50 min for sequential
# deploy-allX. Dominated by the AMI bake (~25 min long pole); every other
# track fits underneath that shadow.
#
# Track definitions are declarative at the top of this file. Adding a new
# track (e.g., a future Node.js compute layer) is ONE entry in TRACKS plus
# a corresponding make target. The orchestration loop is track-agnostic.
#
# Per-track logs at /tmp/parallel-deploy.<pid>/<track>.log. Heartbeat
# refreshes a single-line status display every 15s using ANSI in-place
# updates. Milestones (state changes) scroll above the live status.
#
# Abort behavior: if any track fails, the orchestrator marks all pending
# tracks as aborted and stops triggering new work. **In-flight tracks are
# NOT killed** — CFN operations interrupted mid-flight leave stacks in
# bad states that need manual cleanup. We let them complete (success or
# failure) before exiting non-zero with a summary.
#
# Usage: scripts/deploy-all-parallel.py <env>

import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

# Anchor cwd to the project root regardless of how this is invoked,
# so the embedded `make ...` calls find the Makefile.
PROJECT_ROOT = Path(__file__).resolve().parent.parent
os.chdir(PROJECT_ROOT)

# ============================================================
# Track definitions — declarative dependency graph
# ============================================================
#
# Each track:
#   deps:  list of track keys this track waits for (must reach state=done or skipped)
#   cmd:   shell command (env name substitutes via {env})
#   label: 3-char display abbreviation (must be width 3 — pad with leading space if needed)
#   name:  human-readable description (shown in the live status block)
#
# To add a new track (e.g., future Node.js compute):
#   1. Add an entry below with deps + cmd + label + name
#   2. Add the make target the cmd references
#   3. Add the key to DISPLAY_ORDER
# Done — the orchestrator picks it up automatically.

TRACKS = {
    # Phase 0 — no dependencies, start at T=0
    "vpc": {"deps": [], "label": "vpc", "name": "VPC + subnets + security groups",
            "cmd": "make deploy-vpc ENV={env} VALIDATED=1"},
    "iam": {"deps": [], "label": "iam", "name": "IAM roles + instance profiles",
            "cmd": "make deploy-iam ENV={env} VALIDATED=1"},
    "app": {"deps": [], "label": "app", "name": "app-drupal (SSM params + secrets)",
            "cmd": "make deploy-app-drupal ENV={env} VALIDATED=1"},
    "ib":  {"deps": [], "label": " ib", "name": "image-builder stack + S3 configs",
            "cmd": "make deploy-image-builder ENV={env} VALIDATED=1 && "
                   "make upload-build-configs ENV={env} VALIDATED=1"},

    # AMI bake — long pole. Triggered as soon as image-builder stack exists.
    "ami": {"deps": ["ib"], "label": "ami", "name": "AMI bake (nginx/php74/php83)",
            "cmd": "make build-amis-if-needed ENV={env} VALIDATED=1"},

    # Phase 1 tier — VPC-dependent, mutually independent
    "str": {"deps": ["vpc"], "label": "str", "name": "storage (FSx + S3 buckets)",
            "cmd": "make deploy-storage ENV={env} VALIDATED=1"},
    "per": {"deps": ["vpc"], "label": "per", "name": "peering (deploy-host <-> workload)",
            "cmd": "make deploy-peering ENV={env} VALIDATED=1"},
    "db":  {"deps": ["vpc"], "label": " db", "name": "database (RDS PostgreSQL)",
            "cmd": "make deploy-database ENV={env} VALIDATED=1"},
    "cch": {"deps": ["vpc"], "label": "cch", "name": "cache (ElastiCache Valkey)",
            "cmd": "make deploy-cache ENV={env} VALIDATED=1"},

    # init-fsx-layout — needs storage (FSx available) AND peering (deploy-host can reach it)
    "fsx": {"deps": ["str", "per"], "label": "fsx", "name": "init FSx layout (/fsx/www + /fsx/nginx)",
            "cmd": "make init-fsx-layout ENV={env}"},

    # Compute — every other infrastructure piece must be ready
    "cmp": {"deps": ["ami", "db", "cch", "str", "iam", "fsx", "app"], "label": "cmp",
            "name": "compute (ALB+NLB+nginx+PHP ASGs)",
            "cmd": "make update-ami-params ENV={env} VALIDATED=1 && "
                   "make deploy-compute ENV={env} VALIDATED=1"},
}

# Track display order in the live status block (top-to-bottom)
DISPLAY_ORDER = ["vpc", "iam", "app", "ib", "ami", "str", "per", "db", "cch", "fsx", "cmp"]

# Single-character state codes (per design discussion 2026-05-24)
STATE_CHARS = {
    "pending": ".",
    "running": ">",
    "done":    "✓",
    "skipped": "-",
    "failed":  "✗",
    "aborted": "!",
}

HEARTBEAT_INTERVAL_SEC = 15
POLL_INTERVAL_SEC = 1

# ANSI escape sequences for in-place line updates
ANSI_CLEAR_LINE = "\r\x1b[K"


# ============================================================
# Track state
# ============================================================

@dataclass
class TrackState:
    name: str          # short key (e.g., "vpc")
    deps: List[str]
    label: str         # 3-char display code (e.g., "vpc")
    full_name: str     # human-readable description (e.g., "VPC + subnets...")
    cmd: str
    state: str = "pending"
    started_at: Optional[float] = None
    ended_at: Optional[float] = None
    exit_code: Optional[int] = None
    process: Optional[subprocess.Popen] = None
    log_path: Optional[Path] = None
    log_handle = None

    def duration_str(self) -> str:
        if self.started_at is None:
            return "  -  "
        end = self.ended_at if self.ended_at is not None else time.time()
        secs = int(end - self.started_at)
        return f"{secs // 60:>2}m{secs % 60:02d}s"


# ============================================================
# Helpers
# ============================================================

def fmt_secs(secs: float) -> str:
    secs = int(secs)
    return f"{secs // 60:>2}m{secs % 60:02d}s"


def fmt_elapsed(start: float) -> str:
    return fmt_secs(time.time() - start)


def waiting_on(track: TrackState, tracks: dict) -> List[str]:
    """List of dep labels still in non-terminal-success state."""
    return [tracks[d].label.strip() for d in track.deps
            if tracks[d].state not in ("done", "skipped")]


def format_track_line(track: TrackState, tracks: dict, start: float) -> str:
    """One line in the live status block — fixed-width columns so the block
    updates in place cleanly when state changes."""
    sc = STATE_CHARS[track.state]
    name_col = f"{track.full_name:<40}"  # 40-char description column

    if track.state == "pending":
        if not track.deps:
            tail = "queued"
        else:
            still_waiting = waiting_on(track, tracks)
            tail = f"waiting on: {', '.join(still_waiting)}" if still_waiting else "ready"
        return f"  {sc} {track.label} {name_col}                      {tail}"

    if track.state == "running":
        s_str = fmt_secs(track.started_at - start)
        run_str = track.duration_str()
        return f"  {sc} {track.label} {name_col} S:{s_str}  E:  -    ({run_str})  running"

    # done / skipped / failed / aborted
    if track.started_at is not None and track.ended_at is not None:
        s_str = fmt_secs(track.started_at - start)
        e_str = fmt_secs(track.ended_at - start)
        dur = track.duration_str()
        tail = ""
        if track.state == "failed":
            tail = f"  exit={track.exit_code} log:{track.log_path.name}"
        return f"  {sc} {track.label} {name_col} S:{s_str}  E:{e_str}  ({dur}){tail}"
    # aborted before start, or impossible state
    return f"  {sc} {track.label} {name_col}                      (never started)"


_last_block_lines = 0


def print_status_block(start: float, tracks: dict):
    """Erase the previously-printed status block and redraw it. The block
    is a single visual unit that updates in place — operator sees each
    track's lifecycle on the SAME line, no scrolling needed to find a
    given track's events."""
    global _last_block_lines

    if _last_block_lines > 0:
        # ANSI: move cursor up N lines, then clear from cursor to end of screen
        sys.stdout.write(f"\x1b[{_last_block_lines}A\x1b[J")

    lines = []
    lines.append(f"[T+{fmt_elapsed(start)}]  deploy-all-parallel  "
                 f"({sum(1 for t in tracks.values() if t.state == 'done')}/"
                 f"{len(tracks)} done)")
    for k in DISPLAY_ORDER:
        lines.append(format_track_line(tracks[k], tracks, start))

    out = "\n".join(lines) + "\n"
    sys.stdout.write(out)
    sys.stdout.flush()
    _last_block_lines = len(lines)


# ============================================================
# Track lifecycle
# ============================================================

def deps_satisfied(track: TrackState, tracks: dict) -> bool:
    """All deps reached a successful terminal state (done or skipped)."""
    return all(tracks[d].state in ("done", "skipped") for d in track.deps)


def any_dep_failed(track: TrackState, tracks: dict) -> bool:
    return any(tracks[d].state in ("failed", "aborted") for d in track.deps)


def start_track(track: TrackState, env: str, log_dir: Path):
    track.state = "running"
    track.started_at = time.time()
    track.log_path = log_dir / f"{track.name}.log"
    track.log_handle = open(track.log_path, "w")
    cmd = track.cmd.format(env=env)
    # shell=True for the && chains; new process group so we could SIGTERM
    # the whole pipeline if we ever decided to (we don't, per the abort
    # policy comment at the top — left here as the right knob to reach for
    # if that policy ever changes).
    track.process = subprocess.Popen(
        cmd, shell=True,
        stdout=track.log_handle, stderr=subprocess.STDOUT,
        preexec_fn=os.setsid,
    )


def check_completed(track: TrackState) -> bool:
    """Poll the subprocess. Returns True if the track JUST transitioned."""
    if track.state != "running":
        return False
    rc = track.process.poll()
    if rc is None:
        return False
    track.ended_at = time.time()
    track.exit_code = rc
    track.state = "done" if rc == 0 else "failed"
    track.log_handle.close()
    return True


def mark_pending_as_aborted(tracks: dict):
    for t in tracks.values():
        if t.state == "pending":
            t.state = "aborted"


# ============================================================
# Main
# ============================================================

def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <env>", file=sys.stderr)
        return 2

    env = sys.argv[1]

    # Pre-flight: validate CFN templates ONCE, fast-fail before any tracks start.
    print(f"Validating CloudFormation templates for ENV={env}...")
    rc = subprocess.run(["make", "validate", f"ENV={env}"]).returncode
    if rc != 0:
        print("Validation failed — aborting before any tracks start.", file=sys.stderr)
        return rc
    print()

    log_dir = Path(f"/tmp/parallel-deploy.{os.getpid()}")
    log_dir.mkdir(exist_ok=True)
    print(f"deploy-all-parallel  ENV={env}  logs={log_dir}/")
    print()
    print(f"State legend:")
    print(f"  .  pending     >  running    ✓  done")
    print(f"  -  skipped     ✗  failed     !  aborted (upstream failed or interrupted)")
    print()
    print(f"Each track updates in place on the same line. "
          f"Tail any log: tail -f {log_dir}/<track>.log")
    print()

    tracks = {
        name: TrackState(name=name, deps=meta["deps"], label=meta["label"],
                         full_name=meta["name"], cmd=meta["cmd"])
        for name, meta in TRACKS.items()
    }

    start_time = time.time()
    last_refresh = 0.0
    state_changed_this_iter = False
    abort_in_effect = False

    # Ctrl-C / SIGTERM: trigger abort cascade. Second hit exits.
    interrupt_count = 0

    def sig_handler(_sig, _frame):
        nonlocal interrupt_count, abort_in_effect
        interrupt_count += 1
        if interrupt_count == 1:
            mark_pending_as_aborted(tracks)
            abort_in_effect = True
        else:
            print()  # leave the block visible
            print("⚠ Second interrupt — exiting immediately.", file=sys.stderr)
            sys.exit(130)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    # Initial render so the operator sees the block right away
    print_status_block(start_time, tracks)
    last_refresh = time.time()

    # Orchestration loop
    while True:
        # Check completions
        state_changed_this_iter = False
        for t in tracks.values():
            if check_completed(t):
                state_changed_this_iter = True
                if t.state == "failed" and not abort_in_effect:
                    mark_pending_as_aborted(tracks)
                    abort_in_effect = True

        # Start newly-eligible tracks (no-op once abort is in effect, since
        # mark_pending_as_aborted already flipped every pending track to aborted)
        for t in tracks.values():
            if t.state == "pending":
                if any_dep_failed(t, tracks):
                    t.state = "aborted"
                    state_changed_this_iter = True
                elif deps_satisfied(t, tracks):
                    start_track(t, env, log_dir)
                    state_changed_this_iter = True

        # Refresh display: immediately on any state change, or every HEARTBEAT_INTERVAL_SEC.
        # The heartbeat refresh while nothing changes keeps running-track durations
        # ticking visibly so the operator can see the long-pole AMI track is still alive.
        if state_changed_this_iter or (time.time() - last_refresh >= HEARTBEAT_INTERVAL_SEC):
            print_status_block(start_time, tracks)
            last_refresh = time.time()

        # Termination: every track in a terminal state
        terminal = ("done", "skipped", "failed", "aborted")
        if all(t.state in terminal for t in tracks.values()):
            break

        time.sleep(POLL_INTERVAL_SEC)

    # Final render — overlays the previous in-place block one last time so
    # the operator sees the terminal state of every track. Then a blank line
    # so the summary text below scrolls separately from the block.
    print_status_block(start_time, tracks)
    print()
    print()
    print()

    done = [t for t in tracks.values() if t.state == "done"]
    skipped = [t for t in tracks.values() if t.state == "skipped"]
    failed = [t for t in tracks.values() if t.state == "failed"]
    aborted = [t for t in tracks.values() if t.state == "aborted"]

    if failed or aborted:
        print(f"FAILED after {fmt_elapsed(start_time)}.")
        if done:
            done_summary = ", ".join(
                f"{t.label.strip()}({t.duration_str().strip()})" for t in done)
            print(f"  ✓ completed: {done_summary}")
        if skipped:
            print(f"  - skipped:   {', '.join(t.label.strip() for t in skipped)}")
        if failed:
            print(f"  ✗ FAILED:")
            for t in failed:
                print(f"      {t.label.strip():>4} — exit {t.exit_code}, log: {t.log_path}")
        if aborted:
            print(f"  ! aborted (upstream failed or user-interrupt): "
                  f"{', '.join(t.label.strip() for t in aborted)}")
        print()
        print(f"To investigate: tail {log_dir}/*.log")
        print(f"Recovery:       most CFN deploys are idempotent — retry: "
              f"make deploy-allXX ENV={env}")
        return 1

    # Success
    print(f"✓ deploy-all-parallel complete: ENV={env}  ({fmt_elapsed(start_time)})")
    print()
    print(f"  Per-track wall-clock:")
    for t in tracks.values():
        print(f"    {t.label} {t.duration_str()}")
    print()
    print(f"  Logs preserved at: {log_dir}/")
    print()
    print(f"  Next step (optional): make install-drupal-full ENV={env}")
    return 0


if __name__ == "__main__":
    try:
        rc = main()
    finally:
        # Always end on a clean line
        sys.stdout.write("\n")
        sys.stdout.flush()
    sys.exit(rc)
