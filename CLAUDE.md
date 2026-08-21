# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Orientation for `fusion_dash`: what the pipeline does, and the decisions in it
that are easy to undo by accident. Read this before touching anything here.
`README.md` is the fuller account of the project; this file is the parts that
bite.

R in this repository follows the IPPRA house style — two-space indent, native
`|>`, 80 columns, guards before the step they protect, comments that give the
reason rather than the history. The full guide is `~/.claude/ippra-r-style.md`.

## Commands

```sh
Rscript 02_create_question_data.R          # srvyr statistics; seconds
Rscript 03_build_dashboard.R               # assemble the site; seconds
python3 -m http.server --directory outputs/03_site 8901
```

There is no `01` script — `01_variable_reference/` is a directory holding the
codebook, the instruments and the procedure that produced it. Nothing generates
`variable_reference.csv`; it is written by reading.

Re-extract instrument text (only when adding a wave):

```sh
python3 01_variable_reference/.claude/skills/fusion-variable-reference/scripts/extract_instrument_text.py \
  01_variable_reference <scratch_dir>
python3 01_variable_reference/.claude/skills/fusion-variable-reference/scripts/check_coverage.py \
  01_variable_reference/variable_reference.csv <scratch_dir>
```

`check_coverage.py` must report `missing 0` for every wave. `extra` is expected
and must be only randomization variables, the consent item and the
please-specify boxes — see the skill.

Port 8899 is often already serving the wxdash site on this machine. Use 8901.

## The rule that matters most

**Read the instruments. Do not write a parser.** This was attempted here first
and reached about 90%, with the last 10% silently wrong — which in a reference
table is worse than obviously wrong. Extracting text from the `.docx` is
scripted; deciding what the text means is not.

The procedure is `01_variable_reference/.claude/skills/fusion-variable-reference/SKILL.md`.
Adding an instrument means following it, not improvising. Its worked examples
are the traps that actually occur in these two documents.

## The variable reference

`01_variable_reference/variable_reference.csv` — 152 rows, one per variable,
carrying each question as it was actually asked. Two companions matter as much
as the sheet:

- `NOTES.md` — what still needs a second pair of eyes, grouped by what to do
  about it. Instrument errors are recorded there and in the `notes` column,
  **never corrected in the sheet**: the sheet records what the documents say.
- the skill directory — the procedure and its two scripts.

Its judgment columns are easy to confuse:

- `experimental` — what the respondent *read* varied. Order-only randomization
  (`RANDOM ORDER`, `randomize block`) is **not** experimental; that would sweep
  in every battery in the survey. A piped answer is not a randomization either.
- `question_focus` — `fusion` or `background`, judged on the question rather
  than the section it sits in.
- `topic` — the dashboard's first column, and the only judgment column the
  reader ever sees.

**Two wave columns, not two rows.** `variable` is the canonical name;
`column_fu25` and `column_fu26` are the data columns. That is what absorbs the
biggest trap in this project: **FU25's instrument was updated to FU26's naming
after FU25 was fielded**, so fifteen variables are `fusion_source_tv` in the
document and `fusion_source_1` in the data. Anything that joins FU25 on
instrument names loses those items and reports success.

Watch the option separator: it is ` | `, so a pipe inside an option label makes
`response_options` unsplittable. Unlabelled scale points are the bare number
(`0 = No trust | 1 | 2 | … | 10 = Complete trust`), and `02` turns those into
`"0 - No trust"`, `"1"`, … so a partly-labelled scale still reads as a scale.

## Statistics live in 02, presentation in 03

`03_build_dashboard.R` computes **nothing**: every percentage and interval is
`02`'s output carried over verbatim, so the published site cannot disagree with
what was computed. A calculation added to the builder gives that up. If you
need a new number, it belongs in `02`.

`02` uses `survey_prop(proportion = TRUE, vartype = "ci")` whether or not the
front end is showing intervals, so the point estimate a reader sees never
changes when they tick the box.

Expect `glm.fit: algorithm did not converge` warnings. They are the logit
interval hitting a group where every respondent gave the same answer — five
such cells, all real (nobody in that group picked "Other"). `02` counts and
prints them at the end so the warnings have a number beside them. Verified
2026-08-21: every group sums to 100%, no interval is missing or inverted.

## Splits are declared once

The roster lives in the `splits` tribble at the top of `02`, and reaches the
front end through `splits.json` → `config.groupings`. wxdash declares its
thirteen splits four times across two languages and nothing catches a missed
edit; this project does not repeat that.

Three things in that block are easy to undo:

- **The demographics come from the vendor's derived columns** (`Age`, `Gender`,
  `Race`, `Education`, `Income`, `Region`, `Metro`, `Party_ID`, `Vote_2024`),
  not FU26's self-reported `gend` / `race` / `edu` / `income` / `party` items.
  FU25 has no self-reported demographics at all. Switching to the FU26 items
  would drop 2025 from every demographic split without saying so.
- **`group_order`** fixes the order of ordinal splits. Without an entry there
  the front end sorts labels alphabetically, which scrambles income, education
  and ideology. A group in the data that is missing from `group_order` stops
  the build.
- **`source`** on a split suppresses the tautology of splitting a question by
  itself — `ideol` by Ideology, `gcc` by Climate change belief. Both drew a
  single bar at 100% in every group before it existed.

`IDEOL_GROUP` and `GCC_GROUP` are derived in `derive_groups()`. The ideology
banding (1–3 liberal, 4 moderate, 5–7 conservative) follows the instrument's
own labels; collapsing seven categories to three is a judgment, made there once
rather than in the front end.

## The front end

`site/` is hand-edited source, forked 2026-08-21 from wxdash's
`11_dashboard/site/`. Only `explore` and `static_page` survive; the map
explorer, landing page and quiz are gone with Leaflet and the map half of the
PDF export. Class prefix is `fu-` where the original uses `wx-`, and the
globals are `FU_BUILD` / `FU_BUNDLE` / `FU_ENGINE_LOADED`.

The table, chart, error-bar and PDF code is otherwise close enough to wxdash's
that a fix in either is worth carrying to the other. One addition here that is
not upstream: `dataTable` columns accept a `render(row)` hook, used to show the
shared stem above the item — without it a row of the select-all batteries reads
"Don't know", which is not a question.

The engine renders only precomputed values. Keep it that way; it is what makes
the "cannot disagree with 02" property inspectable rather than asserted.

Two things that will bite when driving it headlessly:

- Serve over HTTP. `fetch()` is blocked on `file://`, so every data file
  returns nothing and the page sits on the loading screen. Its watchdog will
  tell you exactly what failed after three seconds.
- No WebGL is needed (Chart.js on a 2D canvas, no map), so no
  `--enable-unsafe-swiftshader`. Routing is on the hash, and per-question state
  is in the query string: `?q=<variable>&grouping=<split>&ci=1&scheme=grey`
  goes straight to a view.

`jsonlite`'s `auto_unbox = TRUE` turns a length-one vector into a bare string.
`02` wraps `waves` in `as.list()` for exactly this reason — a question asked in
one wave arrived as `"FU26"`, and the front end calls `.join()` on it. Anything
new that the front end iterates needs the same treatment.

## Adding a wave

1. Drop the `.docx` in `01_variable_reference/` and the weighted CSV in `data/`.
2. Add a row to `waves` in `00_paths.R` and a `column_fu27` column to the sheet.
3. Follow the skill's **Adding a newly fielded wave** section — read the new
   instrument, compare wording variable by variable, update `NOTES.md`.
4. Re-run `02` and `03`.

The demographic split columns must exist in the new wave under the same names;
`02` checks all of them before computing anything rather than discovering a
gap halfway through 126 questions.
