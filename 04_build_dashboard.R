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
# Run after 02, from anywhere:
#   Rscript 04_build_dashboard.R
#
# Writes outputs/04_site/ — plain static files, fully self-contained. Preview:
#   python3 preview.py

data_in <- file.path(outputs, "02_question_data")
out <- file.path(outputs, "04_site")

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
  "<a href=\"https://www.ou.edu/ippra\">The University of Oklahoma's ",
  "Institute for Public Policy Research and Analysis</a>")

groupings_cfg <- splits |>
  transmute(id, label, phrase = if_else(is.na(phrase), list(NULL), as.list(phrase))) |>
  pmap(function(id, label, phrase) {
    if (is.null(phrase) || is.na(phrase)) list(id = id, label = label)
    else list(id = id, label = label, phrase = phrase)
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
  "run by ", INSTITUTE_LINK, ". This dashboard covers ", wave_line, ".</p>",
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
  "else - click <em>Show the R code</em> beneath it. Each script is written ",
  "for the plot in front of you: that question, that split, that version, ",
  "naming those columns and no others. It is generated by the same code that ",
  "produced the published estimates and re-checked against them on every ",
  "build, so what it draws is what you are looking at. It needs the ",
  "tidyverse and srvyr.</p>",
  "<p><strong>Contact.</strong> ",
  "<a href=\"mailto:jtr@ou.edu\">Joe Ripberger</a> at OU IPPRA.</p>")

config <- list(
  schema_version = 1,
  project = list(
    slug = "fusion",
    title = "Fusion Energy Survey - Explore the Data",
    nav_title = "Fusion Energy Survey",
    nav_subtitle = "IPPRA - University of Oklahoma"
  ),
  theme = list(default = "fusion", allow_viewer_switch = TRUE),
  groupings = groupings_cfg,
  explore_caption = list(
    answered = paste0("{n} US adults answered this question {waves}. Bars ",
                      "show the weighted percentage{split_clause} giving ",
                      "each answer."),
    waves_one = "in the {years} wave",
    waves_many = "across the {years} waves",
    split_clause = " of each {group_phrase}",
    smallest = " The smallest group, {smallest}, has {smallest_n} respondents.",
    dropped = paste0(" A further {dropped} answered the question but reported ",
                     "no {group_phrase}, and are not in the bars above."),
    multi_response = paste0("Respondents could pick more than one answer, so ",
                            "each bar is the share who chose that option and ",
                            "the bars do not add up to 100%."),
    asked_if = "Not everyone was asked: {condition}",
    arm = paste0("This is one of {n} versions of the question that were asked ",
                 "of different halves of the sample. Shown here: {prompt} - ",
                 "{label}. The menu above the chart switches between them."),
    provenance = paste0("From the IPPRA Fusion Energy Survey, run by ",
                        INSTITUTE_LINK, ". Each wave is weighted to national ",
                        "benchmarks, so the percentages describe US adults ",
                        "rather than only the people surveyed. This question ",
                        "is stored as <code>{variable}</code>.")
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
    list(id = "home", component = "fu_landing", label = "Home",
         hero = list(
           eyebrow = "IPPRA Fusion Energy Survey - University of Oklahoma",
           headline = paste0("What do Americans know, expect and want from ",
                             "fusion energy?"),
           sub = paste0("Nationally representative survey data on awareness, ",
                        "risk and benefit perceptions, siting, trust and ",
                        "regulation - with a companion study of subject ",
                        "matter experts to come."),
           cta_label = "Explore the survey questions",
           # The flagship chart: support for building fusion plants, asked in
           # both waves, on a scale a reader takes in at a glance.
           question = "new_fusion")),
    list(id = "explore", component = "explore",
         nav_group = "Public",
         label = "Explore Survey Data",
         questions = "data/questions.json", default_grouping = "All",
         intro = paste0("Click a question in the table below to see the ",
                        "weighted distribution of responses, split by the ",
                        "group you choose. Search matches question wording, ",
                        "the shared stem above a battery of items, the ",
                        "variable name and the topic tags."),
         # x_label titles the category axis and y_label the value axis, which
         # the horizontal layout swaps on screen but not in meaning.
         chart = list(x_label = "Response", y_label = "Respondents (%)"),
         blurb = paste0("Weighted response distributions for every closed-",
                        "ended question, split thirteen ways.")),
    list(id = "public-qual", component = "open_responses",
         nav_group = "Public",
         label = "Explore Open Responses",
         index = "data/open/index.json",
         words = "data/open/words.json",
         verbatims = "data/open/verbatims/{id}.json",
         intro = paste0("What people said in their own words. Words are ",
                        "counted exactly as they were typed and answers are ",
                        "shown whole. Where the responses have been read and ",
                        "coded, each carries one theme you can filter by; ",
                        "where they have not, no theme is shown rather than ",
                        "a guessed one."),
         blurb = paste0("Word associations, why people support or oppose ",
                        "fusion, and what they would ask an expert.")),
    list(id = "sme-survey", component = "placeholder",
         nav_group = "SMEs",
         label = "Explore Survey Data",
         intro = paste0("Survey responses from subject matter experts - ",
                        "people working on fusion energy and its regulation."),
         note = "This survey has not been fielded yet.",
         blurb = "Survey responses from subject matter experts."),
    list(id = "sme-qual", component = "placeholder",
         nav_group = "SMEs",
         label = "Explore Qualitative Data",
         intro = paste0("Interviews and open responses from subject matter ",
                        "experts."),
         note = "These have not been collected yet.",
         blurb = "Interviews and open responses from subject matter experts."),
    list(id = "about", component = "static_page", label = "About",
         html = about_html)
  ),
  footer = list(
    tagline = paste0("What US adults know, expect and want from fusion ",
                     "energy."),
    links_html = paste0(
      "<a href=\"#about\">About &amp; methods</a>",
      "<a href=\"https://ou.edu/ippra\">OU IPPRA</a>",
      "<a href=\"mailto:jtr@ou.edu\">Contact</a>"),
    funding = paste0("Supported by the University of Oklahoma's Institute ",
                     "for Public Policy Research and Analysis.")
  )
)

# A caption template naming a token the front end does not fill renders as an
# empty gap in a sentence, which reads as a missing number rather than a bug.
known_tokens <- c("n", "waves", "split_clause", "years", "group_phrase",
                  "smallest", "smallest_n", "dropped", "condition", "variable",
                  "multi_response", "prompt", "label")
used <- unlist(config$explore_caption) |>
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
