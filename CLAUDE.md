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
Rscript 03_create_open_response_data.R     # words + verbatims; seconds
Rscript 04_build_dashboard.R               # assemble the site; seconds
python3 preview.py                         # http://localhost:8901
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

Port 8899 is often already serving the wxdash site on this machine; `preview.py`
defaults to 8901.

**Preview through `preview.py`, not `python3 -m http.server`.** The plain
server sends no cache headers, so the browser keeps `index.html` and goes on
requesting the previous build's `engine.js?v=…`. A rebuild then appears to have
done nothing, and the page shows stale text no amount of rebuilding fixes —
which is how a caption that had already been corrected was still doubling its
show condition on screen. `preview.py` sends `Cache-Control: no-cache`.

## The rule that matters most

**Read the instruments. Do not write a parser.** This was attempted here first
and reached about 90%, with the last 10% silently wrong — which in a reference
table is worse than obviously wrong. Extracting text from the `.docx` is
scripted; deciding what the text means is not.

The procedure is `01_variable_reference/.claude/skills/fusion-variable-reference/SKILL.md`.
Adding an instrument means following it, not improvising. Its worked examples
are the traps that actually occur in these two documents.

The same rule governs theming the open responses, under its own skill —
`open-response-themes` — for the same reason: a keyword pass produces a column
that looks coded and is wrong exactly where it matters.

## The variable reference

`01_variable_reference/variable_reference.csv` — 152 rows, 20 columns, one per
variable, carrying each question as it was actually asked. Two companions matter as much
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
- `asked_if` / `asked_if_plain` — the show condition twice over. The sheet
  keeps the document's `fusion_know = 1`; the dashboard prints the plain
  clause, because a caveat a reader cannot decode is not a caveat. `02` halts
  on a condition with no plain text, since the caption would otherwise print
  "Not everyone was asked:" and stop.
- `battery` — which select-all set a `checkbox_item` belongs to. Declared, not
  inferred from the shared stem, so editing one item's wording cannot split a
  battery in two.

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
interval hitting a group where every respondent gave the same answer — four
such cells, all real (no Black or Midwest respondent picked "Other" in the
risk, cost and information batteries). `02` counts and prints them at the end
so the warnings have a number beside them. Verified 2026-08-21: every
single-response group sums to 100%, and no interval is missing or inverted.

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

Response option labels are **never truncated**. `wrapTickLabel` wraps at word
boundaries with no line cap, and `draw()` sizes the canvas from the resulting
line counts — each category gets whichever is taller, the room its label needs
or the room its bars need, with no maximum. A capped height would be truncation
by another route, since Chart.js drops ticks to fit. The three `fusion_reg_choice`
proposals run to 539 characters and differ only in their later clauses: trimmed
to a common prefix they read as the same answer three times.

Response order is declared in two places and inferred in none. `02` sorts each
group's rows by the instrument's own option order, because response codes are
character and grouping alone sorts them as strings — that puts 10 between 1 and
2 on every eleven-point scale and rotates the income follow-ups, whose codes run
6-10. The front end then passes `categoryOrder` from `v.options` to
`groupedBarChart`, because the chart otherwise orders categories by first
appearance, and a response nobody in the first group gave lands at the end of
the axis. Both were live bugs, fixed 2026-08-21; leave both in place.

`IDEOL_GROUP` and `GCC_GROUP` are derived in `derive_groups()`. The ideology
banding (1–3 liberal, 4 moderate, 5–7 conservative) follows the instrument's
own labels; collapsing seven categories to three is a judgment, made there once
rather than in the front end.

## Table order is survey order

The question table opens in `variable_reference.csv`'s own row order, carried
through `02` as `ref_row` and used to sort the catalog. That order is FU26's
sequence — the order respondents met the questions — with each FU25-only block
placed where FU25 asked it rather than appended at the end: `fusion_know_dev`
after `und_fusion_tech`, `rskben_fusion` in the slot FU26 gives
`fusion_risk_ben`, the investment and argument run between the support block
and the trust block, and the two nine-item impression batteries straight after
the trust battery they extend.

A select-all battery takes the position of its **first item**, so
"Where have you heard about fusion energy?" sits tenth, beside `fusion_know`,
rather than at the end of the table with the other batteries. Reordering the
sheet's rows is how the table is reordered; nothing else depends on row order.

## What reaches the dashboard

`02` builds a question file for a reference row only when it is a `question` or
`checkbox_item` with two or more options **and** `question_focus != "background"`.
That last clause holds back 14 items — gender, race, income and its four
follow-ups, education, party, ideology, partisan strength, lean, and trust in
government. They are splits, not findings.

The filter is keyed on the reference, not on a list in the script, so putting an
item back means re-classifying it in `variable_reference.csv` — which is also
where anyone would look to find out why it is missing. The `worry_*` items were
re-classified from `background` to `fusion` on 2026-08-21 for exactly this
reason: issue concern is a substantive attitude, not a personal characteristic,
and the first pass had them wrong.

## Split-sample items are one plot per arm

Seven questions were asked in more than one form and pooled until 2026-08-21:
`fusion_host` (10 or 50 miles), `labs_trust` / `labs_trust_risk` /
`labs_trust_bene` (a generic laboratory or Lawrence Livermore), and
`reg_path_balance` / `reg_path_support` / `fusion_reg_choice` (three regulatory
proposals). Each arm is now estimated on its own and the reader picks between
them from a menu inside the chart card. There is deliberately no pooled option:
pooling averages across the treatment, which is the thing the flag warns about.

`arm_variable` in the reference names the randomization behind a question;
`01_variable_reference/arms.csv` maps each wave's raw assignment values to an
arm id, a label and an order. Both are declared rather than matched, because
`rand_lab` records the same arm as "US national laboratories…" in 2025 and
"U.S. national laboratories…" in 2026 — string equality would split one arm in
two and neither half would say so. `02` halts on an assignment value that
arms.csv does not map, on a respondent with no arm, and on an arm id whose
label differs between waves.

`govspend_fusion_exp_a` and `_b` are *not* handled this way: FU25 released them
as one column per arm, so they are already separate questions.

Every question file carries `splits` and `summaries` keyed by arm, with a
single `"all"` key where there is no experiment, so the front end has one code
path rather than two. Note that `jsonlite` writes `NULL` as `{}`, which is
truthy in JavaScript — `arms` is emitted as `NA` when absent, and the engine
tests `Array.isArray` besides.

## Batteries are one plot each

The 38 `checkbox_item` rows become 5 charts, grouped by their `battery` column.
A battery's chart is not a distribution: each item is its own proportion — the
share of the people shown the battery who ticked that box — estimated with
`survey_mean` one item at a time rather than normalised against the others. The
bars do not sum to 100, the question file says `multi_response: true`, and the
caption repeats it. Verified 2026-08-21 against a plain weighted share computed
straight from the CSVs: agreement to rounding.

Items are ranked by share, most-picked at the top — the instrument's own order
is arbitrary, and was randomized on screen anyway. Two things keep that honest.
The ranking is taken from the Everyone distribution and then used for every
split, so changing the split re-colours the chart rather than reshuffling it.
And the residual option sinks to the bottom whatever its share: "Other (please
specify)" is not a finding that beat the options below it, it is where the rest
went. Which option is residual is read from the wording and cross-checked
against the `_oth` naming convention, so a wave that breaks either stops the
build.

`02` halts if a battery spans more than one stem or topic, if its items
disagree about which waves asked them, or if they disagree about who was shown
them — one denominator cannot serve items resting on different samples. That
last check is why the missingness pattern within each battery was verified
before any of this was built.

## Open responses (03)

`03_create_open_response_data.R` builds the qualitative page: word
associations, the three why-items, and the questions people would put to a
fusion expert. It **counts and screens, it does not summarise**. Words are
counted as typed - "clean" and "clean energy" stay separate, because deciding
they are one word is coding - and verbatims are carried whole. There is no
coding frame, and a build script inventing one would put words in respondents'
mouths with nothing on the page to say so.

Three things in it are easy to undo:

- **A word's share is of respondents, not of entries.** Everyone gave up to
  three words, so counting entries would let one person's repetition read as
  agreement. A word mentioned twice by the same person counts once.
- **`word_stoplist.csv`** holds the 24 explicit non-answers ("none", "not
  sure", "n/a", bare question marks) - 440 of 7,056 entries. Versioned rather
  than a regex in code, because whether "not sure" is a non-answer or a real
  association is a judgment someone may want to revisit. "unknown" is *not* on
  it: 43 people meant it.
- **The identifier screen is a net, not a review.** It catches emails, URLs,
  phone numbers, long digit runs and @handles, holds them back, and writes
  `held_back_for_review.csv`. It currently catches nothing across 3,580
  responses - verified against probes, so that is a real result and not a
  broken pattern. It cannot catch "I live in New York City", which is in the
  data. A human has to read these before the site is published anywhere
  public.

The three why-items show **both** gate variables beside each response —
`new_fusion` (fusion power plants) and `fusion_host` (a facility nearby) —
because a person reached the question through either one and the two often
disagree: 940 of the 1,630 "unsure" rows have them landing in different bands.

Both sit on the same 1-7 scale, and the instrument labels only its ends. They
are banded into five using those two words and nothing else — 1 "Strongly
opposes", 2-3 "Opposes", 4 "Neither", 5-6 "Supports", 7 "Strongly supports" —
because "Opposes" is as much as can be said about a 3 without inventing a label
the respondent never saw. `SUPPORT_BANDS` names the order so the filter menus
read in it; alphabetical would put "Strongly opposes" between "Opposes" and
"Supports".

They also carry a caution: the gate includes `fusion_host`, which randomized
the distance to 10 or 50 miles, and 52 responses mention the distance they were
shown.

## Themes on open responses

`01_variable_reference/themes.csv` holds one primary theme per response, keyed
on `case_id`; `theme_labels.csv` holds the roster and the order the filter menu
reads in. Coded so far: `oppose` (403 responses, 15 themes), `support` (377, 15) and
`uncertain` (1,630, 17). An item
with no coding gets no theme column; nothing is guessed.

The procedure is
`01_variable_reference/.claude/skills/open-response-themes/SKILL.md`, with an
export script and a coverage checker beside it. Coding a new item means
following it, not improvising.

**Coded in three passes, by reading.** Draft the themes from reading the whole
set; assign one to each response by reading it; then read each theme's members
together and fix what landed wrong. That third pass is not optional — it is
what caught "Scared" sitting under *No reason given* while "Scary" sat under
*Safety*, and a response filed under *Prefer other energy sources* that in fact
dismissed solar too.

A keyword rule would be worse than useless here. "I don't know what fusion is,
it sounds dangerous, and I don't want it near my house" contains the trigger
words for four themes; which one it *is* depends on which the writer leads with
and dwells on, and only reading tells you that.

**One theme per response**, the concern it leads with or dwells on. Many raise
two. A response coded *Health effects* may well also mention property values;
the coding records the dominant concern, not the only one.

`case_id` is the join key and is **dropped before writing**: it identifies a
person and has no business in a published file. `03` halts if any response in a
coded item has no theme — a partly-coded item would let the filter hide
whatever was missed.

## Pages

Six, declared in `03`'s `config$pages`:

| id | component | nav |
|---|---|---|
| `home` | `fu_landing` | Home |
| `explore` | `explore` | Public → Explore Survey Data |
| `public-qual` | `open_responses` | Public → Explore Open Responses |
| `sme-survey` | `placeholder` | SMEs → Explore Survey Data |
| `sme-qual` | `placeholder` | SMEs → Explore Qualitative Data |
| `about` | `static_page` | About |

A page carrying `nav_group` folds into a dropdown at the position of its
group's first member; that machinery came from the fork untouched. The survey
page keeps the id `explore` rather than taking a name matching its new label,
because `#explore?q=…` links are already in circulation.

`placeholder` pages say what will go there and what is missing. Filling one in
means writing its component and swapping `component` in `03` — the page, its
nav position and its landing-page blurb are already in place. Note that the
public qualitative data **exists**: the verbatims (`fusion_oppose_why`,
`fusion_support_why`, `fusion_question`, `comments`) are in the reference and
in the data, and are excluded from `02` only because they carry no response
distribution. Nothing is coded or summarised yet, which is what that page says.

`fu_landing` is adapted from wxdash's `wx_landing`: same hero, live flagship
chart and directory, with the map alternative link gone and the meta line
reading this project's `meta.json`. Its chart reads `v.splits[armKey]` like the
explorer does, so a split-sample flagship would still draw.

## The front end

`site/` is hand-edited source, forked 2026-08-21 from wxdash's
`11_dashboard/site/`. Only `explore` and `static_page` survive; the map
explorer, landing page and quiz are gone with Leaflet and the map half of the
PDF export. Class prefix is `fu-` where the original uses `wx-`, and the
globals are `FU_BUILD` / `FU_BUNDLE` / `FU_ENGINE_LOADED`.

The table, chart, error-bar and PDF code is otherwise close enough to wxdash's
that a fix in either is worth carrying to the other. Two additions here that are not upstream, both on `dataTable`: columns accept a
`render(row)` hook, used to show the shared stem above the item — without it a
row of the select-all batteries reads "Don't know", which is not a question —
and `filter: "select"` turns a column's filter box into a menu built from the
values present, which is what the Topic column uses. Menu filters match
exactly; text filters match on substring, or picking "Regulation" would also
select any topic merely containing the word.

Wave codes are internal. `FU25` is the instrument's name for the fielding and
appears in the variable reference's `instruments` column and in `00_paths.R`;
everything a reader sees says 2025. `02` emits `asked$year` rather than
`asked$wave` for the question files, the Asked column and `meta.json`.

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
gap halfway through 79 charts.
