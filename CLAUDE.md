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

  Every one of the 30 conditions was checked against both waves on
  2026-08-22 — for each, does the item hold a value exactly when the
  condition is true? All 30 hold with **no respondent answering an item the
  condition excludes**, except the three why-items, where the document
  describes neither wave as fielded. Those three carry `asked_if` as the
  document writes it and `asked_if_plain` as the survey actually behaved,
  with the divergence spelled out in `notes`. They are the only rows where
  the two columns are not renderings of each other; do not "fix" that.
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

## Every chart carries the R that rebuilds it

The explore page has a **Download R code** button in the toolbar, beside
*Download chart (PDF)*. It saves a script that rebuilds *that* plot — that
question, that split, that arm — from the released CSVs and nothing else.

**Download only; there is no on-page viewer.** A collapsible panel showing the
code under the chart was built and then removed: someone who wants the script
wants it in their editor, not in a scrolling box. `.fu-toolbar-actions` groups
the two download buttons, because `.fu-pdf-btn` takes `margin-left: auto` and
two of them loose in the row each push themselves to the right edge, ending up
at opposite ends of it.

**One script per (arm, split), not one template.** 1,099 of them. A script for
a specific plot names that plot's variables and no others: splitting by gender
should not make a reader read a roster of thirteen grouping columns, and it
should say `Gender`, not `.data[[SPLIT]]`. Three rules the generated code
follows, and they are the point of it:

- **no helper functions** — every step is a call the reader can run on its own;
- **column names written where they are used**, never through `.data[[ ]]`;
- **only the columns this plot needs** — no grouping column at all under
  Everyone.

Splits differ by more than a name, which is why a template would not do: some
need a derived column written out, some an order, Everyone needs neither.

**`02` generates them**, not the front end. The script that did the computing
writes the code that reproduces it — the same property that makes `04` carry
numbers rather than calculate them. The engine does a lookup and composes
nothing.

**`02` then runs them and compares.** `verify_r_code()` evaluates a script
against the same CSVs a reader would download and checks its estimates against
the rows being written to the question file — matching on *labels*, so a
levels/labels pairing that had drifted would not slip through. The build halts
on a mismatch and prints the count. `verify_pairs()` picks the coverage: every
question, every shape the generator can produce (no grouping, a plain column, a
derived column, the wave), and every arm at least once — 277 of the 1,099,
which is all the distinct code paths. It has caught two real defects: an arm
join naming `year` while joining on `survey_year`, and `strwrap()` breaking a
line *inside* a quoted response label and silently changing the string.

**The scripts live in `data/rcode/<id>.json`, fetched on the first download
and cached.** `fusion_reg_choice` carries three arms by twelve splits — 174 KB
— and code nobody asked for has no business loading with every chart. The
question file just carries `has_r_code`, which is also what hides the button
for a question with no script.

Two things the generated code makes visible that the pipeline only describes:
`fusion_source_online = fusion_source_2` in every battery script, and
`filter(distance == "50")` against `filter(rand_dist == "50")` in every
split-sample one.

## Splits are declared once## Splits are declared once

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
  `held_back_for_review.csv`. It currently catches nothing across the corpus -
  verified against probes, so that is a real result and not a broken pattern.
  It cannot catch "I live in New York City", which is in the data. The reading
  that catches meaning is the content review below; the screen runs alongside
  it, not instead of it.

## The content review

Every verbatim is read before it is published. Two files record the outcome,
and `03` will not build an item without them:

- `verbatim_review.csv` — one row per item: how many responses were in the
  corpus when it was read, and when. **`03` compares that count against what
  it is about to publish and halts if they differ.** That check is the point.
  A corpus that grew — a new wave, a widened routing rule, a reversed
  withhold — contains responses nobody has read, and without the check
  "reviewed" is a claim in a commit message rather than a property of the
  build. Re-read the item and update the count; do not just bump the number.
- `verbatim_withheld.csv` — one row per withheld response: `item`, `case_id`,
  and the reason in prose. Declared in a file rather than a rule in code
  because whether a response crosses the line is a judgement someone may want
  to overturn, and they can only overturn what they can see. `03` halts on a
  withhold naming a response the corpus does not contain, since a stale
  withhold hides nothing and masks a real one.

Reviewed 2026-08-22, all 3,360 responses. **Two withheld, both from
`uncertain`**, both for content directed at groups of people rather than at
fusion energy: one objecting to a facility because of the racial groups it
would bring to the respondent's neighbourhood, one asserting that immigrants
admitted under the previous administration would want to cause a nuclear
disaster. The second is the borderline call and is marked as such in the file.

Nothing else was withheld, and the line is deliberately narrow. Ordinary
political opinion stays in, including sharp opinion about named public
figures; so does mild profanity, conspiracy theory, and criticism of the
survey itself. Location detail stays in at region level — the corpus names
Three Mile Island, Hanford, Oak Ridge, Los Alamos, the Mojave and one small
Florida town — because none of it identifies a person on its own. Withholding
opinions because they are unwelcome would misrepresent the corpus, which is
the same failure as a keyword coding frame.

The count of what was withheld is stated on the page beside every item, the
same rule the identifier screen follows: a response the reader will never know
existed unless the number is there.

**The three why-items are restricted to one routing rule across both waves.**
The waves gated them differently — FU25 asked "why do you oppose" of anyone
negative on *either* the power-plants question or the facility-nearby
question, FU26 only of people negative on both — so FU25's oppose corpus
included people who back fusion and object only to the siting. `00_paths.R`
declares `why_item_kept()`, FU26's rule; `03` and the theme skill's
`export_for_coding.R` both apply it, which is why it lives in the shared file
rather than in either script. It withholds 220 of FU25's 297 oppose
responses, and `03` prints the number rather than letting a total quietly
shrink. `support` and `uncertain` lose nothing. Full account in `NOTES.md`.

The three why-items show **both** gate variables beside each response —
`new_fusion` (fusion power plants) and `fusion_host` (a facility nearby) —
because a person reached the question through either one and the two often
disagree: 940 of the 1,630 "unsure" rows have them landing in different bands.

Both sit on the same 1-7 scale, and the instrument labels only its ends. They
are banded into three on **the survey's own cut points** — 1-2 "Opposes", 3-5
"Neither for nor against", 6-7 "Supports" — because those are the boundaries
the routing itself uses, and they are the only ones the instrument asserts.
`SUPPORT_BANDS` names the order so the filter menus read in it; alphabetical
would put "Neither for nor against" first.

A five-band scheme cutting at 1 / 2-3 / 4 / 5-6 / 7 was in place until
2026-08-22. It was invented here rather than read off the routing, and it
crossed the gate boundaries both ways: a 5 read "Supports" and a 3 read
"Opposes" where the survey had treated both as middle ground. The unsure item
then showed 395 responses supporting on both gate columns and 118 opposing on
both — every one caused by a 5 or a 3, and every one a contradiction the
coding did not contain. **Bands that disagree with the routing make the
routing look broken.** Do not re-cut them without checking the routing first.

They also carry a caution: the gate includes `fusion_host`, which randomized
the distance to 10 or 50 miles, and 52 responses mention the distance they were
shown.

## Themes on open responses

`01_variable_reference/themes.csv` holds one primary theme per response, keyed
on `case_id`; `theme_labels.csv` holds the roster and the order the filter menu
reads in. Coded so far: `oppose` (183 responses, 14 themes), `support` (377, 15) and
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

## The theme distribution

The qualitative page draws a ranked bar per theme above the verbatims it
summarises, with a **Split by** control and click-to-filter. Four things in it
are easy to undo:

- **`03` computes it, on the rows that are actually published** — after the
  routing restriction, the content withhold and the identifier screen. The
  engine re-scales the bars but never re-computes them. Computing them in the
  front end from `v.rows` would give the same answer today and quietly stop
  the first time a row is held back; the withheld *Local impact on my area*
  response is why that item reads 75 and not 76.
- **Unweighted**, and the caption says so. The percentage is the count over
  its group, nothing more. These are the only bars on the site that are not a
  population estimate — the word associations directly above them are
  weighted, and so is every percentage on the explore page — so the caption
  names the difference rather than leaving a reader to trip over it. It
  changes little either way: weighting moved nothing by more than 1.4 points
  on the two large items. The count sits on every bar so a two-response theme
  cannot be read as a rate.
- **Theme order is 03's, in every split** — frequency across everyone, *No
  reason given* last. Changing the split recolours the chart rather than
  reshuffling it, the same rule the battery charts follow, so a reader
  comparing groups does not lose the row they were looking at. Bars also share
  one scale across the whole split.
- **A group under 30 responses is not drawn**, and the caption names it with
  its size. Eight people who oppose fusion plants outright and still landed in
  the unsure item are eight real people, but "12.5%" beside a group of 1,300
  invites a comparison that eight cannot support. They stay in the table.

Splits offer themselves only where the data holds more than one group of that
size, which is why `ask` has no year menu (FU26 only) and why `oppose` and
`support` have no gate-band menu: under FU26's routing rule everyone in them
sits on the same side of both gates, so the split would be a single bar at
100%. That is the same tautology the `source` column suppresses on the explore
page, arrived at for free.

Clicking a theme filters the table below and moves its Theme menu; using the
menu lights the bar. `dataTable` gained `setFilter` / `getFilter` and an
`onFilterChange` hook for this, which is the third thing on it that is not
upstream in wxdash.

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
