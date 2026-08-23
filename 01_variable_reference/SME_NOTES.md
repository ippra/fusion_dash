# SME variable reference — what needs a second pair of eyes

Built 2026-08-23 from `FU26 SME Survey Instrument.docx`, read end to end,
against `data/FU26_SME_data.csv` (153 respondents).

142 rows, one per variable. 128 have a data column; the other 14 are the
battery stems the instrument names but the data does not store. 25 of them
reach the dashboard as charts.

Nothing below is fixed in `sme_variable_reference.csv` — the sheet records what
the document says. Tick an item when it is resolved, and date the tick.

## 1. Check before pooling or modelling

- [ ] **There are no weights, and there is no weight column.** 153 people
      identified as having relevant expertise is a purposive sample, not a
      sample of any population, so every percentage on the expert page is a
      plain count of the experts who answered. `04_create_sme_data.R` builds
      the survey design with weights of 1 so the interval and the file shape
      match the public side; that is a convenience, not a claim that the
      numbers generalise. Do not put an expert percentage next to a public
      percentage without saying which is which.
- [ ] **26 SME columns share a name with a public variable and only five ask
      the same question.** `fusion_time`, `fusion_risk`, `fusion_cost`,
      `fusion_ben` and `fusion_risk_ben` are word for word the public FU26
      items. The three `fusion_risk_*` / `fusion_cost_*` / `fusion_ben_*`
      batteries are **not**: the public was asked which they would most want to
      understand, experts which non-experts most need to understand, and some
      item wordings differ as well (public `fusion_risk_waste` is "Long-term
      radioactive material management", the SME item is "Long-term waste
      management and decommissioning challenges"). Anything that joins the two
      surveys on column names produces a comparison that looks valid. The
      sheet's `compare_to` column declares the five that are real.
- [ ] **`fusion_pub_time` asks about the wrong bands.** It reproduces FU25's
      overlapping wording — `1 to 5 / 5 to 10 / 10 to 25 / 25 to 50 / 50 to
      100` — while the item it is predicting, FU26's `fusion_time`, uses the
      fixed bands `1 to 5 / 6 to 10 / 11 to 25 / 26 to 50 / 51 to 100`. The
      expert's own `fusion_time` uses the fixed bands. So the two timeline
      questions inside this one instrument are banded differently, and the
      expert is predicting a distribution over bands the public never saw. The
      codes line up 1-to-1 in order, so the comparison is drawn, but it is a
      comparison across two banding schemes and the page says so.
- [ ] **`fusion_pub_feel` relabels the scale it is predicting.** The public
      scale reads `Very negative / Negative / Neither / Positive / Very
      positive`; this one reads `Somewhat negative` and `Somewhat positive` for
      2 and 4. A five-point scale with softer middle labels is not obviously
      the same measure.
- [ ] **42 of 153 did not finish.** `finished` is 1 for 111 and 0 for 42, and
      `progress` runs from 50 to 100. Nothing is filtered on it: each item uses
      whoever answered that item, which is the rule the public pages follow,
      and the caption carries the per-item denominator. Late items therefore
      rest on fewer people — the ranking blocks near the end have about 130
      answers against 152 for the first substantive question.
- [ ] **The two "select the two most significant" batteries are capped, so
      their bars sum to about 200, not 100.** Same for `fusion_sup_cor`, capped
      at three, which sums to about 300. The captions say the bars do not sum
      to 100 but do not yet say what they do sum to.

## 2. Instrument problems worth fixing before the next fielding

- [ ] **`primary_role` says "Which best describes your primary role" and then
      offers select-all-that-apply.** Either the stem or the response type is
      wrong. As fielded it is select-all, and the sheet records that.
- [ ] **`exp_comm_none` is not exclusive.** "No — I primarily communicate with
      other experts" sits in a select-all list with nothing preventing a
      respondent choosing it alongside three audiences.
- [ ] **`fusion_ben_oth_spec` carries the word "Other" before its `[verbatim]`
      marker** while its risk and cost siblings do not — the same cosmetic slip
      the public FU26 instrument has.
- [ ] **The three risk / cost / benefit battery stems have no variable name**,
      unlike `primary_emp`, `fusion_chal_few` and the rest, which are named.
      The sheet gives them `fusion_risk_topics`, `fusion_cost_topics` and
      `fusion_ben_topics` so they have somewhere to hang.
- [ ] **The `exp_years` bands are listed without numbers** while every other
      closed item numbers its options. The data codes them 1-6 in listed order.

## 3. Names and fields that must NOT be published

- [ ] **`external_ref` is a five-digit contact reference.** It is not a name,
      but it is a key back to whatever list the invitations came from. Nothing
      in the pipeline emits it; keep it that way.
- [ ] `confirm_name` and `confirm_email` are asked on page 1 of the instrument
      and are **not** in the released file. Good — but the next export has to
      strip them again, and nothing in the file records that they were removed.

## 4. Fielding metadata

- [ ] IRB number 17657, approval date 03/10/2026, against 0680 and 06/17/2025
      on the public FU26 instrument. Different protocol, as expected for a
      different population; recorded so it is not read as an error.
- [ ] The instrument's closing page promises participants a link to the public
      results (`[link]`, unfilled) and early access to findings. Whoever
      publishes this dashboard owes them that link.

## 5. Open questions

- [ ] `fusion_sup_cor` asks experts which factors most strongly correlate with
      public support. The actual correlates can be computed from the public
      data and are not, yet — that comparison would be the strongest test of
      expert calibration in the survey, and it is the one prediction item with
      no counterpart on the comparison page.
- [ ] `fusion_pub_word_1..3` asks experts to predict the public's most common
      word associations. The public words are already counted on the public
      qualitative page; nobody has compared the two lists.
- [ ] `fusion_mis` (122 responses) and `fusion_change_dis` (115) are not
      published. They need the same content read the public verbatims got —
      see `NOTES.md` section 6 — before anything is shown, and they are not
      themed.
- [ ] Whether the experts who felt more confident about understanding public
      views (`fusion_pub_conf`) actually predicted better. The data supports
      the question; the dashboard does not ask it.
