-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 The Worx Company
-- Author: Kurt Vanderwater <kurt@worxco.net>
--
-- table-widths.lua — Pandoc Lua filter for print-friendly tables.
--
-- Purpose: force pandoc-emitted tables to use proportional-width wrapping
-- columns when rendering to PDF via xelatex. Without this, pipe tables in
-- Markdown that don't have explicit column-width hints get emitted as
-- LaTeX `longtable` with fixed-width columns that don't wrap — wide cells
-- then overflow into adjacent columns, producing the "column 2 prints
-- over column 3" artifact.
--
-- Behavior: for every Table in the AST, assign each column 1/N of the
-- effective line width (equal-share proportional). This triggers pandoc's
-- p{...} column emission in LaTeX, which enables word-wrapping inside
-- cells. Alignment stays at AlignDefault (left).
--
-- Called by: scripts/pandoc/render-pdf.sh (via `pandoc --lua-filter=...`).
--            Used by the `make print-doc` Makefile target.
--
-- To customize per-table: set explicit column widths in the Markdown
-- source (via pandoc's grid-table syntax with header sizing). Any table
-- with explicit widths in the source will still get overwritten by this
-- filter — remove the filter for that render if selective control is
-- needed.
--
-- Created: 2026-08-03
function Table(t)
  local n = #t.colspecs
  if n > 0 then
    for i = 1, n do
      t.colspecs[i] = { pandoc.AlignDefault, 1.0 / n }
    end
  end
  return t
end
