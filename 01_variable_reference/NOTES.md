# Variable reference — what needs a second pair of eyes

Built 2026-08-21 from `FU25 Survey Instrument.docx` and `FU26 Survey
Instrument.docx`, read end to end, against `data/FU25_data_wtd.csv` (1,200
respondents) and `data/FU26_data_wtd.csv` (1,244 respondents).

152 rows, one per variable. 126 are closed-ended and reach the dashboard; 55
variables were asked in both waves; 13 are experimental; 17 carry
`wording_varies`.

Nothing below is fixed in `variable_reference.csv` — the sheet records what the
documents say. Tick an item when it is resolved, and date the tick.

## 1. Check before pooling or modelling

- [ ] **`fusion_time` bands moved and used to overlap.** FU25 offered `1 to 5 /
      5 to 10 / 10 to 25 / 25 to 50 / 50 to 100 years`, so a respondent who
      thought "ten years" had two valid answers. FU26 closed the gaps: `1 to 5 /
      6 to 10 / 11 to 25 / 26 to 50 / 51 to 100`. The codes are identical
      across waves, so pooling by code silently compares different bands.
- [ ] **`rskben_fusion` (FU25) and `fusion_risk_ben` (FU26) are not the same
      item.** FU25 asked about the balance of *risks and benefits*; FU26 asks
      about *risks, costs, and benefits* and relabels every endpoint. They have
      different names, so nothing pools them by accident — but a trend series
      that treats them as one measure is comparing two quantities.
- [ ] **FU25 released fifteen variables under names its own instrument no
      longer uses.** The ten `fusion_source_*` boxes are `fusion_source_1` …
      `fusion_source_10` in the data; `inv_fusion_private` / `_government` are
      `inv_fusion_1` / `_2`; `inv_fusion_priority` / `inv_other_priority` are
      `inv_priority_1` / `_2`; `comments` is `comment`. The sheet carries both
      in `variable` and `column_fu25`. Anything that joins FU25 data on
      instrument names loses those fifteen items and reports success.
- [ ] **`govspend_fusion_exp` is one item and two columns.** The FU25 data
      splits it into `govspend_fusion_exp_a` (no background information) and
      `_b` (after reading about global investment) — the arms of
      `rand_spend_comp`. Each is missing for about half the sample. Pooling
      them averages across the treatment the experiment was built to measure.
- [ ] **Four items name a randomized organization or distance.** `labs_trust`
      (both waves) and `labs_trust_risk` / `labs_trust_bene` (FU25) rate either
      "U.S. national laboratories for energy and security" or "Lawrence
      Livermore National Laboratory"; `fusion_host` (both waves) asks about a
      facility 10 or 50 miles away. A mean over any of those columns is a mean
      over two different questions.
- [ ] **The FU26 regulation block rests on a three-arm randomization.**
      `reg_path_balance` and `reg_path_support` rate whichever of the three
      `rand_reg_path` proposals the respondent read. `fusion_reg_choice` offers
      all three to everyone, but every respondent has just evaluated one of
      them, so the choice follows a randomized prime.
- [ ] **FU25 has no self-reported demographics.** `gend`, `race`, `hisp`,
      `edu`, `income` and `party` are FU26 items only; in FU25 those
      characteristics come from the vendor sample frame and exist only as the
      derived `Gender`, `Race`, `Education`, `Income`, `Party_ID` columns. Both
      waves carry the derived columns, so any split that pools waves must use
      those — splitting on the FU26 raw items drops 2025 entirely.
- [ ] **The two waves routed the three why-items by different rules.** Both
      are deterministic and both reproduce their wave exactly (0 mismatches in
      2,410 routed respondents), but they are not the same rule:

      | | FU25 | FU26 |
      |---|---|---|
      | oppose | `new_fusion <= 2` **or** `fusion_host <= 2` | `new_fusion <= 2` **and** `fusion_host <= 2` |
      | support | neither gate in 3-5, and one >= 6 | `new_fusion >= 6` **and** `fusion_host >= 6` |
      | unsure | everything else | everything else |

      FU25 tests oppose first and unsure second, so `or` on the oppose gate
      pulls in anyone negative on **either** question. FU26 requires both.
      The effect is large and in one direction: **221 FU25 respondents (18%)
      were asked why they oppose who FU26 would have asked why they are
      unsure**, and 264 FU26 respondents (21%) the reverse. So `oppose`
      falling from 297 responses in 2025 to 106 in 2026 is a change in the
      gate, not a change in opinion, and the two waves' oppose corpora are
      different populations. Ten of the FU25 oppose responses come from people
      who scored 6 or 7 on fusion plants — "I support fusion energy but I
      would want a facility to be in a remote region" is filed under why
      people oppose.

      Decide before any trend or pooled claim on these items: report them by
      wave, or restrict FU25 to the rows FU26's rule would also have routed
      there. Note this reaches the theme coding too, which pools both waves.
- [ ] **The `asked_if` column describes neither wave's rule.** It records
      `new_fusion <= 2 or fusion_host <= 2` and its two siblings, taken from
      the documents. FU26 uses `and`, and neither instrument states the
      priority between the three conditions, which is what actually decides
      the overlapping cases. The sheet records what the documents say — but
      the documents are wrong about what was fielded, so the plain-language
      caption on the page is wrong too, in the same way, for both waves.
- [ ] **`confirm_attention` filters nobody.** Every FU26 respondent in the
      released data answered Yes. It has no variance and cannot be used as a
      quality screen after the fact.

## 2. Instrument problems worth fixing before the next fielding

- [ ] **The FU25 document on file does not describe the FU25 data.** It was
      updated to FU26's naming after FU25 was fielded. Either keep an as-fielded
      copy alongside it or record the renames in the document itself, so the
      next person to read it is not misled the way a parser would be.
- [ ] **FU26 `fusion_reg_choice` option 3 and `rand_reg_path` arm C describe the
      same proposal in different words** — "reduce unnecessary barriers" against
      "reduce administrative barriers". One of the two is wrong; respondents
      read both.
- [ ] **`fusion_source_dk` is not exclusive.** "Don't know" sits in a
      select-all-that-apply list with no rule preventing a respondent from
      choosing it and three sources.
- [ ] **The "please specify" boxes are named nowhere.** FU25 releases
      `fusion_source_10_text`; FU26 releases `fusion_source_oth_spec`,
      `fusion_risk_oth_spec`, `fusion_cost_oth_spec`, `fusion_ben_oth_spec` and
      `fusion_info_oth_spec`. Only the last four appear in the document at all,
      and none is tied to its parent box.
- [ ] **The consent item has no variable name.** Both instruments show its two
      options under the IRB text; both waves release it as `intro`.
- [ ] **`rand_spend_comp` is not released.** The FU25 assignment has to be
      reconstructed from which of `govspend_fusion_exp_a` / `_b` is populated.
      FU26 releases `rand_reg_path` directly, which is the better pattern.
- [ ] **FU26 page 19 carries a lead-in paragraph and no item.** Harmless, but it
      is the only page in either document with nothing on it.

## 3. Names that must NOT be fixed

These are in the released data. Correcting them in the sheet breaks the join.

- [ ] `comment` — FU25's column has no trailing `s`; FU26's is `comments`.
- [ ] `fusion_source_1` … `fusion_source_10`, `inv_fusion_1`, `inv_fusion_2`,
      `inv_priority_1`, `inv_priority_2` — FU25's released names.
- [ ] `distance` and `nat_lab` — FU25's names for FU26's `rand_dist` and
      `rand_lab`.
- [ ] `fusion_cost_constru`, `fusion_cost_opera`, `fusion_cost_decomm`,
      `fusion_ben_energysec` — truncated, but as released.

## 4. Fielding metadata

- [ ] **FU26's header is still a template.** It reads `n = 2,000; July ##-##,
      2026; Avg. Time = ## min`. The released file has 1,244 respondents. Fill
      in the real sample size, field dates and duration.
- [ ] **FU25's IRB approval date reads 05/11/2018**, FU26's reads 06/17/2025,
      both under IRB number 0680. If the protocol was renewed, FU25's header was
      never updated.
- [ ] Contact address changed between waves (`hjsmith@ou.edu` →
      `kuhikagupta@ou.edu`). Expected; recorded so it is not read as an error.

## 5. Cosmetic issues

- [ ] **FU25 writes "US", FU26 writes "U.S."** throughout — organization names,
      question stems, and the fusion information paragraph. This is the only
      difference behind most of the 17 `wording_varies` rows; the `notes` column
      says which.
- [ ] **FU26 writes the `gcccert_yes` / `gcccert_no` show conditions as `ggc =
      1` and `ggc = 0`** — a typo for `gcc`.
- [ ] **FU26 `party` runs its first option onto the question line**, so the
      paragraph reads `…or what? 1 - Democratic`.
- [ ] **FU26 `iden` lists its options as 2 then 1.**
- [ ] **FU25's page markers carry no number** (`---End Web pg---`) while FU26
      numbers them.
- [ ] **FU25 `word_1` / `word_2` / `word_3` item text ends with a colon**
      (`First word/phrase:`), which reads oddly as a standalone question.
- [ ] **FU26 `fusion_ben_oth_spec` carries the word "Other" before its
      `[verbatim]` marker** while its risk, cost and info siblings do not.
- [ ] **FU26's income follow-ups continue their codes across items** — `inc_50`
      uses 1–5, `inc_100` 6–10, `inc_150` 11–15, `inc_200` 16–21. Deliberate,
      and worth knowing before anyone recodes them.

## 6. Before the open-response page is published

- [ ] **A response has to be read for content, not only for identifiers.**
      `03_create_open_response_data.R` screens every verbatim for emails, URLs,
      phone numbers, long digit runs and @handles, and currently catches
      nothing across 3,580 responses. That screen sees shapes, not meaning, and
      it is not a substitute for someone reading them.
      **Known example: `uncertain` response 299 (2025, case R_7v227pi7cJFbMtw)
      objects to a facility on the grounds that it would introduce "blacks,
      Hispanics and other undesirable elements" to the respondent's community.**
      It is coded *Local impact on my area*, which is its stated reason, and it
      renders verbatim on the page like every other answer. It is not the only
      thing of its kind that a full read might surface.
      Decide before the site is served anywhere public: publish the corpus
      whole, withhold specific responses with the count stated, or show themes
      and counts without the raw text for these items. Whichever is chosen, say
      it on the page.
- [ ] **Free text carries location detail the screen cannot catch** — "I live
      in New York City", "I live within 50 miles of Canada and Buffalo", "I
      live near the Hanford WA Nuclear Plant". Individually harmless; worth a
      judgement about the set.

## 7. Open questions

- [ ] FU25's two-approaches block (`fusion_app_know`, `fusion_app_prom`, and the
      magnetic/inertial confinement descriptions) was dropped in FU26 with no
      replacement. Retired on purpose, or dropped for length?
- [ ] The eight `argue_fusion_*` persuasiveness items and both nine-item
      `*_trust_risk` / `*_trust_bene` batteries were also dropped after FU25.
      Whether they return decides whether they are a trend series or a one-off.
- [ ] FU26 splits the risk/cost/benefit judgment into three separate ratings
      (`fusion_risk`, `fusion_cost`, `fusion_ben`) plus a balance item
      (`fusion_risk_ben`). Whether the balance item is meant to continue FU25's
      `rskben_fusion` as a trend is not settled by the documents.
- [ ] `nuclear_support` (FU26) is worded to match `new_fusion` word for word,
      which implies it is a benchmark for fusion support. Nothing in the
      document says so.
