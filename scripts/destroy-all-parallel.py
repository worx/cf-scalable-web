#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# destroy-all-parallel: parallel orchestrator for cf-scalable-web tear-downs.
# Symmetric counterpart to deploy-all-parallel.py — same display framework,
# same orchestration loop, inverted dependency graph.
#
# Critical path: cmp → (db | str) → vpc = ~10 min wall clock, down from
# ~20-25 min sequential. About half the destroy time recovered.
#
# Track definitions are declarative at the top of this file. Adding a new
# track is one entry in TRACKS plus a corresponding make target.
#
# Tolerance: every track's command appends `|| true` so "stack already
# gone" is treated as success (matching the existing destroy-all
# behavior). A genuine destroy failure (bucket not empty, ENI stuck,
# etc.) will show in the per-track log file — operator can retry, since
# destroy is naturally idempotent.
#
# Usage: scripts/destroy-all-parallel.py <env> [--yes]
#   --yes  Skip the "are you sure?" prompt (equivalent to CONFIRMED=yes).

import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

PROJECT_ROOT = Path(__file__).resolve().parent.parent
os.chdir(PROJECT_ROOT)

# ============================================================
# Track definitions — declarative reverse-dependency graph
# ============================================================

TRACKS = {
    # Tier 1 — start at T=0 (no CFN imports gate these)
    "cnx": {"deps": [], "label": "cnx", "name": "nginx ASG + instances",
            "cmd": "make destroy-compute-nginx ENV={env} CONFIRMED=yes || true"},
    "cph": {"deps": [], "label": "cph", "name": "PHP ASGs (74 + 83) + instances",
            "cmd": "make destroy-compute-php ENV={env} CONFIRMED=yes || true"},
    "ib":  {"deps": [], "label": " ib", "name": "image-builder + its AMIs",
            "cmd": "make destroy-image-builder ENV={env} CONFIRMED=yes || true"},
    "umn": {"deps": [], "label": "umn", "name": "unmount FSx on deploy-host",
            "cmd": "make unmount-deploy-host-fsx || true"},
    # cch + db have NO CFN imports from compute — independent stacks. Hoist to T=0.
    "cch": {"deps": [], "label": "cch", "name": "cache (ElastiCache Valkey)",
            "cmd": "make destroy-cache ENV={env} CONFIRMED=yes || true"},
    "db":  {"deps": [], "label": " db", "name": "database (RDS PostgreSQL)",
            "cmd": "make destroy-database ENV={env} CONFIRMED=yes || true"},

    # Tier 2 — load balancers (after their ASG consumers are gone)
    "alb": {"deps": ["cnx"], "label": "alb", "name": "compute ALB + target groups",
            "cmd": "make destroy-compute-alb ENV={env} CONFIRMED=yes || true"},
    "nlb": {"deps": ["cph"], "label": "nlb", "name": "compute NLB + target groups",
            "cmd": "make destroy-compute-nlb ENV={env} CONFIRMED=yes || true"},

    # Tier 3 — storage split: FSx needs compute gone (no mounters) + umn done;
    # S3 needs image-builder gone (it consumes the image-builder bucket).
    "fxs": {"deps": ["cnx", "cph", "umn"], "label": "fxs", "name": "storage FSx OpenZFS",
            "cmd": "make destroy-storage-fsx ENV={env} CONFIRMED=yes || true"},
    "s3":  {"deps": ["ib"], "label": " s3", "name": "storage S3 buckets",
            "cmd": "make destroy-storage-s3 ENV={env} CONFIRMED=yes || true"},
    "iam": {"deps": ["cnx", "cph", "ib"], "label": "iam", "name": "IAM roles + instance profiles",
            "cmd": "make destroy-iam ENV={env} CONFIRMED=yes || true"},
    "per": {"deps": ["cnx", "cph"], "label": "per", "name": "peering (deploy-host <-> workload)",
            "cmd": "make destroy-peering ENV={env} || true"},

    # Tier 4 — VPC must be ABSOLUTE last. Any lingering ENI hangs the delete.
    "vpc": {"deps": ["cnx", "cph", "alb", "nlb", "ib", "cch", "db", "fxs", "s3", "iam", "per"],
            "label": "vpc", "name": "VPC + subnets + security groups",
            "cmd": "make destroy-vpc ENV={env} CONFIRMED=yes || true"},
}

DISPLAY_ORDER = ["cnx", "cph", "alb", "nlb", "umn", "ib", "s3", "cch", "db", "fxs", "iam", "per", "vpc"]

STATE_CHARS = {
    "pending": ".",
    "running": ">",
    "done":    "✓",
    "skipped": "-",
    "failed":  "✗",
    "aborted": "!",
}

HEARTBEAT_INTERVAL_SEC = 2
POLL_INTERVAL_SEC = 1


# ============================================================
# Track state
# ============================================================

@dataclass
class TrackState:
    name: str
    deps: List[str]
    label: str
    full_name: str
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
    return [tracks[d].label.strip() for d in track.deps
            if tracks[d].state not in ("done", "skipped")]


def format_track_line(track: TrackState, tracks: dict, start: float) -> str:
    sc = STATE_CHARS[track.state]
    name_col = f"{track.full_name:<40}"

    if track.state == "pending":
        if not track.deps:
            tail = "queued"
        else:
            still = waiting_on(track, tracks)
            tail = f"waiting on: {', '.join(still)}" if still else "ready"
        return f"  {sc} {track.label} {name_col}                      {tail}"

    if track.state == "running":
        s_str = fmt_secs(track.started_at - start)
        run_str = track.duration_str()
        return f"  {sc} {track.label} {name_col} S:{s_str}  E:  -    ({run_str})  running"

    if track.started_at is not None and track.ended_at is not None:
        s_str = fmt_secs(track.started_at - start)
        e_str = fmt_secs(track.ended_at - start)
        dur = track.duration_str()
        tail = ""
        if track.state == "failed":
            tail = f"  exit={track.exit_code} log:{track.log_path.name}"
        return f"  {sc} {track.label} {name_col} S:{s_str}  E:{e_str}  ({dur}){tail}"

    return f"  {sc} {track.label} {name_col}                      (never started)"


_last_block_lines = 0


def print_status_block(start: float, tracks: dict):
    global _last_block_lines

    if _last_block_lines > 0:
        sys.stdout.write(f"\x1b[{_last_block_lines}A\x1b[J")

    lines = []
    done_count = sum(1 for t in tracks.values() if t.state == "done")
    lines.append(f"[T+{fmt_elapsed(start)}]  destroy-all-parallel  "
                 f"({done_count}/{len(tracks)} done)")
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
    return all(tracks[d].state in ("done", "skipped") for d in track.deps)


def any_dep_failed(track: TrackState, tracks: dict) -> bool:
    return any(tracks[d].state in ("failed", "aborted") for d in track.deps)


def start_track(track: TrackState, env: str, log_dir: Path):
    track.state = "running"
    track.started_at = time.time()
    track.log_path = log_dir / f"{track.name}.log"
    track.log_handle = open(track.log_path, "w")
    cmd = track.cmd.format(env=env)
    track.process = subprocess.Popen(
        cmd, shell=True,
        stdout=track.log_handle, stderr=subprocess.STDOUT,
        preexec_fn=os.setsid,
    )


def check_completed(track: TrackState) -> bool:
    if track.state != "running":
        return False
    rc = track.process.poll()
    if rc is None:
        return False
    track.ended_at = time.time()
    track.exit_code = rc
    # Note: every cmd has `|| true` appended, so rc=0 even on stack-not-found.
    # Only non-zero exit here indicates a genuine make-target failure.
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

def confirm_or_exit():
    """Prompt the operator unless --yes is on the command line."""
    if "--yes" in sys.argv:
        return
    print()
    print("⚠ This will DESTROY ALL stacks (compute, db, cache, storage,")
    print("  image-builder, iam, peering, vpc) for the specified env.")
    print()
    try:
        resp = input("Type 'yes' to confirm: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        print("Aborted by user.")
        sys.exit(1)
    if resp != "yes":
        print(f"Got '{resp}', not 'yes' — aborting.")
        sys.exit(1)


def main() -> int:
    # Strip optional flags from argv to find the env
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print(f"Usage: {sys.argv[0]} <env> [--yes]", file=sys.stderr)
        return 2

    env = args[0]

    confirm_or_exit()

    log_dir = Path(f"/tmp/parallel-destroy.{os.getpid()}")
    log_dir.mkdir(exist_ok=True)
    print()
    print(f"destroy-all-parallel  ENV={env}  logs={log_dir}/")
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
    abort_in_effect = False

    interrupt_count = 0

    def sig_handler(_sig, _frame):
        nonlocal interrupt_count, abort_in_effect
        interrupt_count += 1
        if interrupt_count == 1:
            mark_pending_as_aborted(tracks)
            abort_in_effect = True
        else:
            print()
            print("⚠ Second interrupt — exiting immediately.", file=sys.stderr)
            sys.exit(130)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    print_status_block(start_time, tracks)
    last_refresh = time.time()

    while True:
        state_changed = False
        for t in tracks.values():
            if check_completed(t):
                state_changed = True
                if t.state == "failed" and not abort_in_effect:
                    mark_pending_as_aborted(tracks)
                    abort_in_effect = True

        for t in tracks.values():
            if t.state == "pending":
                if any_dep_failed(t, tracks):
                    t.state = "aborted"
                    state_changed = True
                elif deps_satisfied(t, tracks):
                    start_track(t, env, log_dir)
                    state_changed = True

        if state_changed or (time.time() - last_refresh >= HEARTBEAT_INTERVAL_SEC):
            print_status_block(start_time, tracks)
            last_refresh = time.time()

        terminal = ("done", "skipped", "failed", "aborted")
        if all(t.state in terminal for t in tracks.values()):
            break

        time.sleep(POLL_INTERVAL_SEC)

    print_status_block(start_time, tracks)
    print()

    done = [t for t in tracks.values() if t.state == "done"]
    failed = [t for t in tracks.values() if t.state == "failed"]
    aborted = [t for t in tracks.values() if t.state == "aborted"]

    if failed or aborted:
        print(f"FAILED after {fmt_elapsed(start_time)}.")
        if done:
            done_summary = ", ".join(
                f"{t.label.strip()}({t.duration_str().strip()})" for t in done)
            print(f"  ✓ destroyed: {done_summary}")
        if failed:
            print(f"  ✗ FAILED:")
            for t in failed:
                print(f"      {t.label.strip():>4} — exit {t.exit_code}, log: {t.log_path}")
        if aborted:
            print(f"  ! aborted (upstream failed or user-interrupt): "
                  f"{', '.join(t.label.strip() for t in aborted)}")
        print()
        print(f"To investigate: tail {log_dir}/*.log")
        print(f"Recovery:       destroy is naturally idempotent — retry: "
              f"make destroy-allXX ENV={env} --yes")
        return 1

    print(f"✓ destroy-all-parallel complete: ENV={env}  ({fmt_elapsed(start_time)})")
    print()
    print(f"  Per-track wall-clock:")
    for t in tracks.values():
        print(f"    {t.label} {t.duration_str()}")
    print()
    print(f"  Logs preserved at: {log_dir}/")
    print()
    print(f"  Note: operator-owned resources (Route 53 sub-zone, parent zone")
    print(f"        records, etc.) are untouched by automation by design.")
    print(f"        See docs/DNS-SETUP.md if you also want to unpublish the env's")
    print(f"        Route 53 alias: make unpublish-dns ENV={env}")
    return 0


if __name__ == "__main__":
    try:
        rc = main()
    finally:
        sys.stdout.write("\n")
        sys.stdout.flush()
    sys.exit(rc)
