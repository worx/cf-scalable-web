#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# render-pdf.sh — Render a Markdown file to print-ready PDF via pandoc + xelatex.
#
# Purpose: convert docs/plans/*.md (or any Markdown file) to a PDF that's
# ready for print or iPad markup. Bundles the fixes that produce good
# output out of the box on macOS:
#   - Lua filter (scripts/pandoc/table-widths.lua) — forces proportional
#     column widths in tables so wide cells wrap instead of overflowing
#     adjacent columns.
#   - LaTeX preamble (scripts/pandoc/preamble.tex) — maps Unicode
#     arrows/checkmarks to LaTeX equivalents so macOS system fonts
#     (Charter, etc.) don't emit tofu for characters they don't ship.
#   - TOC, colored links, sensible margins, Menlo for code, Charter for body.
#
# Usage:  render-pdf.sh <path-to-md> [output-pdf-path]
#         Default output: /tmp/<basename>.pdf
#
# Env overrides:
#   FONT       Main font (default: Charter). Must be installed on macOS.
#   FONTSIZE   Body font size (default: 11pt).
#   MARGIN     Page margin (default: 1in).
#   OPEN       Set to 'no' to skip auto-open (default: open in Preview).
#
# Requires: pandoc (brew install pandoc), xelatex (brew install --cask basictex).
#
# Called by: Makefile target `print-doc`.
#
# Created: 2026-08-03

set -euo pipefail

MD_FILE="${1:-}"
if [ -z "$MD_FILE" ]; then
  echo "Usage: $0 <path-to-md> [output-pdf-path]" >&2
  exit 2
fi
if [ ! -f "$MD_FILE" ]; then
  echo "ERROR: $MD_FILE not found" >&2
  exit 2
fi

# Resolve to absolute path so pandoc reports it clearly if there's an error
MD_ABS=$(cd "$(dirname "$MD_FILE")" && pwd)/$(basename "$MD_FILE")

# Determine output path: explicit second arg, or /tmp/<basename>.pdf
OUT_FILE="${2:-/tmp/$(basename "${MD_FILE%.md}").pdf}"

# Env-overridable knobs
FONT="${FONT:-Charter}"
FONTSIZE="${FONTSIZE:-11pt}"
MARGIN="${MARGIN:-1in}"

# Locate the helper files (Lua filter + LaTeX preamble) relative to THIS script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUA_FILTER="$SCRIPT_DIR/table-widths.lua"
HEADER_TEX="$SCRIPT_DIR/preamble.tex"

for helper in "$LUA_FILTER" "$HEADER_TEX"; do
  if [ ! -f "$helper" ]; then
    echo "ERROR: helper file not found: $helper" >&2
    exit 2
  fi
done

# Tool preconditions
for tool in pandoc xelatex; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not installed." >&2
    case "$tool" in
      pandoc)  echo "  Install: brew install pandoc" >&2 ;;
      xelatex) echo "  Install: brew install --cask basictex   # ~100MB; adds /Library/TeX/texbin to PATH in a new shell" >&2 ;;
    esac
    exit 2
  fi
done

echo "Rendering $MD_ABS"
echo "     → $OUT_FILE"
echo "  font: $FONT $FONTSIZE  margin: $MARGIN"
echo ""

pandoc "$MD_ABS" \
  --pdf-engine=xelatex \
  --toc --toc-depth=3 \
  --lua-filter="$LUA_FILTER" \
  --include-in-header="$HEADER_TEX" \
  -V geometry:margin="$MARGIN" \
  -V documentclass=article \
  -V fontsize="$FONTSIZE" \
  -V mainfont="$FONT" \
  -V monofont="Menlo" \
  -V colorlinks=true \
  -V linkcolor=blue \
  -V urlcolor=blue \
  -V toccolor=blue \
  --metadata date="Rendered $(date +'%Y-%m-%d')" \
  -o "$OUT_FILE"

echo ""
echo "✓ PDF ready: $OUT_FILE"

if [ "${OPEN:-yes}" != "no" ]; then
  open "$OUT_FILE"
fi
