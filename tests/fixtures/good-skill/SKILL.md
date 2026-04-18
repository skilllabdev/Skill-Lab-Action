---
name: csv-reconciliation
description: Reconcile two CSV files by a shared key column, emitting adds/removes/changes as three separate CSVs. Use when the user asks to diff, compare, or reconcile tabular data where rows are identified by a stable key.
---

# CSV Reconciliation

## When to use this skill

Trigger when the user asks to:

- Compare two CSV exports from the same source (e.g., "what changed between yesterday's and today's users export?")
- Produce a diff of tabular data keyed by a column (user_id, sku, email, etc.)
- Audit a migration by comparing pre- and post-migration extracts

Do **not** use this skill when:

- The files are not tabular (use `file-diff` instead)
- There is no stable key column — reconciliation requires a join key
- The user wants a human-readable summary, not row-level outputs

## Inputs

1. `before.csv` — baseline file
2. `after.csv` — new file
3. `key` — name of the column shared by both files (defaults to the first column if omitted)

## Procedure

1. Validate both files have a header row and the named `key` column exists in each.
2. Load rows into dictionaries indexed by key. If duplicate keys exist in either file, abort with a clear error listing the first three duplicates.
3. Compute three sets:
   - `added`: keys present in `after` but not `before`
   - `removed`: keys present in `before` but not `after`
   - `changed`: keys in both where any non-key column differs
4. Emit `added.csv`, `removed.csv`, `changed.csv` in the working directory. For `changed.csv`, include one row per changed key with columns: `key`, `column`, `before`, `after` (tall format — easier to review).
5. Print a one-line summary: `N added, N removed, N changed`.

## Error handling

- **Missing file**: report which of the two files is missing; do not proceed.
- **Key column not found**: list the column names you did find and stop.
- **Encoding errors**: retry once with `utf-8-sig`; if that fails, report the offending byte offset.
- **Empty output**: still write the three files (as headers-only) so downstream tooling doesn't break on missing paths.

## Notes

- Use `csv.DictReader` with `newline=''` — this handles embedded newlines inside quoted fields.
- Never load both files fully into memory if they exceed ~1M rows; switch to a sorted-merge approach and note this in the summary.
- Preserve the column order from `after.csv` when writing `added.csv` and `changed.csv`.
