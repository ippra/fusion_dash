library(tidyverse)
library(jsonlite)

source(here::here("00_paths.R"))

# Dashboard Assembly -----------------------------------------------------------
# The BUILDER half of the pipeline. Assembles the deployable site from what
# 02_create_question_data.R computed plus the hand-edited front end in site/.
#
# This script calculates NO statistics: every percentage and confidence
# interval is 02's output carried over verbatim, so the published site cannot
# disagree with what 02 computed. The property is true by construction rather
# than enforced by a harness, and a calculation added here gives it up.
#
# What it adds is presentation: config.json — the page, the split roster with
# caption phrases, the popover texts, and the caption {token} templates the
# front end fills at render time.
#
# Run last, after 02, 03, 04 and 05:
#   Rscript 06_build_dashboard.R
#
# Writes outputs/06_site/ — plain static files, fully self-contained. Preview:
#   python3 preview.py

data_in <- file.path(outputs, "02_question_data")
out <- file.path(outputs, "06_site")

needed <- file.path(data_in, c("questions.json", "splits.json", "meta.json"))
if (!all(file.exists(needed))) {
  print(needed[!file.exists(needed)])
  stop("Files above are missing - run 02_create_question_data.R first.")
}

if (!dir.exists(site_src)) {
  stop("No site source at ", site_src, " - the site/ directory moved.")
}

# Rebuilt from scratch each run: a question dropped upstream must not survive
# here as a stale file the table no longer lists but a ?q= link still reaches.
unlink(out, recursive = TRUE)
dir.create(file.path(out, "data", "q"), recursive = TRUE)

wjson <- function(x, path, pretty = FALSE) {
  write_json(x, file.path(out, path), pretty = pretty, auto_unbox = TRUE,
             na = "null", digits = NA)
}

# Open Responses ---------------------------------------------------------------
# Copied through unchanged, like the question data: 03 counts and screens, this
# script only moves the result.
open_in <- file.path(outputs, "03_open_responses")
if (!file.exists(file.path(open_in, "index.json"))) {
  stop("No open-response data - run 03_create_open_response_data.R first.")
}
dir.create(file.path(out, "data", "open", "verbatims"), recursive = TRUE)
invisible(file.copy(list.files(open_in, pattern = "\\.json$", full.names = TRUE),
                    file.path(out, "data", "open")))
invisible(file.copy(
  list.files(file.path(open_in, "verbatims"), full.names = TRUE),
  file.path(out, "data", "open", "verbatims")))

# The expert survey's own qualitative output, carried the same way. 05 counts,
# screens and applies the content review; this script only moves the result.
sme_open_in <- file.path(outputs, "05_sme_open_responses")
if (!file.exists(file.path(sme_open_in, "index.json"))) {
  stop("No expert open-response data - run ",
       "05_create_sme_open_response_data.R first.")
}
dir.create(file.path(out, "data", "sme-open", "verbatims"), recursive = TRUE)
invisible(file.copy(
  list.files(sme_open_in, pattern = "\\.json$", full.names = TRUE),
  file.path(out, "data", "sme-open")))
invisible(file.copy(
  list.files(file.path(sme_open_in, "verbatims"), full.names = TRUE),
  file.path(out, "data", "sme-open", "verbatims")))

# Question Data ----------------------------------------------------------------
# Copied through unchanged - these ARE the statistics, and they stay 02's.
q_files <- list.files(file.path(data_in, "q"), full.names = TRUE)
if (length(q_files) == 0) stop("No question files in ", data_in, "/q.")
invisible(file.copy(q_files, file.path(out, "data", "q")))
# The reproduction scripts, one file per question, fetched only when a reader
# opens the code panel. Kept out of the question file so a chart nobody clicks
# through costs nothing extra to load.
rcode_files <- list.files(file.path(data_in, "rcode"), pattern = "\\.json$",
                          full.names = TRUE)
dir.create(file.path(out, "data", "rcode"), recursive = TRUE,
           showWarnings = FALSE)
invisible(file.copy(rcode_files, file.path(out, "data", "rcode")))
invisible(file.copy(file.path(data_in, "questions.json"),
                    file.path(out, "data", "questions.json")))
invisible(file.copy(file.path(data_in, "meta.json"),
                    file.path(out, "data", "meta.json")))

# SME Data ---------------------------------------------------------------------
# The expert survey, carried through the same way and kept in its own directory.
# It is a different survey, not another wave: unweighted, 153 purposive
# respondents, its own question sheet. Mixing it into data/q would let a ?q=
# link cross between them.
sme_in <- file.path(outputs, "04_sme_data")
if (!file.exists(file.path(sme_in, "questions.json"))) {
  stop("No SME data - run 04_create_sme_data.R first.")
}
dir.create(file.path(out, "data", "sme", "q"), recursive = TRUE)
invisible(file.copy(list.files(file.path(sme_in, "q"), full.names = TRUE),
                    file.path(out, "data", "sme", "q")))
# The expert survey's reproduction scripts, carried the same way and kept in
# their own directory: 04 wrote them, and a page reads the ones belonging to
# the survey it is showing.
dir.create(file.path(out, "data", "sme", "rcode"), recursive = TRUE,
           showWarnings = FALSE)
invisible(file.copy(list.files(file.path(sme_in, "rcode"), pattern = "\\.json$",
                               full.names = TRUE),
                    file.path(out, "data", "sme", "rcode")))
invisible(file.copy(
  list.files(sme_in, pattern = "\\.json$", full.names = TRUE),
  file.path(out, "data", "sme")))
sme_catalog <- read_json(file.path(sme_in, "questions.json"),
                         simplifyVector = TRUE)
sme_meta <- read_json(file.path(sme_in, "meta.json"), simplifyVector = TRUE)

catalog <- read_json(file.path(data_in, "questions.json"), simplifyVector = TRUE)
splits <- read_json(file.path(data_in, "splits.json"), simplifyVector = TRUE)
meta <- read_json(file.path(data_in, "meta.json"), simplifyVector = TRUE)
message("Questions carried over: ", length(q_files))

# Every question the table lists must have a file behind it, and every file
# must be listed. Either way round is a dead link rather than a visible error.
listed <- catalog$id
present <- str_remove(basename(q_files), "\\.json$")
mismatch <- c(setdiff(listed, present), setdiff(present, listed))
if (length(mismatch) > 0) {
  print(mismatch)
  stop("Questions above are in the catalog without a file, or the reverse.")
}

# Config -----------------------------------------------------------------------
# What the builder authors: the page, the split roster, the caption templates
# and the popover texts. Everything with a number in it is a {token} the front
# end fills from the question file, so no sentence here can state a figure the
# data does not carry.
INSTITUTE_LINK <- paste0(
  "<a href=\"https://www.ou.edu/ippra\">University of Oklahoma\u2019s ",
  "Institute for Public Policy Research and Analysis</a>")

groupings_cfg <- splits |>
  transmute(id, label, category,
            phrase = if_else(is.na(phrase), list(NULL), as.list(phrase))) |>
  pmap(function(id, label, category, phrase) {
    out <- list(id = id, label = label)
    if (!is.na(category)) out$category <- category
    if (!is.null(phrase) && !is.na(phrase)) out$phrase <- phrase
    out
  })

wave_line <- meta$waves |>
  mutate(text = paste0(year, " (", format(n, big.mark = ","), " respondents)")) |>
  pull(text) |>
  paste(collapse = " and ")

# Every count in the prose is read rather than typed: the two public waves
# come from 02's meta, the expert n from 04's. An About page carrying a number
# nothing computes is the one place a stale figure would never be noticed.
n25 <- format(meta$waves$n[meta$waves$year == 2025], big.mark = ",")
n26 <- format(meta$waves$n[meta$waves$year == 2026], big.mark = ",")
n_sme <- format(sme_meta$respondents, big.mark = ",")

# One survey's panel: the year and n as a figure a reader can take in at a
# glance, then what it measured. The counts come from the pipeline's meta, so
# a panel cannot state a sample size the site disagrees with.
survey_panel <- function(kicker, n, who, body) {
  paste0(
    "<div class=\"fu-survey\">",
    "<p class=\"fu-survey-kicker\">", kicker, "</p>",
    "<p class=\"fu-survey-n\">", n, "</p>",
    "<p class=\"fu-survey-who\">", who, "</p>",
    "<p class=\"fu-survey-body\">", body, "</p>",
    "</div>")
}

# Each section of the site, linked. A reader who has just been told what
# Comparisons holds should be one click from it rather than back at the nav.
section_link <- function(href, label, body) {
  paste0("<a class=\"fu-about-link\" href=\"", href, "\">",
         "<span class=\"fu-about-link-name\">", label, "</span>",
         "<span class=\"fu-about-link-body\">", body, "</span></a>")
}

about_html <- paste0(
  "<p class=\"fu-about-lede\">The Fusion Energy Socio-Technical Observatory ",
  "is a long-term research effort led by the ", INSTITUTE_LINK, " (IPPRA) and ",
  "supported by the U.S. Department of Energy. The Observatory studies how ",
  "the public and fusion energy experts understand, evaluate, and communicate ",
  "about fusion energy. Its goal is to provide the evidence needed to improve ",
  "science communication, public engagement, and decision-making as fusion ",
  "technologies continue to develop.</p>",

  "<p>This site provides interactive access to the Observatory\u2019s survey ",
  "data, allowing users to explore public opinion, expert perspectives, and ",
  "the communication gaps between them.</p>",

  "<hr>",
  "<h3>The surveys</h3>",
  "<p>The Observatory currently includes three complementary surveys.</p>",
  "<div class=\"fu-survey-grid\">",
  survey_panel("Public survey \u00b7 2025", n25, "U.S. adults", paste0(
    "A nationally representative survey conducted in partnership with ",
    "Verasight, measuring public awareness of fusion energy, perceptions of ",
    "its risks, costs, and benefits, support for research and deployment, ",
    "trust in information sources, and related topics.")),
  survey_panel("Public survey \u00b7 2026", n26, "U.S. adults", paste0(
    "A second nationally representative survey, also conducted with ",
    "Verasight, that repeated many of the 2025 questions while expanding ",
    "coverage of communication priorities and policy issues.")),
  survey_panel("Expert survey \u00b7 2026", n_sme, "fusion experts", paste0(
    "Experts drawn from academia, national laboratories, government, and ",
    "private industry, asked about their own assessments of fusion energy, ",
    "their expectations for the technology\u2019s future, and their ",
    "predictions of how the public responded to the public survey.")),
  "</div>",
  "<p>Together, these surveys make it possible to compare what the public ",
  "believes, what experts believe, and what experts think the public ",
  "believes.</p>",

  "<hr>",
  "<h3>Using this site</h3>",
  "<p>The site is organized into three sections.</p>",
  "<div class=\"fu-about-links\">",
  section_link("#explore", "Public Perspectives", paste0(
    "Nationally representative results from the 2025 and 2026 public ",
    "surveys.")),
  section_link("#sme-survey", "Expert Perspectives",
               "Results from the 2026 expert survey."),
  section_link("#sme-compare", "Comparisons", paste0(
    "The two side by side, highlighting where opinions differ, where experts ",
    "accurately understand public opinion, and where communication ",
    "priorities diverge.")),
  "</div>",
  "<p>Open-ended responses are displayed exactly as respondents submitted ",
  "them. Where thematic coding is available, responses can also be explored ",
  "by theme.</p>",

  "<hr>",
  "<h3>Interpreting the results</h3>",
  "<p>Public survey results are weighted to national demographic benchmarks ",
  "so that estimates represent U.S. adults rather than only the people who ",
  "completed the surveys. Where questions were asked in both public surveys, ",
  "results are pooled by default; selecting <em>Survey year</em> displays ",
  "each wave separately.</p>",
  "<p>Some questions were intentionally asked in multiple versions as part ",
  "of survey experiments. These are identified as <em>Split-sample items</em> ",
  "because the experimental wording affects how the results should be ",
  "interpreted.</p>",
  "<p>The expert survey was designed to understand expert perspectives ",
  "rather than estimate characteristics of a larger population of experts. ",
  "Accordingly, expert results are presented without weighting.</p>",

  "<div class=\"fu-about-note\">",
  "<p class=\"fu-about-note-label\">A note on interpretation</p>",
  "<p class=\"fu-about-note-body\">The public surveys were conducted using ",
  "nationally recruited online panels rather than probability samples. ",
  "Weighting improves representativeness across key demographic ",
  "characteristics, but, as with any survey, results should be interpreted ",
  "as estimates rather than exact population values.</p>",
  "</div>")

# The expert page's splits and caption. Separate from the public roster because
# the numbers mean something different: a share of 153 experts who answered,
# with no weighting, and a caption that says so instead of saying "weighted".
# 04's own roster, read rather than retyped. Declared once: sector, field and
# role would otherwise be a third place to keep in step.
sme_groupings <- read_json(file.path(sme_in, "splits.json"))
sme_caption <- list(
  answered = paste0("{n} experts answered this question {waves}. The bars ",
                    "show the raw (unweighted) distribution of ",
                    "responses{split_clause}."),
  waves_one = "in {years}",
  waves_many = "in {years}",
  split_clause = " by {group_phrase}",
  smallest = " The smallest group, {smallest}, has {smallest_n} experts.",
  dropped = paste0(" A further {dropped} answered the question but reported ",
                   "no {group_phrase}, and are not shown."),
  # Sector, field and role are select-all, so their groups are not exclusive.
  # Said in the caption because a reader adding the groups up would otherwise
  # find more experts than the survey has, and conclude the numbers are wrong.
  overlap = paste0(" These groups overlap: {overlap} of the {n} named more ",
                   "than one {group_phrase}, and are counted in each one ",
                   "they named."),
  multi_response = paste0("Experts could select more than one answer, so each ",
                          "bar is the share who chose that option and the ",
                          "bars do not sum to 100%."),
  answered_rank = paste0("{n} experts ranked these items {waves}. The bars ",
                         "show the mean placing{split_clause} - a LOWER ",
                         "number is a higher placing, not a percentage."),
  answered_mean_pct = paste0("{n} experts answered this question {waves}. The ",
                             "bar shows the mean percentage they ",
                             "gave{split_clause}, not a share of the experts."),
  rank_note = paste0("Experts who did not reach this question are left out ",
                     "rather than counted as unranked."),
  asked_if = "Not everyone was asked this question: {condition}",
  arm = "",
  provenance = paste0("Results are from the IPPRA Fusion Energy expert survey ",
                      "conducted by the ", INSTITUTE_LINK, ". The sample is ",
                      "people identified as having relevant expertise; it ",
                      "carries no weights and describes those experts rather ",
                      "than any wider population."),
  variable_line = "Variable: <code>{variable}</code>"
)

config <- list(
  schema_version = 1,
  project = list(
    slug = "fusion",
    title = "Fusion Energy Socio-Technical Observatory",
    nav_title = "Fusion Energy Socio-Technical Observatory",
    nav_subtitle = "IPPRA - University of Oklahoma"
  ),
  theme = list(default = "fusion", allow_viewer_switch = TRUE),
  groupings = groupings_cfg,
  explore_caption = list(
    answered = paste0("{n} U.S. adults answered this question {waves}. The ",
                      "bars show the weighted distribution of ",
                      "responses{split_clause}."),
    waves_one = "in the {years} survey wave",
    waves_many = "across the {years} survey waves",
    split_clause = " by {group_phrase}",
    smallest = " The smallest group, {smallest}, has {smallest_n} respondents.",
    dropped = paste0(" A further {dropped} answered the question but are not ",
                     "shown, having no value for this grouping."),
    multi_response = paste0("Respondents could select more than one answer, ",
                            "so each bar is the share who chose that option ",
                            "and the bars do not sum to 100%."),
    asked_if = "Not everyone was asked this question: {condition}",
    arm = paste0("This is one of {n} versions of the question, each asked of ",
                 "a different portion of the sample. Shown here: {prompt} - ",
                 "{label}. Use the menu above the chart to switch between ",
                 "them."),
    provenance = paste0("Results are from the IPPRA Fusion Energy Survey ",
                        "conducted by the ", INSTITUTE_LINK, ". Each survey wave ",
                        "is weighted to nationally representative ",
                        "demographic benchmarks."),
    variable_line = "Variable: <code>{variable}</code>"
  ),
  explainers = list(
    weighted_pct = paste0("Percentages are weighted to represent U.S. adults ",
                          "as a whole, not just the people who participated ",
                          "in the survey. Error bars show 95% confidence ",
                          "intervals."),
    experimental = paste0("<p>This question was not asked the same way of ",
                          "everyone. What varied might be a distance, the ",
                          "name of an organization, or a paragraph of ",
                          "background information shown to half the sample.</p>",
                          "<p>The bars still describe the people who answered, ",
                          "but they average across two or three versions of ",
                          "the question, so they are not a single population ",
                          "measure. The instrument records which.</p>")
  ),
  # Two audiences, each unfolding into a survey view and a qualitative view.
  # Only the public survey has data behind it so far; the other three are
  # placeholders that say so rather than empty shells that look broken.
  pages = list(
    # The landing page argues, and shows nothing. No chart and no headline
    # figure: a teaser plot invited a reader to judge the project on whichever
    # question happened to be on it, and a big number on the way in gives away
    # a finding before the reader knows why it should matter to them. The
    # copy's job is to make an expert want the finding, not to hand it over.
    # The landing page describes the programme and the instrument. No chart
    # and no headline figure: a teaser plot invited a reader to judge the
    # project on whichever question happened to be on it, and a finding on the
    # way in is spent before the reader knows what it bears on. The copy is
    # the project's own framing rather than a pitch written for the site -
    # this is a research programme and the page should read like one.
    # The landing page is the project summary, close to verbatim, with the
    # directory under it. No chart and no headline figure: a teaser plot
    # invited a reader to judge the project on whichever question happened to
    # be on it, and a finding on the way in is spent before the reader knows
    # what it bears on. The words are the proposal's own - see
    # `submission materials/project_summary.docx` - and if this is revised it
    # should be revised from there rather than rewritten for the site.
    list(id = "home", component = "fu_landing", label = "Home",
         hero = list(
           eyebrow = paste0("Socio-Technical Observatory - University of ",
                            "Oklahoma - supported by the U.S. Department ",
                            "of Energy"),
           headline = "Building the Social Foundation for Fusion Energy",
           lede = list(
             paste0("Fusion energy has the potential to transform the ",
                    "nation's energy future. Although substantial progress is ",
                    "being made to overcome the scientific and engineering ",
                    "challenges, successful deployment will also depend on ",
                    "effective science communication, informed public ",
                    "engagement, and evidence-based decision-making. This ",
                    "project examines how the public understands and ",
                    "evaluates fusion energy, how experts communicate its ",
                    "risks, costs, benefits, and timelines, and where gaps ",
                    "between the two may create barriers to informed ",
                    "discussion ",
                    "and policy.")),
           # What is here, in three: the two surveys and the comparison of
           # them. This replaced a five-row directory that listed the same
           # destinations as the nav bar sitting directly above it.
           actions = list(
             list(label = "The Public", page = "explore",
                  note = paste0("Nationally representative survey data on how ",
                                "Americans understand, evaluate, and respond ",
                                "to fusion energy.")),
             list(label = "Experts", page = "sme-survey",
                  note = paste0("Perspectives from researchers, engineers, ",
                                "regulators, and industry leaders on the ",
                                "future of fusion energy and its ",
                                "communication challenges.")),
             list(label = "Public vs. Experts", page = "sme-compare",
                  note = paste0("Side-by-side comparisons showing where ",
                                "expert expectations and public perceptions ",
                                "align\u2014and where they diverge most.")))),
         sections = list(
           list(columns = list(
             list(lead = "Why public acceptance matters",
                  body = paste0(
                    "Fusion energy will not succeed through scientific ",
                    "breakthroughs alone. Like other major energy ",
                    "technologies, its future depends on whether the public ",
                    "views it as beneficial, trustworthy, and worthy of ",
                    "continued investment. Public perceptions influence ",
                    "research funding, regulatory decisions, and the ",
                    "willingness of communities to host new facilities. As ",
                    "fusion moves from the laboratory to commercial ",
                    "deployment, understanding public concerns, expectations, ",
                    "and priorities will be essential for building and ",
                    "maintaining the social support needed to realize its ",
                    "potential.")),
             list(lead = "Why expert understanding matters",
                  body = paste0(
                    "Experts not only develop fusion technologies, they also ",
                    "explain them to policymakers, journalists, community ",
                    "leaders, and the public. Those conversations are shaped ",
                    "by assumptions about what non-experts already know, what ",
                    "they misunderstand, and what they care about. When those ",
                    "assumptions are inaccurate, communication can reinforce ",
                    "confusion, create unrealistic expectations, or overlook ",
                    "legitimate concerns. Measuring both expert understanding ",
                    "and expert perceptions of the public provides the ",
                    "evidence needed to develop communication strategies that ",
                    "accurately convey the risks, costs, benefits, and ",
                    "timelines associated with fusion energy."))))),
         colophon_html = paste0(
           "Primary contact: <a href=\"mailto:kuhikagupta@ou.edu\">Kuhika ",
           "Gupta</a>, University of Oklahoma.")),
         # No `blurb`, and absent rather than NULL: list() keeps a NULL
         # element, jsonlite writes it as {}, and {} is truthy in JavaScript -
         # the landing page listed itself in its own directory, with
         # "[object Object]" where the description goes.
    list(id = "explore", component = "explore",
         nav_group = "Public Perspectives",
         label = "Survey Results",
         # The title says what the page is; the paragraph under it says how to
         # use it. Both are authored here, like every other sentence.
         title = "How the public sees fusion energy",
         questions = "data/questions.json", default_grouping = "All",
         # What the page opens on. Row 1 is whatever the survey asked first -
         # a word association - which is a poor first impression of a survey
         # about what people know and expect.
         default_question = "fusion_know",
         intro = paste0("Survey results from the IPPRA Fusion Energy Survey, ",
                        "fielded with US adults in 2025 and 2026. Percentages ",
                        "are weighted to represent the country as a whole, ",
                        "and any question can be cut by demographic, ",
                        "political or energy-attitude groups. Click a ",
                        "question in the table below to view the weighted ",
                        "distribution of public responses by the group you ",
                        "select."),
         # x_label titles the category axis and y_label the value axis, which
         # the horizontal layout swaps on screen but not in meaning.
         chart = list(x_label = "Response", y_label = "Respondents (%)"),
         blurb = "Charts and summaries of survey responses."),
    list(id = "public-qual", component = "open_responses",
         nav_group = "Public Perspectives",
         label = "Open Responses",
         title = "The public in their own words",
         index = "data/open/index.json",
         # Word associations are hidden for now. The file is still
         # built and still shipped - restoring this line brings the
         # view back with it.
         # words = "data/open/words.json",
         verbatims = "data/open/verbatims/{id}.json",
         intro = paste0("What survey respondents wrote when the question ",
                        "left the answer to them: the questions they would ",
                        "put to a fusion expert, and their reasons for ",
                        "supporting, opposing or remaining unsure about ",
                        "fusion energy. Click an option in the menu below to ",
                        "explore public responses written in respondents\u2019 ",
                        "own words. Responses are shown exactly as they were ",
                        "submitted and can be filtered by theme where ",
                        "thematic coding is available."),
         blurb = "Responses written in participants\u2019 own words."),
    # The expert survey reuses the explore component - the question files have
    # the same shape - but reads its own directory and its own caption
    # templates, because 153 unweighted experts are not a population estimate
    # and the caption must not say they are.
    list(id = "sme-survey", component = "explore",
         nav_group = "Expert Perspectives",
         label = "Survey Results",
         questions = "data/sme/questions.json",
         question_dir = "data/sme/q",
         rcode_dir = "data/sme/rcode",
         groupings = sme_groupings,
         caption = sme_caption,
         default_grouping = "All",
         # "raw (unweighted)" carries the caveat the longer sentence used
         # to. What it does not carry - that a purposive sample of experts is
         # not a sample of any population - is in the caption under every
         # chart and in the value tooltip, which is where it belongs anyway.
         title = "How fusion experts see fusion energy",
         intro = paste0("Survey results from 153 people identified as having ",
                        "relevant fusion expertise, fielded in 2026. This is ",
                        "a separate survey rather than a third wave of the ",
                        "public one: the figures are counts of the experts ",
                        "who answered rather than estimates of any wider ",
                        "population, and can be cut by years in fusion work, ",
                        "sector, field and role. Click a question in the ",
                        "table below to view the raw ",
                        "(unweighted) distribution of expert responses by the ",
                        "group you select."),
         chart = list(x_label = "Response", y_label = "Experts (%)"),
         value_tip = paste0("Percentages are raw (unweighted) counts of the ",
                            "experts who answered. This sample is people ",
                            "identified as having relevant expertise, not a ",
                            "sample of a wider population, so it carries no ",
                            "weights. Error bars show 95% confidence ",
                            "intervals."),
         blurb = "Charts and summaries of survey responses."),
    # The same component the public page uses, pointed at the expert survey's
    # files. One code path rather than two: what differs between the surveys -
    # whether there is a valence scale, whether anything is weighted, whether
    # there is more than one fielding - is carried in the data, not in a second
    # copy of the component.
    list(id = "sme-qual", component = "open_responses",
         nav_group = "Expert Perspectives",
         label = "Open Responses",
         title = "Experts in their own words",
         index = "data/sme-open/index.json",
         # Word associations are hidden for now. The file is still
         # built and still shipped - restoring this line brings the
         # view back with it.
         # words = "data/sme-open/words.json",
         verbatims = "data/sme-open/verbatims/{id}.json",
         # The two claims this used to carry - that every response was read
         # before publication, and that nothing here is weighted - are in the
         # caption beside every item, which is where a reader meets them next
         # to the responses they qualify.
         intro = paste0("What experts wrote in their own words: what they ",
                        "think non-experts most misunderstand about fusion ",
                        "energy, and what they would change about how it is ",
                        "discussed. Click an option in the menu below to ",
                        "explore expert responses written in respondents\u2019 ",
                        "own words. Responses are shown exactly as they were ",
                        "submitted and can be filtered by theme where ",
                        "thematic coding is available."),
         blurb = "Responses written in participants\u2019 own words."),
    list(id = "sme-compare", component = "comparison",
         label = "Comparisons",
         title = "How experts and the public compare",
         source = "data/sme/comparisons.json",
         # Plain text now rather than intro_html: the sentence carries no
         # emphasis, and pageHead() takes either.
         intro = paste0(
           "Comparisons between the nationally representative 2025 and 2026 ",
           "public surveys and the 2026 Fusion Energy Expert Survey. ",
           "Findings are organized into three groups: where experts and the ",
           "public answered the same questions, where experts estimated ",
           "public opinion, and where the two identified different ",
           "communication priorities. Click through the cards below to ",
           "explore each finding and the underlying survey data."),
         # The card that opens each part. Authored here with the rest of the
         # page copy; these three were the last prose left in the engine.
         parts = list(
           list(part = 1L, label = "Part one",
                title = "What Each Group Thinks",
                blurb = paste0("Both experts and the public were asked the ",
                               "same questions. Differences reflect genuine ",
                               "differences in perspective. Neither group is ",
                               "right or wrong.")),
           list(part = 2L, label = "Part two",
                title = "What Experts Think the Public Thinks",
                blurb = paste0("Experts estimated how the public answered ",
                               "each question. Unlike Part One, differences ",
                               "here reflect the accuracy of those estimates ",
                               "rather than differences in opinion. The ",
                               "public results are the observed answers.")),
           list(part = 3L, label = "Part three",
                title = "What Each Side Thinks Needs Explaining",
                blurb = paste0("These final comparisons examine communication ",
                               "priorities. The public was asked what it most ",
                               "wants to understand before forming an opinion ",
                               "about fusion energy, while experts were asked ",
                               "what non-experts most need to understand. ",
                               "Differences between the two reveal where ",
                               "communication priorities diverge."))),
         blurb = paste0("Where expert expectations about public opinion match ",
                        "the survey, and where they miss.")),
    list(id = "about", component = "static_page", label = "About",
         title = "About the Fusion Energy Socio-Technical Observatory",
         html = about_html)
  ),
  footer = list(
    # What the Observatory is, and who runs and funds it. The tagline
    # described the two surveys; the surveys are an output of the programme
    # rather than the programme itself.
    tagline = paste0("Understanding how the public and fusion experts ",
                     "perceive the risks, costs, benefits, and future of ",
                     "fusion energy\u2014and where those perspectives ",
                     "diverge."),
    links_html = paste0(
      "<a href=\"#about\">About &amp; methods</a>",
      "<a href=\"https://ou.edu/ippra\">OU IPPRA</a>",
      "<a href=\"mailto:kuhikagupta@ou.edu\">Contact</a>"),
    funding = paste0("A project of the University of Oklahoma\u2019s ",
                     "Institute for Public Policy Research and Analysis, ",
                     "supported by the U.S. Department of Energy.")
  )
)

# The split menu groups consecutive runs of one category, so a category that
# appears twice in the roster renders as two headings with the same name.
cats <- splits$category[!is.na(splits$category)]
if (any(duplicated(rle(cats)$values))) {
  print(rle(cats)$values)
  stop("Split categories above are not contiguous in the roster; the menu ",
       "would show a heading twice.")
}

# A page opening on a question that does not exist falls back to row 1 without
# saying so, which reads as the setting having been ignored.
for (pg in config$pages) {
  if (is.null(pg$default_question)) next
  ids <- if (identical(pg$id, "sme-survey")) sme_catalog$id else catalog$id
  if (!pg$default_question %in% ids) {
    stop("Page '", pg$id, "' opens on '", pg$default_question,
         "', which is not in its question catalog.")
  }
}

# A caption template naming a token the front end does not fill renders as an
# empty gap in a sentence, which reads as a missing number rather than a bug.
known_tokens <- c("n", "waves", "split_clause", "years", "group_phrase",
                  "smallest", "smallest_n", "dropped", "overlap", "condition",
                  "variable", "multi_response", "prompt", "label")
# Both caption sets, not just the public one: the expert page brings its own,
# and a token the front end does not fill would print as "{total}" on screen.
used <- unlist(c(config$explore_caption, sme_caption)) |>
  str_extract_all("\\{(\\w+)\\}") |>
  unlist() |>
  str_remove_all("[{}]") |>
  unique()
unknown <- setdiff(used, known_tokens)
if (length(unknown) > 0) {
  print(unknown)
  stop("Caption tokens above are not filled by the front end.")
}

wjson(config, "config.json", pretty = TRUE)

# Site Files -------------------------------------------------------------------
# Everything under site/ is copied through: it is the hand-edited source, kept
# editable as itself rather than generated from R strings. index.html is the
# one exception - the __BUILD__ stamp is filled in so asset URLs bust
# long-lived host caches on every deploy.
BUILD <- format(Sys.time(), "%Y%m%d%H%M%S")
invisible(file.copy(list.files(site_src, full.names = TRUE), out,
                    recursive = TRUE, overwrite = TRUE))
index_html <- readLines(file.path(site_src, "index.html"))
writeLines(gsub("__BUILD__", BUILD, index_html), file.path(out, "index.html"))

# list.files() skips dotfiles at the top of site/, but the copy above descends
# into assets/ as whole directories, so macOS's .DS_Store rides along and is
# published. Dropped here rather than filtered on the way in, because the trap
# is anything hidden, not that one filename.
copied <- list.files(out, recursive = TRUE, all.files = TRUE, full.names = TRUE)
unlink(copied[startsWith(basename(copied), ".")])

# Guarded rather than trusted: nothing under site/ should be R or survey data,
# but either saved there by mistake would become readable on a public URL.
leaked <- list.files(out, pattern = "\\.([Rr]|csv|docx)$", recursive = TRUE)
if (length(leaked) > 0) {
  print(leaked)
  stop("Files above reached the built site - they must not be published.")
}

required <- c("index.html", "engine.js", "engine.css", "config.json",
              "data/questions.json", "data/meta.json",
              "data/open/index.json", "data/open/words.json",
              "assets/vendor/chart.umd.min.js",
              "assets/vendor/chartjs-plugin-datalabels.min.js",
              "assets/vendor/jspdf.umd.min.js")
absent <- required[!file.exists(file.path(out, required))]
if (length(absent) > 0) {
  print(absent)
  stop("Files above are missing from the built site.")
}

size_mb <- sum(file.size(list.files(out, recursive = TRUE,
                                    full.names = TRUE))) / 1024^2
message("Site written to ", out)
message("  build ", BUILD, ", ", length(q_files), " questions, ",
        round(size_mb, 1), " MB")
message("  preview: python3 preview.py")
