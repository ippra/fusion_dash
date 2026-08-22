---
name: open-response-themes
description: Code the open-ended survey responses in the IPPRA Fusion Energy Survey into themes, by reading them. Use when asked to theme, code, categorise, tag or group free-text answers — the why-oppose / why-support / why-unsure items, the questions people would ask a fusion expert, or a newly fielded open-ended item. Triggers on "themes", "theme the responses", "code the verbatims", "categorise the open responses", "qualitative coding", "tag the answers".
---

# Open response themes

Turns one open-ended item's answers into `themes.csv`: **one primary theme per
response**, keyed on `case_id`, plus a labelled roster in `theme_labels.csv`.
The dashboard shows the theme as a filterable column beside the raw text, which
is never altered.

Coded so far: `oppose` (403 responses, 15 themes), `support` (377, 15) and
`uncertain` (1,630, 17). Not coded: `ask` (1,170). An uncoded item shows no theme column —
`03_create_open_response_data.R` does not guess.

## Read the responses. Do not write a matcher.

This is the sibling rule to `fusion-variable-reference`'s, and it fails the
same way. A keyword or embedding pass produces a column that looks coded and
is wrong in the cases that matter, because the trigger words are all in every
answer. A real example from `oppose`:

> "I don't know what fusion is, it sounds dangerous, and I don't want it near
> my house"

That contains the cue for *Not enough information*, *Safety and accident risk*,
and *Not near where people live*. Which one it **is** depends on what the
writer leads with and dwells on. Only reading tells you.

More of what defeats matching, all of it real in this corpus:

| Looks like | Actually is |
|---|---|
| "It sounds dangerous. Just from all the movies and media… or a terrorist target." | Safety — the terrorism line is where the impression came from, not the claim |
| "our world isn't built to last off of fusion energy/solar" | Not a preference for solar; it dismisses solar too |
| "I meant to indicate that I support fusion energy. I could not go back to correct my error." | Does not actually oppose — the gate caught someone who does not belong |
| "Do it on the rich. They have plenty of land. Experiment on them!!!!!" | A siting objection, written as sarcasm |
| "I was not oppose it I just don't think it should be within 10 miles" | Correctly gated: they oppose the siting, not the technology |
| "Already near a nuc plant" | Siting — four words, and the reason is that they already host one |

## Procedure

### 1. Export the item

```sh
Rscript <skill>/scripts/export_for_coding.R oppose <scratch>/oppose_raw.txt
```

One response per line: index, `case_id`, year, text. The index is for
referring to a response while you read; **the `case_id` is the key the coding
uses**, because an index moves when the data does.

### 2. Read every response, in order

Whole file. Not a sample, not a search. ~400 responses at a median of 77
characters is a few thousand words — read them.

You are looking for what people are actually worried about, in their words,
not for a tidy taxonomy. Let the themes come from the corpus. If two concerns
keep arriving together, that is one theme; if a theme you drafted turns out to
have three members that do not resemble each other, it was not a theme.

### 3. Draft the themes

Name them for what the respondent is saying, not for the topic area. "Safety
and accident risk" and "Association with nuclear power" are different claims
about the same subject and belong apart — 29 people opposed because fusion
*sounds like* nuclear, which is a communications finding rather than a safety
one.

Aim for themes a reader can act on. Fifteen worked for 403 responses; the
largest was 20% and the smallest 0.2%.

### 4. Assign one theme to each response

**The concern it leads with or dwells on.** Many responses raise two or three;
the coding records the dominant one, and the page says so. Do not invent a
second column for the rest — a filter with overlapping membership is a filter
whose counts do not add up.

Two rules that settle most of the hard cases:

- If the response names a specific harm, code the harm. If it says only that
  the writer lacks knowledge, code *Not enough information to judge*. "I don't
  know enough to know if these plants emit harmful chemicals" names emissions;
  "I just don't know enough about it" does not.
- A bare statement of fear — "Dangerous", "Scary", "unsafe", "Risk" — names a
  concern and belongs with it. Reserve *No reason given* for refusals and
  non-answers: "No comment", "na", "I can not explain it".

Write the assignments out as an explicit index → theme mapping, then script the
paste-in. That is safer than retyping and cannot alter the text.

**Key every row to its index.** A positional list of codes — one per response,
no indices — silently shifts every assignment after a miscount, and the totals
still look plausible. That happened on `uncertain`: 1,660 codes emitted for
1,630 responses. Ten codes per row with the starting index stated, and an
assert on the row length, makes the error impossible to miss.

### 5. Verify — read each theme's members together

**Not optional, and not a formality.** This pass exists because assignments
made one at a time drift. Print every response under a theme, together, and
read down the list asking whether they are making the same claim.

It also catches themes missed in pass 3 entirely. On `uncertain` it turned up
six responses citing fusion's clean-energy promise with no concern attached,
sitting in *No reason given* — they had given one, and there was no theme for
it. *Clean energy potential* exists because the verification pass found it.

On the `oppose` pass it caught three:

- "Scared" was filed under *No reason given* while "Scary" and "Scary stuff"
  sat under *Safety* — the same answer treated two ways.
- One response under *Prefer other energy sources* dismissed solar as well.
- One under *Security and weapons risk* led with "It sounds dangerous".

Then run the checker:

```sh
python3 <skill>/scripts/check_themes.py oppose <scratch>/oppose_raw.txt
```

`missing` and `extra` must be zero, and no theme may be `unlabelled`. It also
flags themes with one or two members — not an error, but look again in case
the response belongs elsewhere.

### 6. Write the files

`themes.csv` — `item, case_id, year, theme`, one row per response.
`theme_labels.csv` — `item, theme, label, theme_order`, one row per theme.

`theme_order` is the order the filter menu reads in; alphabetical is wrong for
the same reason it is wrong for the support bands. Order by frequency, with
*No reason given* and any "does not actually belong here" theme last.

Then `Rscript 03_create_open_response_data.R && Rscript 04_build_dashboard.R`.

## Rules that matter

**One theme per response.** The dominant concern. A response coded *Health
effects* may well also mention property values; the coding does not pretend
otherwise, and the page tells the reader as much.

**Small themes stay small.** *Security and weapons risk* has three members.
That is what the corpus contains, and padding it by pulling in adjacent
responses would misrepresent it. *Does not actually oppose* has one, and earns
its place by saying something true about the gate.

**The raw text is never edited.** Not for spelling, not for grammar, not for
length. The theme sits beside it; the reader can always see what was actually
written and disagree with the coding.

**`case_id` is the key and never ships.** It identifies a person. `03` joins on
it and drops it before writing the page's JSON. Coding by row index instead
would silently corrupt the moment a wave is added or the data is re-exported.

**All or nothing per item.** `03` halts if a coded item has any response
without a theme, because a half-coded item lets the theme filter hide whatever
was skipped without saying so.

## Coding a new item

Same six steps. The three why-items share a shape — they are three slices of
the same population, cut by where people sit on the support scales — so their
theme lists will overlap heavily but should not be copied across: what people
say when asked why they *support* something is not the mirror of why they
oppose it. Draft each from its own reading.

Coding `support` bore this out. Its themes are not the oppose list inverted:
*Willing to host it here* has no counterpart on the oppose side beyond a plain
refusal, and *Doubts it will be allowed to happen* — supporters who expect
industry or politics to block it — exists only here.

It also runs a much higher *No reason given* rate: 16% against opposition's
4.5%. That is the corpus, not the coding. An opposing answer almost always
names the thing feared; a supporting one is often just "It's a positive thing".
Watch for the temptation to rescue those into a theme they do not earn.

`ask` is a different kind of item entirely. Those are questions, not positions,
and the useful theme is what the person wants to know rather than what they
believe. The FU26 instrument promises these will be shared with people working
on fusion communication, so a theme list that helps that audience find their
own area is the point.

## Where the coding lives

`01_variable_reference/themes.csv` and `theme_labels.csv`, beside the codebook
and versioned with it. Small, readable as a diff, and reviewable by someone who
disagrees with a call — which is the whole reason it is a file rather than a
rule inside a script.
