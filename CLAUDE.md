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
Rscript 02_create_question_data.R          # public srvyr statistics; ~90s
Rscript 03_create_open_response_data.R     # public words + verbatims; seconds
Rscript 04_create_sme_data.R               # expert survey + comparisons; seconds
Rscript 05_create_sme_open_response_data.R # expert words + verbatims; seconds
Rscript 06_build_dashboard.R               # assemble the site; seconds
python3 preview.py                         # http://localhost:8901
```

`05` reads `03`'s output rather than recounting the public's words, and `06`
reads everything: the numbering is the run order, and each script does one
survey's one job. `00_open_responses.R` holds the rules the two qualitative
pages share.

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

`01_variable_reference/variable_reference.csv` — 152 rows, 23 columns, one per
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

## Statistics live in 02 and 04, presentation in 05

`06_build_dashboard.R` computes **nothing**: every percentage and interval is
`02`'s output carried over verbatim, so the published site cannot disagree with
what was computed. A calculation added to the builder gives that up. If you
need a new number, it belongs in `02`.

`02` uses `survey_prop(proportion = TRUE, vartype = "ci")` whether or not the
front end is showing intervals, so the point estimate a reader sees never
changes when they tick the box.

**The caption under a chart is a `{token}` template**, authored in `06` and
filled by the engine from the question file, so no sentence there can state a
figure the data does not carry. `06` halts on a token the front end does not
fill — it would otherwise print as a gap in the sentence, which reads as a
missing number rather than as a bug. Both surveys carry their own set, running
in parallel: *the bars show the weighted distribution of responses* against
*the raw (unweighted) distribution of responses*. `variable_line` is a
separate paragraph from `provenance` because the variable code is a reference,
not part of the sentence about how the survey was weighted.

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

**The expert survey has them too**, generated by `04` — 50 scripts, one per
(question, split), against `data/sme/rcode/`. The page picks its directory
from `page.rcode_dir`; hard-coding `data/rcode` would have the expert page
offer a download that rebuilds someone else's chart. There are no arms, since
the expert survey split-sampled nothing, and **every one of the 50 is verified
rather than a sample** — the coverage argument that justifies checking 277 of
the public side's 1,416 does not arise at this size.

Three shapes there, keyed on the question file's own `value_kind`: a
distribution (`survey_prop`), one proportion per item for a select-all
(`survey_mean(item == "1")`), and a mean for the rankings and the typed
allocations (`survey_mean(as.numeric(item))`, a normal interval rather than a
logit one). Each generated script says which it is doing and why the bars do
or do not sum to 100. It also states in its header that the design uses a
weight of 1 for shape rather than as a claim that the numbers generalise —
the same caveat the page carries, in the file a reader takes away.

`00_rcode.R` holds what both generators must do identically: `r_quote()`,
`r_vec()`, `r_title()`, the cached reader and `verify_r_code()`. The
generators themselves are **not** shared — waves, arms and weights against one
unweighted fielding is too much difference for one function — but `r_vec()`
exists because `strwrap()` broke a line inside a quoted response label, and a
second copy of that lesson would eventually lose it.

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
front end through `splits.json` → `config.groupings`.

**`category` groups the menu** into Demographics, Politics & Values, Science &
Energy and Survey. Sixteen options in one flat list is a list a reader scans
rather than one they read. The engine builds an `<optgroup>` per **consecutive
run** of one category rather than by lookup, so the roster's order is the
menu's order, headings included — which also means a category appearing twice
would render as two headings with the same name, and `06` halts on that. A
roster whose splits carry no category renders flat; the expert page's five do. wxdash declares its
thirteen splits four times across two languages and nothing catches a missed
edit; this project does not repeat that.

Three things in that block are easy to undo:

- **The demographics come from the vendor's derived columns** (`Age`, `Gender`,
  `Race`, `Education`, `Income`, `Region`, `Metro`, `Party_ID`, `Vote_2024`),
  not FU26's self-reported `gend` / `race` / `edu` / `income` / `party` items.
  FU25 has no self-reported demographics at all. Switching to the FU26 items
  would drop 2025 from every demographic split without saying so.
- **`phrase`** reads after "by" in a chart caption — *"the weighted
  distribution of responses by age group"* — so it is a noun phrase rather
  than a label, and it is not the label. `Race/Ethnicity` is labelled that and
  phrased "race and ethnicity"; `AWARE_GROUP` is labelled "Fusion awareness"
  and phrased "whether they had heard of fusion before". The `dropped` clause
  deliberately does **not** use it: "reported no whether they had heard of
  fusion before" is what that costs.
- **`group_order`** fixes the order of ordinal splits. Without an entry there
  the front end sorts labels alphabetically, which scrambles income, education
  and ideology. A group in the data that is missing from `group_order` stops
  the build.
- **`source`** on a split suppresses the tautology of splitting a question by
  itself — `ideol` by Ideology, `gcc` by Climate change belief, and now
  `nuclear_support`, `univ_trust`, `fusion_know` and `worry_enviro` by the four
  splits built from them. Both of the first two drew a single bar at 100% in
  every group before it existed.
- **`waves`** records where a split can be built. Everything is `both` except
  `NUCLEAR_GROUP`, which rests on an item FU26 asked and FU25 did not. A
  wave-limited split measures its own denominator and its own `dropped` count
  against that wave, so the caption reads "1,243 US adults … in the 2026 wave"
  rather than counting 2,444 and reporting 1,200 as dropped — which would read
  as attrition instead of coverage. Its generated R script reads that wave
  only, for the same reason: deriving the grouping from a column the other
  file does not have is an error, not an empty column, and the reproduction
  check caught exactly that.

**The four splits the expert survey pointed at.** `NUCLEAR_GROUP`,
`SCITRUST_GROUP`, `AWARE_GROUP` and `ENVCON_GROUP` exist because they are the
strongest correlates of support in the data, and the findings deck now links
straight into them — a reader told that views on nuclear power are the single
best predictor can cut any question by it in one click. Bands are thirds of
the scale, not thirds of the sample, so the cut points still mean the same
thing in a wave whose distribution has moved.

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
`checkbox_item` with two or more options, `question_focus != "background"`
**and** `explore_chart == "yes"`. The focus clause holds back 14 items — gender, race, income and its four
follow-ups, education, party, ideology, partisan strength, lean, and trust in
government. They are splits, not findings.

**`explore_chart` holds back three more**: `word_1_feel`, `word_2_feel` and
`word_3_feel`. It is a different judgement from `question_focus` and exists so
the two do not have to be conflated — those three *are* substantive fusion
attitudes rather than background, and the sheet should go on saying so. They
are not charted because the rating refers to a word the respondent typed and
stored in another column, so a distribution of the ratings alone says nothing
about what was rated. The valence still reaches a reader as the colour of each
word on the qualitative page, and `04`'s word-feeling comparison still uses it.

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
on `case_id`; `theme_labels.csv` holds the roster, the order the filter menu
reads in, and whether the page draws each theme at all. Coded so far:
`oppose` (183 responses read, 174 drawn), `support` (377 / 317), `uncertain`
(1,630 / 1,481) and `ask` (1,170 / 1,083); on the expert side
`misunderstood` (122 / 122) and `change` (115 / 113). An item with no coding gets no
theme column; nothing is guessed.

**`published` is what makes those two numbers differ**, and it is a column in
the sheet rather than a filter in code, because whether a response answered
the question is a judgement someone may want to overturn and they can only
overturn what they can see. Five themes are marked `no`:

- *No reason given* on the three why-items and *No question offered* on `ask`
  — "I don't know", "na", "Nothing", "No thanks". These are the verbatim
  equivalent of the entries `word_stoplist.csv` keeps out of the word counts,
  and counting them as a theme lets "gave no reason" read as a reason.
- *Not a question - a statement about fusion* on `ask`, which is **not** a
  non-answer. Those 16 responses are substantive and most of them are
  criticism of the survey itself. They are held back because that item is
  questions for a fusion expert and these are not questions, not because they
  are unwelcome — the line the content review draws is elsewhere and stays
  there. Putting them back is one cell in the sheet.

The expert sheet carries the same column, with *No answer given* on `change`
marked `no` — one response, "I don't know". `check_published_column()` and
`unpublished_caution()` live in `00_open_responses.R` so both pages hold the
same line, and a label sheet without the column stops the build rather than
quietly drawing everything.

The drop happens **after** the review check and the content withhold, so
`reviewed` still means the whole corpus was read. The count is printed beside
every item that has one — the same rule the identifier screen and the content
withhold follow — and the caption distinguishes how many answered from how
many are drawn, because "1,083 people answered" when 1,170 did would be wrong
in the one direction that flatters the item.

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
- **Theme order is 03's, in every split** — frequency across everyone.
  Changing the split recolours the chart rather than reshuffling it, the same
  rule the battery charts follow, so a reader comparing groups does not lose
  the row they were looking at. Bars also share one scale across the whole
  split. The themes marked `published = no` are not in the order because they
  are not on the chart.
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

## The expert survey

`data/FU26_SME_data.csv` — 153 people identified as having relevant expertise,
fielded once in 2026. It is a **different survey, not a third wave**, and three
things follow:

- **It has no weights and no `weight` column.** A purposive sample of experts
  is not a sample of a population. Every percentage on the expert page is a
  plain count of the experts who answered. `04` builds the design with weights
  of 1 so the interval and the file shape match the public side — which is what
  lets one `explore` component draw both — but that is convenience, not a claim
  that the numbers generalise. The page's caption and tooltip say so, and they
  are page-level overrides precisely because the global ones say "weighted to
  represent US adults", which would be a lie here.
- **It gets its own sheet**, `sme_variable_reference.csv`, with its own
  `SME_NOTES.md`. Not a `column_sme` on the public sheet: **26 SME columns
  share a name with a public variable and only five ask the same question.**
  The three risk/cost/benefit batteries reuse the public item names for a
  different stem — the public was asked which *they* would most want to
  understand, experts which *non-experts* most need to understand. One sheet
  would put those in one row and invite exactly the comparison that is wrong.
- **The comparisons are declared, never matched on name.** `compare_to` and
  `compare_kind` in the SME sheet name the five same-question pairs and the
  twelve prediction pairs. `04` computes the public side of each from the same
  files `02` reads and then **checks it against what `02` published**, halting
  on a mismatch — a comparison that disagreed with the public page would be
  worse than none.

## The findings deck

`sme-compare` is not a stack of charts — it has none. It is twelve cards you
slide left and right: a headline, the numbers, a paragraph saying what they
mean, and links to the explore pages. Nine small bar charts were what made an
earlier version read like a dataset rather than like findings.

**Two parts, and the distinction is the point.** Running them together is what
made the page hard to follow:

| | what was asked | what a gap means |
|---|---|---|
| Part one | both groups answered the same question, in the same words | a difference of view — nobody is wrong |
| Part two | experts were asked to predict what the public said | a mistake, and the public column is the answer |
| Part three | a parallel question put to each side from its own position | a mismatch of agenda |

Part three is the three risk/cost/benefit batteries — the pair `NOTES` warns
about, where the two surveys reuse the same column names for different stems.
That is not a comparison to make by accident, so the eighteen pairs are
declared in the SME sheet as `compare_kind = "agenda"` with a `compare_label`.

**Every card prints both question stems in full**, quoted from the two
reference sheets by `pub_q()` / `sme_q()` rather than retyped, so a card cannot
claim wording the instrument does not have. What the block is called says which
part you are on: part one leads *"The same question, put to both groups"* and
its two quotes differ only in "US" against "United States"; parts two and three
lead *"What each side was asked"* and the pivotal phrase is marked — *"What
percentage of respondents do you think"*, or *"would you most want to
understand"* against *"non-experts most need to understand"*. The difference
between the two questions is the finding; describing it in a caption and hoping
the reader takes it on trust is what made the section hard to follow.

The marked phrase is a literal substring of the stem and the engine splits on
it, so a highlight that stops matching renders the question whole rather than a
rewritten one. Part three's expert stems share a two-sentence preamble across
all three batteries, cut at "Which of the following"; `question_only()` stops
the build if that sentence is not there rather than printing the preamble as
though it were the question. On the correlates card the second row is the public
support question the ranking is scored against, quoted like the first rather
than described — how it is scored is the note's job.

Nine of the eighteen options are worded differently between the surveys — two
of them substantively, the public's waste option saying "radioactive material
management" against the expert's "waste management and decommissioning". Those
rows carry a dagger, and a disclosure under the figures prints both wordings
in full. `compare_label` exists because neither survey's wording can label
both columns.

Each part opens with a divider card that says so, every card is banded and
tinted by part (blue, amber, green) and tagged in its kicker, because a reader
landing mid-deck needs to know which kind of card they are on.

Figures sit in a three-column grid rather than a chart or a `<table>`: the row
label wraps freely while the number columns stay locked, and the larger of each
pair is marked so the shape of a comparison is legible without reading every
figure. `fu-compare-1` drops the second column for the two cards that carry one
series, so an empty slot never reads as a missing number.

**The grid is on `.fu-compare`, and each row is `display: contents`**, so every
row shares one set of columns. Putting the grid on the row instead lets each row
size its own label column and the figures stop lining up down the card. The
label column is `minmax(0, max-content)` — the longest label and no more — so
the numbers sit beside what they describe; `1fr` pushes them to the far edge of
a wide card, where the eye has to travel to pair a number with its label. Prose
carries no width cap: the lede and the quoted stems run the full width of the
card.

- **`04` writes the headlines and the paragraphs**, from the same values the
  figures show. A
  sentence assembled in the front end, or typed into the builder, would go
  stale the first time the data moved — "by 12 points" is computed, not
  written. `scales::ordinal` turns a rank into "3rd" so even that follows the
  table.
- **The public side of every card is checked against `02`** in one pass over
  eight questions before any card is written. The cards collapse those
  distributions into bands, and a collapse can only be trusted if the thing
  being collapsed matches what the explore page shows.
- **The blind-spot and false-lead cards pick themselves.** They are the
  largest positive and negative gaps between expert rank and actual rank in
  the correlates table, taken with `slice_max`/`slice_min` rather than named,
  so they follow the data if it changes.
- **The current card is tracked, not re-derived.** Deriving it from scroll
  position on every button press looks tidier and is wrong: a second click
  landing while the smooth scroll is still travelling reads a position already
  past the current card and advances two. The index is the source of truth for
  the buttons; a scroll the reader performs writes back to it once the strip
  settles. Card offsets come from `getBoundingClientRect`, not `offsetLeft` —
  the latter is relative to the nearest positioned ancestor rather than the
  strip, so comparing it against `scrollLeft` read one card early.
- **Sliding is CSS scroll-snap**, not an animation loop: the buttons, the dots
  and the arrow keys all just scroll the strip, so a touch swipe and a
  trackpad work without three code paths. The strip sets `align-items:
  flex-start` — a flex row otherwise makes every card as tall as the tallest,
  which left the short ones with a screen of empty space beneath them.
- **Links use `?q=<variable>#<page>`**, which is the app's own deep-link form:
  the router reads the hash and `getParam` reads the query string.

**The eleventh comparison is computed, not carried.** `fusion_sup_cor` asks
experts to name the strongest correlates of public support, and the correlates
are computable — so `04` computes them: η, bias-corrected, of `new_fusion`
across the groups of each factor. One measure for all ten so they rank against
each other; it assumes no ordering (race and awareness have none) and catches
a curve (age and ideology need that); the correction matters because the
factors run from two categories to eleven.

`sme_correlates.csv` declares which public measure stands for each expert
factor, because half of them are the vendor's derived columns rather than
reference variables. Two carry an `alternative_column` that is computed and
shown beside the first: partisanship scores 0.05 on `Party_ID` and 0.15 on
`ideol`, environmental concern 0.00 on `worry_enviro` and 0.10 on `gccrsk`.
Showing only the primary number would make a measure-sensitive result look
settled.

Three response types the public pipeline never had, and the question file
carries `value_kind` so the front end labels the axis rather than assuming a
percentage:

| `value_kind` | what the bar is | where |
|---|---|---|
| `share` | share of experts who gave that answer | most items |
| `mean_rank` | mean placing, **lower is higher** | the three drag-to-rank blocks |
| `mean_pct` | mean of the percentage they typed | the two allocations that sum to 100 |

Five splits: Everyone, years in fusion work, and **sector, field and role,
whose groups overlap**. The six experience bands collapse to three because 153
respondents do not support six.

The three professional splits are select-all, so a respondent can be in more
than one group of the same split. **They are, and the caption says so** — a
person who named two fields is counted in both, each group is estimated on its
own members, and the bars inside a group still sum to 100 because each group
is its own denominator. What is given up is that the groups no longer
partition the sample.

**Assigning each person to one group was tried against the data and rejected.**
Rarest-wins — send a multi-picker to their least common category — is fine for
sector, where 135 of 153 named only one. On field it moves plasma physics from
76 people to 12 and leaves an eleven-person *Mechanical engineering* group of
whom eight are plasma physicists; on role it leaves a seventeen-person
*Facility operations* group, every one of whom named another role too. The
rule assumes the rare pick is the person's real identity, which holds when the
picks are near-exclusive and fails when they are simultaneous. Overlapping
invents nothing instead.

`01_variable_reference/sme_split_groups.csv` declares which checkbox items make
up each collapsed group, so re-cutting the buckets is an edit to a sheet. Three
things in the implementation are easy to undo:

- **`frame_for()` stacks the rows**, once per group a respondent belongs to.
  `group_by(group)` downstream then sees each person once within each of their
  groups, so the estimate and its interval are right for every group.
- **`summarise_group()` counts people, not rows** (`sme_id`). On a stacked
  frame `nrow()` reports more experts than answered.
- **`dropped` is measured against `d`, not against the split's frame.** The
  split's frame holds only people who have a group, so measuring there makes
  it zero by construction and hides the experts who named no sector at all.

The sheet's `split` column is **renamed to `split_id` on read**: `split` is
also the generator's argument name, and inside `filter()` the data mask wins —
the column would shadow the argument and every split would match every row.

The roster reaches the front end as `04`'s own `splits.json`, read by `06`
rather than retyped. It was declared in both until these three made that a
third place to forget.

`groupedBarChart` keeps a single `activeChart` so the explore page cannot leak
one per redraw. The comparison page draws ten at once and passes `multi: true`
to opt out; without it each chart destroys the one before and only the last
survives. Charts there are also drawn **after** the page is in the document,
because Chart.js sizes itself from the canvas's laid-out box and a detached one
has none.

## The expert qualitative page

`05_create_sme_open_response_data.R` builds it, and it is the **same
`open_responses` component the public page uses**, pointed at different files.
One code path, not two: what differs between the surveys is carried in the
data, which is what forced three things out of the engine and into the scripts.

The page intro says only what the page is. The two claims it used to carry —
that every response was read before publication, and that nothing here is
weighted — are in the caption beside each item, which is where a reader meets
them next to the responses they qualify. **That move added the review sentence
to the predicted-words caption**, which had never carried one: the intro was
the only place it was said, and the count of what was read has to sit with the
thing it was read from.

The caption over an item is two lines — **`asked_line`**, the question in
quotes so a reader sees the wording rather than a paraphrase, and
**`theme_caption`**, what the chart groups and what a click does — followed by
**`theme_note`** behind a *Note* disclosure. Both lines and the note are
written by the script that built the item; the engine composed them from parts
and could not know whether it was addressing respondents or experts, or
whether the item had a chart under it at all.

**The note is built from the counts, not written**: how many answered, how
many were excluded for not answering, and the one-theme-per-response rule that
makes the bars counts of people rather than counts of things said. It takes
the item's own nouns — a question, a reason, a concern — and drops the
"excluded" sentence where nothing was. `excluded_noun` is a second noun for
the one slot the theme noun does not fit: "did not include a substantive
misunderstanding" is why the expert items say "answer" there.

**What used to sit on the page and no longer does**: the count of what was
held back from the chart, and the statement that every response was read
before publication. Removed 2026-08-25 at Joe's request. **The checks behind
them are untouched** and still stop the build — an item nobody has read does
not publish, a corpus that has grown since it was read does not publish, and a
withhold naming a response the corpus does not contain does not publish. What
went is the disclosure, not the property.

- **The captions are written by the script that did the counting.** Both
  surveys have a words question and they are not the same question — the
  public gave associations and rated how each felt, experts predicted what the
  public would say and rated nothing. A sentence assembled in the engine would
  have to know which survey it was describing. `words.json` carries `title`,
  `caption` and optional `col_labels`; each verbatim file carries
  `theme_caption`. The public file's version ends by naming the one bar list
  on that page which is not a population estimate; on the expert page that
  sentence would be false, because nothing there is weighted.
- **No `scale` means no valence.** The ramp, its legend and the feeling column
  appear only where the words carry one. A grey bar is the honest bar.
- **The Survey column appears only where there is more than one fielding.** A
  column whose every cell reads 2026 is a filter that can only filter to
  everything. That also drops it from the public `ask` item, which is FU26
  only.

`00_open_responses.R` holds what the two pages must do identically — the
identifier screen, `normalise_word()`, `theme_distribution()`, `MIN_GROUP`,
and the two caution builders. `review_caution()` takes the withholding reason
as a `one`/`many` pair because the two surveys withheld for different reasons
and the clause has to agree with the count.

**Three items, 122 + 114 + 401.** `misunderstood` (`fusion_mis`) and `change`
(`fusion_change_dis`) are themed; `words` is `fusion_pub_word_1..3`.

**The predicted words are set against what the public actually said**, which
is what makes the item worth publishing rather than listing — it is a
prediction that can be scored, and it was the one prediction the findings deck
had no counterpart for. `05` reads the public column out of `03`'s
`words.json` rather than recounting it: two counts of one corpus drift, and
the point of the column is that it is the same list the public page draws.
Matching is exact after the shared normalisation and nothing is merged, so
"clean" predicting "clean energy" is a miss — the same judgment `03` refuses
to make when it keeps the two apart. 88 of the 203 predicted words appear in
the public list at all. Experts put "science fiction" at 10.9% against the
public's 0.6%, and "sun" at 10.9% against 1.4%.

**Splits are Everyone and years in fusion work**, the same three-band collapse
`04` uses and for the same reason. `change`'s middle band has 28 responses, so
`MIN_GROUP` drops it and the caption names it with its size.

**Themes were coded by reading, in the three passes the skill sets out.** The
third pass moved two responses out of *Turn down the hype* into *Stop
promising near-term power on the grid*: both name a timeline promise as the
thing to stop, and "hype" is only the word they reached for. That boundary is
the one to watch on this item — `hype` is about the volume of claims,
`honesty` about disclosing the downsides, and several responses are both.

`sme_themes.csv`, `sme_theme_labels.csv`, `sme_verbatim_review.csv` and
`sme_verbatim_withheld.csv` are the expert survey's own, for the same reason
it has its own sheet. One file holding both surveys would let a public item id
and an expert one collide with nothing to catch it.

**All 237 verbatims and 401 word entries were read on 2026-08-24. One was
withheld**, from `change`, and the reason is not the public side's: it names
two fusion outreach events and identifies its author as an organiser of them.
In a purposive sample of 153 experts an organising role in a named annual
event plausibly identifies the person, where the same detail in a sample of
2,444 adults would not. It is a borderline call, recorded as such, and it is
withheld for the identifying detail rather than for the opinion — which is an
ordinary and constructive one about communicating at a lay level. There is no
redaction anywhere in this pipeline, so the choice is the whole response or
none of it.

One borderline was **kept** and is recorded in `sme_verbatim_review.csv`: a
response arguing outreach should target women, who it says hold "unfounded
fears", and suggesting makeup artists and yoga retreats as vehicles. It is a
condescending generalisation, but it is addressed to how fusion is
communicated rather than at the group, and the gender gap it asserts is real
in the public data — gender is the third strongest correlate of support.
Withholding it would misrepresent what experts said about their own audience,
which is the same failure as a keyword coding frame.

## Pages

Seven, declared in `06`'s `config$pages`:

| id | component | nav |
|---|---|---|
| `home` | `fu_landing` | Home |
| `explore` | `explore` | Public Perspectives → Survey Results |
| `public-qual` | `open_responses` | Public Perspectives → Open Responses |
| `sme-survey` | `explore` | Expert Perspectives → Survey Results |
| `sme-qual` | `open_responses` | Expert Perspectives → Open Responses |
| `sme-compare` | `comparison` | Comparisons |
| `about` | `static_page` | About |

**The two groups offer the same two things, named the same way**, so a reader
who has learned the Public menu already knows the Experts one. The comparison
is not one of them: it belongs to neither survey, and burying it under Experts
made it read as an expert-survey page rather than the thing the two surveys
are for.

**Both dropdowns offer the same two things, named and described the same
way** — Survey Results and Open Responses — so a reader who has learned one
menu already knows the other. The description under each item is the page's
`blurb`: the labels alone do not say which is which until you have opened
both, and the dropdown is where that choice is made. `blurb` is also what the
landing page's directory used, which is why it reads as a standalone sentence
rather than as menu chrome.

**`default_question` is what a page opens on** when there is no `?q=`.
`explore` opens on `fusion_know`; without it a page opens on row 1, which is
whatever the survey asked first. `06` halts on a default the catalog does not
carry, because the front end would fall back to row 1 in silence and that
reads as the setting having been ignored.

A page carrying `nav_group` folds into a dropdown at the position of its
group's first member, and a page without one renders as a plain link where it
sits — which is why `sme-compare` had to move *after* `sme-qual` in
`config$pages` to become a tab of its own rather than splitting the Experts
menu in two.

**Ids are not labels and do not follow them.** `explore`, `sme-survey`,
`sme-qual` and `sme-compare` keep the names they were given because
`#explore?q=…` and `?q=…#sme-compare` links are already in circulation — the
findings deck's own links are the latter.

There are no `placeholder` pages left. The component says what will go there
and what is missing, and filling one in means writing its component and
swapping `component` in `06` — the page, its nav position and its landing-page
blurb stay put. `sme-qual` was the last one; it is now the `open_responses`
component pointed at the expert survey's files.

## The landing page is the project summary

`fu_landing` no longer resembles wxdash's `wx_landing` it was forked from.
**There is no chart and no headline figure**, and both absences are the point:

- A teaser plot invited a reader to judge the whole project on whichever
  question happened to be on it, and said nothing about why the work is being
  done.
- A finding on the way in is spent before the reader knows what it bears on.
  The findings deck delivers those; the landing page says what the programme
  is.

**There are no figures on it at all.** A provenance line — how many adults,
how many experts, which years — was the last thing on the page carrying a
number, and it went too. The landing page now fetches nothing: it is the only
component on the site that reads no data file.

**The words are the proposal's**, from `submission materials/`
`project_summary.docx`, close to verbatim: fusion's promise and the social
challenges alongside the technical ones, the fission precedent, the short-term
and long-term acceptance argument, the multiplier sentence, and the
Observatory's four objectives as it states them. Two earlier versions were
written for the site instead and read like marketing. **If this is revised,
revise it from the summary rather than rewriting it.**

**The copy is authored in `06`**, not in the engine, which carries no prose of
its own: `hero` (eyebrow, headline, lede paragraphs, actions) and `sections`.
A section is either a `lead` with a `body` of paragraphs and optional numbered
`points`, or a pair of `columns` each with its own `lead` and `body`.

One section is used, and it is a pair: **why public acceptance matters** and
**why expert understanding matters**. Side by side rather than stacked,
because they are two halves of one argument — acceptance is why the public is
surveyed, the communication gap is why the experts are — and stacking makes
the second read as a consequence of the first.

The page is **the headline, the summary's opening paragraph, three tabs and
one paired section**, and nothing else. An Observatory block
with the four objectives, a colophon naming the investigators, and a five-row
directory of the other pages were each written and each removed.
`directory_lead`, `colophon` and a section's `points` still render if a page
supplies them; the landing page supplies none of them.

**`hero$actions` is what is here**, in three: the public survey, the expert
survey, and the comparison. Rendered as a connected row rather than three
loose buttons, so they read as the whole of the site and not as three
suggestions.

Where a count does appear in prose it is read rather than typed — `spell()`
turns the small ones into words. `split thirteen ways` was written when there
were thirteen splits and was still on the page at sixteen, which is the
argument for computing them. They stack
below 900px — three across leaves each about 230px, which wraps its note to
five lines. The open-response pages are not tabs; they sit in the nav
dropdowns, which is where the directory was duplicating.

Two things in it are easy to undo:

- **It is one left-aligned column.** Two columns balanced only while the
  headline was a six-line slogan and the lede ran three paragraphs; against
  the project's own summary the halves never match, and the page was rebuilt
  twice chasing that before the column won.
- **`home` carries no `blurb`, and it is absent rather than `NULL`.** `list()`
  keeps a `NULL` element, `jsonlite` writes it as `{}`, and `{}` is truthy —
  the landing page listed itself in its own directory with "[object Object]"
  where the description goes. The same trap `waves` hits, in a new place.

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
