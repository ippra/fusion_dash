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

about_html <- paste0(
  "<h2>About this dashboard</h2>",
  "<p><strong>The survey.</strong> The IPPRA Fusion Energy Survey asks US ",
  "adults what they know, expect and want from fusion energy: whether they ",
  "have heard of it, how they weigh its risks, costs and benefits, whether ",
  "they would support a facility near where they live, whom they would trust ",
  "for information about it, and how they think it should be regulated. It is ",
  "run by the ", INSTITUTE_LINK, ". This dashboard covers ", wave_line, ".</p>",
  "<p><strong>Weighting.</strong> Each wave is weighted to national ",
  "benchmarks, so the percentages describe US adults rather than only the ",
  "people who took the survey. Where a question was asked in both waves the ",
  "chart pools them; the <em>Survey year</em> split takes them apart.</p>",
  "<p><strong>Split-sample items.</strong> Some questions were deliberately ",
  "asked in more than one form - a facility 10 or 50 miles away, a laboratory ",
  "named generically or specifically, a spending question asked with and ",
  "without background information, three different regulatory proposals. ",
  "Those items are marked <em>Split-sample item</em> above the chart, because ",
  "a single percentage over them averages across the thing the experiment was ",
  "built to measure.</p>",
  "<p><strong>Caution.</strong> These data, like most survey data, come from ",
  "non-probability samples that are not necessarily representative of the ",
  "entire US population. Use caution when making inferences and drawing ",
  "conclusions.</p>",
  "<p><strong>Where the questions come from.</strong> Every question, response ",
  "option and show condition on this site is read off the survey instruments ",
  "themselves and recorded in <code>variable_reference.csv</code>, alongside ",
  "<code>NOTES.md</code>, which lists what the instruments got wrong and what ",
  "still needs checking.</p>",
  "<p><strong>Reproducing a chart.</strong> Every chart on the survey page ",
  "carries the R that rebuilds it from the released data files and nothing ",
  "else - <em>Download R code</em>, beside the chart download. Each script is ",
  "written for the plot in front of you: that question, that split, that ",
  "version, naming those columns and no others. It is generated by the same ",
  "code that produced the published estimates and re-checked against them on ",
  "every build, so what it draws is what you are looking at. It needs the ",
  "tidyverse and srvyr.</p>",
  "<p><strong>Contact.</strong> ",
  "<a href=\"mailto:jtr@ou.edu\">Joe Ripberger</a> at OU IPPRA.</p>")

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
    weighted_pct = paste0("Percentages are weighted so results represent US ",
                          "adults as a whole, not just the people who ",
                          "happened to take the survey. Intervals are 95% ",
                          "confidence intervals."),
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
         questions = "data/questions.json", default_grouping = "All",
         # What the page opens on. Row 1 is whatever the survey asked first -
         # a word association - which is a poor first impression of a survey
         # about what people know and expect.
         default_question = "fusion_know",
         intro = paste0("Click a question in the table below to view the ",
                        "weighted distribution of public responses by the ",
                        "group you select."),
         # x_label titles the category axis and y_label the value axis, which
         # the horizontal layout swaps on screen but not in meaning.
         chart = list(x_label = "Response", y_label = "Respondents (%)"),
         blurb = "Charts and summaries of survey responses."),
    list(id = "public-qual", component = "open_responses",
         nav_group = "Public Perspectives",
         label = "Open Responses",
         index = "data/open/index.json",
         words = "data/open/words.json",
         verbatims = "data/open/verbatims/{id}.json",
         intro = paste0("What people said in their own words. Words are ",
                        "counted exactly as they were typed and answers are ",
                        "shown whole. Where the responses have been read and ",
                        "coded, each carries one theme you can filter by; ",
                        "where they have not, no theme is shown rather than ",
                        "a guessed one."),
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
         intro = paste0("Click a question in the table below to view the raw ",
                        "(unweighted) distribution of expert responses by the ",
                        "group you select."),
         chart = list(x_label = "Response", y_label = "Experts (%)"),
         value_tip = paste0("Percentages are plain counts of the experts who ",
                            "answered - this sample is not weighted, because ",
                            "it is people identified as having relevant ",
                            "expertise rather than a sample of a wider ",
                            "population. Intervals are 95% confidence ",
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
         index = "data/sme-open/index.json",
         words = "data/sme-open/words.json",
         verbatims = "data/sme-open/verbatims/{id}.json",
         intro = paste0("What experts said in their own words: what they ",
                        "think non-experts most misunderstand about fusion, ",
                        "what they would change about how it is discussed, ",
                        "and the words they expected the public to reach for. ",
                        "Every response was read before publication. Nothing ",
                        "here is weighted: these are counts of the ",
                        sme_meta$respondents, " experts who answered, not ",
                        "estimates for any population."),
         blurb = "Responses written in participants\u2019 own words."),
    list(id = "sme-compare", component = "comparison",
         label = "Comparisons",
         source = "data/sme/comparisons.json",
         intro = paste0("Slide through the findings below. They come in ",
                        "three parts, and the difference matters. Part one ",
                        "is questions both groups answered, so a gap is a ",
                        "difference of view. Part two is experts predicting ",
                        "what the public said, so a gap is a mistake and the ",
                        "public column is the answer. Part three is a ",
                        "parallel question put to each side from its own ",
                        "position - what the public wants explained against ",
                        "what experts think it needs - so a gap there is a ",
                        "mismatch of agenda. Every card links to the pages ",
                        "where the underlying data lives. Expert figures are ",
                        "unweighted counts of ", sme_meta$respondents,
                        " people; public figures are weighted to the ",
                        "population."),
         blurb = paste0("Where expert expectations about public opinion match ",
                        "the survey, and where they miss.")),
    list(id = "about", component = "static_page", label = "About",
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
