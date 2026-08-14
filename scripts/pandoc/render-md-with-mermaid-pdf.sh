#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# ============================================================
# render-md-with-mermaid-pdf.sh
#
# Purpose:  Render a Markdown file that contains ```mermaid fences
#           into a PDF. Pre-processes each ```mermaid``` block into
#           a PNG via mermaid-cli (mmdc, via npx — no global install
#           needed), rewrites the MD to reference the PNGs, then
#           pipes to pandoc + xelatex.
#
#           Complement to scripts/pandoc/render-pdf.sh, which handles
#           standard MD without Mermaid. This script is for MD authored
#           for Obsidian/GitHub where diagrams are embedded Mermaid.
#
# Usage:    scripts/pandoc/render-md-with-mermaid-pdf.sh <path-to-md> [output.pdf]
#           Default output: same directory, same basename, .pdf extension.
#
# Requires: pandoc, npx (Node.js), xelatex.
#           mermaid-cli is auto-fetched by npx on first run — no
#           persistent install needed but the first invocation
#           downloads a chromium-headless bundle (~200 MB, cached).
#
# Created:  2026-08-14
# ============================================================

set -euo pipefail

MD_FILE="${1:-}"
if [ -z "$MD_FILE" ] || [ ! -f "$MD_FILE" ]; then
  echo "Usage: $0 <path-to-md> [output.pdf]" >&2
  echo "  Input must exist. Output defaults to <basename>.pdf next to input." >&2
  exit 2
fi

BASE=$(basename "$MD_FILE" .md)
DIR=$(dirname "$MD_FILE")
OUT="${2:-$DIR/$BASE.pdf}"

# Scratch workspace — all intermediate files live here, wiped at end
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Input:  $MD_FILE"
echo "Output: $OUT"
echo "Work:   $WORK"

# ============================================================
# Step 1: extract Mermaid blocks + render each to PNG
# ============================================================
# awk state machine: when we see ```mermaid, capture lines into a
# per-block temp file. When we see the closing ```, close and mark
# the block index in the output MD with a placeholder image ref.
PROCESSED="$WORK/processed.md"
awk -v work="$WORK" '
BEGIN { in_mermaid=0; idx=0 }
/^```mermaid[ \t]*$/ {
  in_mermaid=1
  idx++
  outf = work "/mermaid-" idx ".mmd"
  next
}
in_mermaid && /^```[ \t]*$/ {
  in_mermaid=0
  close(outf)
  print "![](" work "/mermaid-" idx ".png){ width=90% }"
  next
}
in_mermaid { print > outf; next }
{ print }
' "$MD_FILE" > "$PROCESSED"

# ============================================================
# Step 2: render each .mmd to PNG using mermaid-cli via npx
# ============================================================
BLOCK_COUNT=$(ls "$WORK"/mermaid-*.mmd 2>/dev/null | wc -l | tr -d ' ')
echo "Found $BLOCK_COUNT mermaid block(s)."

if [ "$BLOCK_COUNT" -gt 0 ]; then
  # Puppeteer config to skip sandbox (needed on macOS often)
  cat > "$WORK/puppeteer.json" <<'PUPP'
{
  "args": ["--no-sandbox"]
}
PUPP

  for mmd in "$WORK"/mermaid-*.mmd; do
    png="${mmd%.mmd}.png"
    echo "  rendering: $(basename "$mmd") -> $(basename "$png")"
    npx --yes @mermaid-js/mermaid-cli \
      -i "$mmd" \
      -o "$png" \
      -b white \
      -w 1600 \
      -p "$WORK/puppeteer.json" \
      >/dev/null 2>&1 || {
        echo "ERROR: mmdc failed on $mmd" >&2
        exit 1
      }
  done
fi

# ============================================================
# Step 3: pandoc → PDF via xelatex
# ============================================================
echo "Running pandoc..."
PREAMBLE="$(dirname "$(readlink -f "$0")")/preamble.tex"
PREAMBLE_ARG=()
if [ -f "$PREAMBLE" ]; then
  PREAMBLE_ARG=(--include-in-header "$PREAMBLE")
fi

pandoc "$PROCESSED" \
  --from markdown+pipe_tables+task_lists+auto_identifiers \
  --to pdf \
  --pdf-engine=xelatex \
  --toc --toc-depth=3 \
  --variable geometry:margin=1in \
  --variable mainfont=Charter \
  --variable monofont=Menlo \
  --variable fontsize=11pt \
  --variable colorlinks=true \
  --variable linkcolor=blue \
  --variable urlcolor=blue \
  --variable documentclass=article \
  "${PREAMBLE_ARG[@]}" \
  --resource-path=".:$WORK:$DIR" \
  -o "$OUT"

echo ""
echo "✓ Rendered $(du -h "$OUT" | awk '{print $1}') -> $OUT"

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
