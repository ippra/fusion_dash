---
name: fusion-variable-reference
description: Build or extend the variable reference sheet (codebook) for the IPPRA Fusion Energy Survey from Word instruments. Use when asked to catalogue fusion survey questions, build or update the codebook or variable reference, or add a newly fielded wave to the existing sheet. Triggers on "variable reference", "codebook", "question sheet", "survey instrument", "index the questions", "add a wave", "FU25", "FU26".
---

# Fusion variable reference

Turns IPPRA Fusion Energy Survey instruments (`FU25 Survey Instrument.docx`,
`FU26 Survey Instrument.docx`, …) into one CSV: **one row per variable**,
carrying the question as it was actually asked and which waves asked it.

Wave prefixes: `FU25` fielded March 2025, `FU26` fielded July 2026. Where a
variable appears in more than one wave, **the newest supplies the wording** and
the older ones record coverage and any wording change.

This is the fusion sibling of `survey-variable-reference` in the wxdash repo,
which does the same job for the four severe-weather instruments. The procedure
is the same; what differs is one survey instead of four hazards, and the wave
column layout described below.

## Read the instruments. Do not write a parser.

This was attempted with a regex parser first, here and in wxdash. It reaches
roughly 90% and the last 10% is silently wrong, which is worse than obviously
wrong in a reference table. Extracting text from the `.docx` is mechanical and
scripted below. **Deciding what the text means is not.** What defeats pattern
matching in these two instruments, all of it real:

| Looks like a question | Actually is |
|---|---|
| `fusion_source_tv: Television news` with no options beneath | one box in a select-all-that-apply battery |
| `fusion_risk_oth_spec: [verbatim]` | the "please specify" box belonging to `fusion_risk_oth` |
| `rand_dist`, `rand_lab`, `rand_spend_comp`, `rand_reg_path` | randomization assignments, named only inside brackets |
| `confirm_attention: Before continuing, will you take a moment…` | an attention screener, not a survey question |
| `fusion_question: As part of this project, we plan to share…` | a preamble; the question is the *next* paragraph, and the `[verbatim]` marking it open-ended is there, not on the item's own line |
| `govspend_fusion_exp` | one instrument item that the data stores as two experimental arms, `_a` and `_b` |
| `gcccert` | one FU25 item with its wording piped off the previous answer, stored as `gcccert_yes` and `gcccert_no` |

And the wording that gives an item its meaning is often not on the item's line
at all: `worry_sec: National security (including terrorism and war)` means
nothing without the stem two paragraphs above it.

The FU25 instrument on file was **updated to the naming FU26 later adopted**,
while FU25's released data kept the original names — `fusion_source_tv` in the
document is `fusion_source_1` in the file. Fifteen variables are affected. A
parser matching document names against data columns therefore fails on FU25 and
succeeds on FU26, which is exactly the shape of bug that looks like success.

FU25 also writes its page markers with no number (`---End Web pg---`) while
FU26 numbers them.

## Procedure

### 1. Extract the text

```sh
python3 <skill>/scripts/extract_instrument_text.py 01_variable_reference <scratch_dir>
```

One `FU25.txt` per instrument, each line prefixed with its index in the
document. The script handles the two traps that corrupt naive extraction —
`mc:Fallback` duplicating every text box, and a text-box anchor paragraph
slurping its children onto one line — and splits on `w:br`, which these
instruments use inside option lists. Do not hand-roll this.

### 2. Read each file end to end

Whole file, in order. Not grep, not head. A stem on line 348 governs items
through line 359; you cannot see that from a search hit. ~770–840 lines per
instrument.

Read the newest instrument first, then the older one, to find variables it has
that the newer dropped and to spot wording changes.

### 3. Write the rows

Newest instrument's order. Then append variables only the older instrument has,
in its order.

| column | contents |
|---|---|
| `variable` | canonical name: the FU26 name where FU26 asks it, else the FU25 instrument name |
| `instrument_name` | the *older* document's name, filled only where it differs from `variable` — which happens where one document item is stored as two columns (FU25 `gcccert`, `govspend_fusion_exp`) |
| `column_fu25` | the column in `data/FU25_data_wtd.csv`, empty when the wave did not ask it |
| `column_fu26` | the column in `data/FU26_data_wtd.csv`, empty when the wave did not ask it |
| `question_type` | `question`, `checkbox_item`, `checkbox_parent`, `verbatim_followup`, `randomization`, `screener` |
| `battery` | for a `checkbox_item`, the id of the select-all set it belongs to; empty otherwise. The dashboard draws one plot per battery, so this is what decides which items are read together |
| `arm_variable` | for a question pooled across the arms of an experiment, the randomization variable behind it. The dashboard draws one plot per arm and offers a menu to switch. Leave empty where the data already carries one column per arm, as FU25 does for `govspend_fusion_exp` |
| `experimental` | `TRUE` when what the respondent read varied — see below |
| `question_focus` | `fusion` or `background` |
| `topic` | the section facet the dashboard shows as its first column — see below |
| `keywords` | one or more content tags, ` \| `-separated, from the fixed list below |
| `question_intro` | the preamble the item sits under, brackets stripped. Empty when the item is self-contained |
| `question_text` | the item, verbatim, brackets stripped |
| `response_options` | `1 = Label \| 2 = Label`, separated by ` \| `. Unlabelled scale points are the bare number |
| `n_options` | count, `0` when none |
| `response_scale` | family name, see below |
| `reverse_worded` | `TRUE` when a negatively worded item sits on a directional scale |
| `asked_if` | the show condition, e.g. `fusion_know = 1` |
| `notes` | programming directives (`RANDOM ORDER`, `VERBATIM`) and anything wrong with the instrument |
| `instruments` | `FU25;FU26` |
| `wording_varies` | `TRUE` when intro, item text or options differ between waves |

**Two wave columns, not two rows.** wxdash keys its sheet on hazard because its
four instruments are four different surveys. Here there is one survey fielded
twice, and the dashboard pools waves behind a survey-year split, so the row is
the question and the wave columns record where to find it. This is also what
absorbs the FU25 renaming: `variable` stays the name a reader would search for,
and `column_fu25` carries the join key the data actually uses.

### 4. Classify each row — by reading it, never by rule

`experimental`, `question_focus`, `topic` and `keywords` are decided **by
reading the question**, one row at a time. Do not write a script that assigns
them from name prefixes or regexes over the wording. The whole point of these
columns is the judgment; a rule that gets 90% of them right is the failure mode
this skill exists to avoid. Scripting the *paste-in* of decisions already made
is fine — and safer than retyping, because it cannot alter the verbatim text.

**`experimental`** — `TRUE` when the answer depends on a stimulus that varied
between respondents, so the item is not a clean population measure. In these
two instruments that means:

- randomized wording inside what the respondent read: `fusion_host` and the
  three `labs_trust*` items carry `[rand_dist]` and `[rand_lab]`
- a randomized information treatment upstream: `govspend_fusion_exp_a` and
  `_b` are the two arms of `rand_spend_comp`
- a randomized stimulus the item then asks about: `reg_path_balance` and
  `reg_path_support` rate whichever of the three `rand_reg_path` proposals the
  respondent was shown
- an upstream randomization that changed what they read first, even where the
  item's own wording is fixed: `fusion_reg_choice` offers all three proposals
  to everyone, but every respondent has just evaluated one of them

Order-only randomization (`RANDOM ORDER`, `randomize`, `randomize block`) is
**not** experimental. That would sweep in every battery in the survey — the
five `worry_` items, all nine trust items, all eight `argue_` items — none of
which vary in what was read.

A **piped answer is not a randomization**. FU25's `gcccert` inserts the
respondent's own previous answer ("are" / "are not"); that stays `FALSE`.

Filtering `experimental == FALSE` is how the sheet is reduced to clean
population measures. Nothing is deleted — the row stays so the record is
complete, and the dashboard shows experimental items with a caution rather than
hiding them.

**`question_focus`** — `fusion` when the question is about fusion energy,
energy policy, regulation, technology, climate or the institutions involved.
`background` when it is primarily a personal characteristic: age, gender, race,
income, education, where they live, ideology, party, consent and attention
checks. Judge the question itself, not the section it sits in — `doright`
("how much of the time do you trust the government in Washington") is
`background` even though it sits among the trust items, while `nuclear_support`
is `fusion` even though it never mentions fusion, because it is the comparison
the fusion support item is read against.

**`topic`** — the facet the dashboard shows in its first column, so a reader
can narrow 100-odd questions before searching. Use these, and add one only when
a new section genuinely does not fit:

`Public concerns` · `Word association` · `Awareness and knowledge` ·
`Risks, costs, and benefits` · `Support and expectations` ·
`Information needs` · `Trust in institutions` · `Investment and arguments` ·
`Regulation` · `Technology and energy` · `Climate change` · `Politics` ·
`Background`

**`keywords`** — pick every tag that genuinely applies, usually one or two:

`admin` · `arguments` · `attention_check` · `awareness` · `benefits` ·
`climate` · `comprehension` · `consent` · `costs` · `demographics` · `energy` ·
`government_spending` · `ideology` · `information_needs` · `knowledge` ·
`location` · `open_feedback` · `regulation` · `risk_perception` · `siting` ·
`sources` · `support` · `timeline` · `trust`

### 5. Write NOTES.md

Alongside the sheet, write `NOTES.md` — the human-facing list of what needs a
second pair of eyes. **This is required, not optional.** The `notes` column is
a per-row record; `NOTES.md` is the part someone will actually act on.

Every item is a `- [ ]` checkbox so it can be worked through and ticked off.
Group by what to do about it, not by where it was found:

1. **Check before pooling or modelling** — anything that silently changes a
   result. Response bands that moved between waves, items renamed between the
   document and the data, names that mean different things in different waves.
2. **Instrument problems worth fixing before the next fielding** — orphaned
   questions, wrong interpolations, unfilled placeholders.
3. **Names that must NOT be fixed** — with the reason: they are in the released
   data, so correcting them breaks the join.
4. **Fielding metadata** — impossible dates, unfilled header placeholders,
   labels that disagree with the fielding date.
5. **Cosmetic issues** — typos and spacing that do not affect the data but do
   make the documents harder to read mechanically.
6. **Open questions** — anything the documents could not settle. Say plainly
   that it is unresolved rather than guessing.

State what the document says and what it should probably say, and never resolve
it silently in the sheet. Carry unticked items forward when a wave is added — a
fixed item gets ticked and dated, not deleted, so the file also records what
stopped being a problem.

Start it with the build date and the instruments it covers.

### 6. Verify

```sh
python3 <skill>/scripts/check_coverage.py variable_reference.csv <scratch_dir>
```

`missing` must be zero. `extra` is expected and must be only: randomization
variables (they appear inside brackets, never as `name:` lines), the consent
item the instrument never names, and the "please specify" boxes the data
carries but the document does not list.

Then confirm every row has a data column in at least one wave, that no row has
both `question_intro` and `question_text` empty except `randomization` rows,
and that it parses:

```sh
Rscript -e 'readr::read_csv("variable_reference.csv", guess_max = Inf) |>
  dplyr::count(question_type)'
```

`02_create_question_data.R` re-checks the sheet against the two data files on
every run, so a column named here that the data does not carry stops the build
rather than dropping a question quietly.

## Rules that matter

**Verbatim means verbatim.** Do not tidy grammar, expand contractions, or
change punctuation. The instruments use curly apostrophes and em dashes; keep
them. Commas inside option labels stay commas — that is why the option
separator is ` | ` and not `, `. Genuine semicolons occur (`Some College; NO
degree`) and must survive. A pipe inside an option label would make
`response_options` unsplittable; none occur so far.

**Checkbox items get `0 = Not selected | 1 = Selected`.** The instrument shows
no options for them; that is the coding, and leaving it blank loses it. Neither
fusion instrument gives the parent stem a variable name, so there are no
`checkbox_parent` rows yet — the stem lives in each item's `question_intro`,
which is where the item gets its meaning. A wave that names a parent gets a
`checkbox_parent` row with `n_options = 0`.

**Every checkbox item needs a `battery`.** The dashboard draws one plot per
battery — the items as categories, each bar the share who ticked that box —
because ten charts reading "6% yes, 94% no" are not a picture of what the
battery asks. Membership is declared here rather than inferred from the shared
stem at build time, so editing one item's wording cannot silently split a
battery in two. `02` halts if a battery spans more than one stem or topic, if
its items disagree about which waves asked them, or if they disagree about who
was shown them — one denominator cannot serve items resting on different
samples. The five so far: `fusion_source` (10), `fusion_risk_topics`,
`fusion_cost_topics`, `fusion_ben_topics` (6 each) and `fusion_info_topics`
(10).

**Unlabelled scale points are the bare number.** `0 = No trust | 1 | 2 | … |
10 = Complete trust`, with `Only the endpoints are labelled` in `notes`. The
dashboard renders those bars as their number so the scale survives.

**Record instrument errors in `notes`, never fix them,** and raise the ones
that matter in `NOTES.md`.

**`reverse_worded` is about wording, not about any scale's coding.** No fusion
item is reverse worded so far; the eight `argue_` items are not, because each
sits on its own persuasiveness scale rather than a shared direction.

## The arms file

`arms.csv` beside the sheet maps each wave's raw assignment values to an arm id,
a display label, an order and a prompt for the menu. One row per wave per value.

Declared rather than matched, for the same reason the wave columns exist:
`rand_lab` records the same arm as "US national laboratories for energy and
security" in FU25 and "U.S. national laboratories for energy and security" in
FU26. Matching on the string would split one arm into two, and both halves
would look like clean estimates. A new wave needs its own rows here even when
the values look identical to the last one's.

`02` halts on an assignment value the file does not map, on a respondent with
no arm recorded, and on an arm id whose label differs between waves.

## Response scale families

A family groups scales with the same structure and endpoints. Exact wording is
never lost — it lives verbatim in `response_options` — so a one-word difference
in a middle label is recorded in `notes` rather than spawning a new family.
Reuse these names; add one only when the shape is genuinely new, and name it
for what it measures plus its length.

`approach_know_5` · `approach_prom_5` · `attention_2` · `certainty_11` ·
`checkbox` · `checkbox_parent` · `concern_11` · `confidence_5` · `consent_2` ·
`describe_bene_7` · `describe_risk_7` · `dev_status_4` · `dropdown` ·
`education_8` · `feeling_5` · `gender` · `heard_3` · `ideology_7` ·
`importance_11` · `income_band_4` · `income_band_5` · `income_band_6` ·
`knowledge_11` · `lean_2` · `level_5` · `better_worse_5` · `numeric` ·
`numeric_0_100` · `open_text` · `party_4` · `persuasive_10` · `race_6` ·
`randomization` · `reg_balance_5` · `reg_choice_3` · `reg_level_5` ·
`reg_phil_4` · `reg_time_4` · `riskben_7` · `riskbencost_7` · `risk_11` ·
`spending_7` · `strength_2` · `support_5` · `support_7` · `timeline_6` ·
`trust_11` · `trust_gov_11` · `yes_no`

`riskben_7` and `riskbencost_7` must not be merged: FU25 asked about the
balance of risks and benefits, FU26 about risks, costs and benefits, under
different variable names. They are different quantities.

## Adding a newly fielded wave

Drop the `.docx` in `01_variable_reference/` and re-run from step 1. For each
variable already in the sheet, compare wording: identical means append the wave
to `instruments` and fill its `column_` cell; different means take the new
wording, keep the old in `notes`, and set `wording_varies` to `TRUE`. Anything
new gets a row. Anything dropped keeps its row with its existing wave columns —
that is the record of when it stopped being asked.

Adding the wave to the pipeline is one row in the `waves` table in
`00_paths.R`, plus a `column_fu27` column here.

Then update `NOTES.md`: carry unticked items forward, tick and date anything
the new wave fixed, and add whatever the new wave introduced.

## Where the instruments come from

`01_variable_reference/` in this repo holds the `.docx` instruments, one per
wave, named `FU26 Survey Instrument.docx`. They came from the fusion survey
folders in Joe Ripberger's Dropbox (`Fusion Survey 2025/`, `Fusion Survey
2026/`), alongside the weighted data files now in `data/`.

Unlike wxdash, these are **not** gitignored: they are about 76 KB each, no
embedded images, and having the sources beside the sheet is worth more than the
bytes. Revisit if a wave arrives carrying graphics.

`variable_reference.csv` is the versioned record of what the instruments
contain, and `NOTES.md` the record of what still needs checking.

## Current state

Both waves are built and coverage-verified — one row per variable, every one
classified by reading. `NOTES.md` carries what the reading turned up.
