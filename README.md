# fusion_dash — the IPPRA Fusion Energy Survey dashboard

A static site that lets a reader explore every closed-ended question in the
IPPRA Fusion Energy Survey: the weighted distribution of responses, split by
any of thirteen groupings, with confidence intervals and a PDF export.

It is the Explore-the-Data half of [wxdash's production
dashboard](../wxdash/00_wxdash_2.0/11_dashboard) pointed at fusion data. The
front end is forked from that project and deliberately reduced — no map, no
landing page, no quiz — and the pipeline keeps the property that arrangement
buys: **the builder computes no statistics**, so the published site cannot
disagree with what was computed upstream.

## The pipeline

Scripts run in number order. Each sources `00_paths.R`, which resolves
everything against the project root — there is nothing machine-specific to
configure.

| step | what it is |
|---|---|
| `01_variable_reference/` | the codebook: `variable_reference.csv`, 152 rows, one per variable, **read off the instruments by hand**, plus `NOTES.md` and the procedure that produced it |
| `02_create_question_data.R` | the statistics: srvyr weighted distributions and 95% intervals for every question and split → `outputs/02_question_data/` |
| `03_build_dashboard.R` | the site: `config.json` plus the hand-edited front end in `site/` → `outputs/03_site/` |

```
data/FU25_data_wtd.csv          1,200 respondents, 117 columns
data/FU26_data_wtd.csv          1,244 respondents, 344 columns
        │
        │   01_variable_reference/variable_reference.csv
        │           152 rows, hand-authored from the instruments
        ▼
02_create_question_data.R       srvyr; seconds
        │
        ▼
outputs/02_question_data/       79 question files + catalog
        │
        ▼                       ┌── site/ (front end source)
03_build_dashboard.R  ◄─────────┘   no statistics
        │
        ▼
outputs/03_site/                the deployable site, 2.2 MB
```

## Building and previewing

```sh
Rscript 02_create_question_data.R          # after any data or reference change
Rscript 03_build_dashboard.R               # always; seconds
python3 -m http.server --directory outputs/03_site 8901
```

R packages: `tidyverse`, `srvyr`, `survey`, `jsonlite`, `here`. `xml2` and
Python 3 are needed only to re-extract instrument text when a wave is added.

Both scripts halt loudly rather than producing a quietly wrong site: a
reference row naming a column the data does not carry, a response code the
instrument does not document, a group the front end would sort into the wrong
order, a question in the catalog with no file behind it, a caption token
nothing fills, and R or survey data leaking into the published directory all
stop the build.

## The variable reference is read, not parsed

`01_variable_reference/variable_reference.csv` carries every question as it was
actually asked: wording, the stem it sits under, its response options, its show
condition, whether its stimulus was randomized, and which wave asked it under
which column name.

It was written by **reading both instruments end to end**, following
`.claude/skills/fusion-variable-reference/SKILL.md`. That skill exists because
the first attempt here was a regex parser: it reached about 90% and the last
10% was silently wrong. Extracting the text from Word is scripted; deciding
what the text means is not. Adding a wave means following the procedure, not
improvising.

`NOTES.md` beside it is the part someone acts on — what the instruments got
wrong, what must not be "fixed" because it is in the released data, and what
the documents could not settle. Read it before pooling the waves.

## What is in the dashboard

79 charts across eleven topics: 74 single-response questions and 5
select-all-that-apply batteries covering 38 items between them.

**Select-all batteries are one plot, not ten.** "Where have you heard about
fusion energy?" is a single chart whose categories are the ten sources and
whose bars are the share who ticked each — not ten charts reading "6% yes, 94%
no" that a reader has to hold in memory to compare. Those bars are each their
own proportion of the same people, so they do not sum to 100, and the caption
says so. Items are ranked by share with the most-picked at the top, taken from
the overall distribution and held fixed across splits so changing the split
re-colours the chart rather than reshuffling it — and "Other (please specify)"
is pinned to the bottom whatever its share, because it is where the rest went
rather than a finding that beat the options above it.

Membership is declared in the reference's `battery` column rather than inferred
from the shared stem, and `02` halts if a battery's items disagree about which
waves asked them or who was shown them.

Two kinds of row are in the reference but not in the dashboard. Verbatims, the
numeric-entry investment splits, the consent item, the attention screener and
the randomization assignments carry no response distribution to draw. And
**background items are held back** — the personal characteristics the survey
collects to describe respondents rather than to report: gender, race, income,
education, party, ideology and trust in government. They earn their place as
splits, which is where they appear. That filter is one line in `02`, keyed on
the reference's `question_focus` column, so putting an item back is a matter of
changing its classification in the sheet rather than special-casing it in code.

**Thirteen splits**, declared once in `02_create_question_data.R`: Everyone,
seven demographics, party identification, 2024 vote, ideology, climate-change
belief, and survey year. The demographics come from the vendor's derived
columns rather than FU26's self-reported items, because FU25 has no
self-reported demographics — splitting on the FU26 items would drop 2025
without saying so.

**Pooling.** A question asked in both waves is one entry whose chart pools
them; the survey-year split takes them apart. Where a wave did not ask a
question the split is simply absent, and the front end falls back to Everyone
rather than drawing an empty panel.

**Split-sample items** are marked above the chart. Thirteen questions varied
what the respondent read — a facility 10 or 50 miles away, a laboratory named
generically or specifically, a spending question asked with and without
background information, three different regulatory proposals. A single
percentage over those averages across the thing the experiment was built to
measure, and the chart says so rather than leaving the reader to find out.

**Respondents dropped by a split** are stated in the caption, not absorbed. A
caption that says 2,444 answered while the bars rest on 2,439 is the quiet
difference this pipeline exists to avoid.

## The front end

`site/` is hand-edited source: `engine.js`, `engine.css`, `index.html`, and
vendored Chart.js and jsPDF. `03_build_dashboard.R` copies it, fills the
`__BUILD__` cache-busting stamp, drops anything hidden, and refuses to publish
a built site containing `.R`, `.csv` or `.docx` files. A run takes seconds, so
iterating on the front end is cheap.

The engine was forked 2026-08-21 from wxdash's `11_dashboard/site/engine.js`.
The map explorer, landing page and quiz are gone, along with Leaflet and the
map half of the PDF export. The class prefix is `fu-` where the original uses
`wx-`. The table, chart, error-bar and PDF code is otherwise close enough that
a fix in either is worth carrying to the other.

The PDF download is a document rather than a screenshot: title, subtitle, the
plot, and the page's own caption set underneath — read off the rendered DOM, so
a download cannot say something the screen does not.

## Deploying

`outputs/03_site/` is the rsync unit — plain static files, no server code, no
third-party requests, every library vendored.

```sh
rsync -av --delete outputs/03_site/ <host>:<docroot>/fusion/
```

Relative URLs and hash routing mean moving hosts needs no change to the site.
Every asset URL carries a `?v=<build>` stamp, so long-lived host caches roll
over on each deploy — but `index.html` itself must be served with
`Cache-Control: no-cache`. It is the one file that cannot version-stamp itself,
and a host that caches it hard keeps serving the old `?v=` references, making
new deploys invisible until a hard refresh.

## Known cleanup

- `site/engine.css` still carries roughly 130 lines of rules for the map, scan
  sheet, landing page and quiz components the fork dropped. Harmless, and worth
  stripping the next time the stylesheet is opened for another reason.
- `rand_spend_comp` is not released as a column in FU25; the assignment has to
  be read off which of `govspend_fusion_exp_a` / `_b` is populated. See
  `NOTES.md`.
