library(tidyverse)
library(srvyr)
library(jsonlite)

source(here::here("00_paths.R"))

# Question Data ----------------------------------------------------------------
# The statistics half of the pipeline. Reads the two weighted survey files and
# the variable reference, and writes one JSON file per question holding the
# weighted response distribution for every split, with 95% confidence
# intervals.
#
# This is the only script that computes anything. 03_build_dashboard.R carries
# these numbers over verbatim, so the site cannot disagree with what is
# computed here — the property wxdash's 10/11 split buys, kept for the same
# reason.
#
# Run after any change to the reference or the data:
#   Rscript 02_create_question_data.R
#
# Writes outputs/02_question_data/.

out <- file.path(outputs, "02_question_data")
unlink(out, recursive = TRUE)
dir.create(file.path(out, "q"), recursive = TRUE)
dir.create(file.path(out, "rcode"), recursive = TRUE)

# ref_row is the sheet's own row order, which is survey order: FU26's sequence
# with each FU25-only block placed where FU25 asked it. The question table is
# sorted by it, so a reader meets the questions in the order respondents did.
reference <- read_csv(variable_reference, guess_max = Inf,
                      show_col_types = FALSE) |>
  mutate(ref_row = row_number())

# Experiment Arms --------------------------------------------------------------
# Which version of a split-sample question each respondent read, declared
# rather than matched on the raw value: rand_lab records the same arm as "US
# national laboratories..." in 2025 and "U.S. national laboratories..." in
# 2026, so string equality would split one arm into two and neither half would
# say so.
arms_table <- read_csv(arms_reference, col_types = cols(
  arm_variable = col_character(), prompt = col_character(),
  wave = col_character(), value = col_character(), arm_id = col_character(),
  label = col_character(), arm_order = col_integer()
))

if (n_distinct(arms_table$prompt[arms_table$arm_variable ==
                                 arms_table$arm_variable[1]]) > 1) {
  stop("An arm variable has more than one prompt.")
}

# An arm id must mean the same thing in every wave, or the toggle would pool
# two different questions under one label.
inconsistent <- arms_table |>
  summarise(labels = n_distinct(label), .by = c(arm_variable, arm_id)) |>
  filter(labels > 1)
if (nrow(inconsistent) > 0) {
  print(inconsistent)
  stop("Arm ids above carry different labels in different waves.")
}

# Splits -----------------------------------------------------------------------
# The roster the dashboard offers, declared once. Everything here must exist,
# or be derivable, in BOTH waves: a split that only one wave carries would
# quietly show a single year's respondents under a label that says otherwise.
#
# The seven demographics come from the vendor's derived columns rather than the
# self-reported items, because FU25 has no self-reported demographics at all —
# it took them from the sample frame. Splitting on FU26's own gend/race/edu
# items would drop 2025 without saying so.
#
# `source` names the survey variable a split is built from, where there is one.
# It exists to suppress the tautology: splitting the ideology question by
# ideology draws one bar at 100% in every group, which looks like a finding and
# is an identity. The vendor-derived demographics have no `source` because the
# FU26 items that resemble them (gend, race, edu, income, party) are separate
# questions, so crossing them is a real comparison rather than a restatement.
splits <- tribble(
  ~id,             ~label,                  ~phrase,                     ~source,
  "All",           "Everyone",              NA_character_,               NA_character_,
  "Age",           "Age",                   "age group",                 NA_character_,
  "Gender",        "Gender",                "gender",                    NA_character_,
  "Race",          "Race and ethnicity",    "race and ethnicity group",  NA_character_,
  "Education",     "Education",             "education group",           NA_character_,
  "Income",        "Income",                "income group",              NA_character_,
  "Region",        "Census region",         "census region",             NA_character_,
  "Metro",         "Metropolitan status",   "community type",            NA_character_,
  "Party_ID",      "Party identification",  "party group",               NA_character_,
  "Vote_2024",     "2024 presidential vote", "vote group",               NA_character_,
  "IDEOL_GROUP",   "Ideology",              "ideology group",            "ideol",
  "GCC_GROUP",     "Climate change belief", "belief group",              "gcc",
  "survey_year",   "Survey year",           "survey year's respondents", NA_character_
)

# Two splits are built rather than read. The banding follows the instrument's
# own labels: ideol 1-3 are the three liberal categories, 4 is "Middle of the
# road", 5-7 are the three conservative ones. Collapsing to three groups is a
# judgment - seven groups on a bar chart is unreadable - and it is made here,
# once, rather than in the front end.
derive_groups <- function(d) {
  d |>
    mutate(
      IDEOL_GROUP = case_when(
        ideol %in% 1:3 ~ "Liberal",
        ideol == 4     ~ "Moderate",
        ideol %in% 5:7 ~ "Conservative",
        TRUE           ~ NA_character_
      ),
      GCC_GROUP = case_when(
        gcc == 1 ~ "Greenhouse gases are warming the planet",
        gcc == 0 ~ "They are not",
        TRUE     ~ NA_character_
      )
    )
}

# Group orders the front end must not re-sort alphabetically. Ordinal splits
# read wrong in any other order, and "Liberal, Moderate, Conservative" is not
# alphabetical in any locale.
group_order <- list(
  Age = c("18-29", "30-49", "50-64", "65+"),
  Education = c("HS or less", "Some college/2-yr degree",
                "4-yr/post-graduate degree"),
  Income = c("< $50,000", "> $50,000"),
  IDEOL_GROUP = c("Liberal", "Moderate", "Conservative"),
  GCC_GROUP = c("Greenhouse gases are warming the planet", "They are not"),
  Party_ID = c("Democrat", "Independent", "Republican")
)

# Reading the Waves ------------------------------------------------------------
# Every column read as character and converted per question, because the two
# files type the same item differently once a wave has a column that is empty
# for its first thousand rows. guess_max = Inf would fix the guessing; reading
# as character removes the guess.
read_wave <- function(path) {
  read_csv(path, col_types = cols(.default = col_character()),
           na = c("", "NA"), guess_max = Inf)
}

waves_data <- waves |>
  mutate(raw = map(data, read_wave))

message("Waves read: ",
        paste0(waves$wave, " n=", map_int(waves_data$raw, nrow),
               collapse = ", "))

# Every split column must be present in every wave before anything is
# computed, not discovered missing halfway through 126 questions.
split_columns <- setdiff(splits$id, c("All", "survey_year", "IDEOL_GROUP",
                                      "GCC_GROUP"))
for (i in seq_len(nrow(waves_data))) {
  have <- names(waves_data$raw[[i]])
  gone <- setdiff(c(split_columns, "ideol", "gcc", weight_var), have)
  if (length(gone) > 0) {
    print(gone)
    stop("Columns above are missing from ", waves_data$wave[i], ".")
  }
}

# One long frame: respondent, wave, weight, every split, every answer. Built
# once so each question is a filter rather than a re-read.
responses <- map2(waves_data$raw, seq_len(nrow(waves_data)), function(d, i) {
  d |>
    derive_groups() |>
    transmute(
      survey_year = as.character(waves_data$year[i]),
      wave = waves_data$wave[i],
      weight = as.numeric(.data[[weight_var]]),
      All = "All",
      across(all_of(c(split_columns, "IDEOL_GROUP", "GCC_GROUP"))),
      row = row_number()
    ) |>
    bind_cols(d |> select(-any_of(c(split_columns, weight_var))))
}) |>
  bind_rows()

if (anyNA(responses$weight)) {
  stop(sum(is.na(responses$weight)), " respondents have no weight - a ",
       "weighted percentage over them would silently drop them.")
}

# Questions --------------------------------------------------------------------
# Closed-ended items only. Verbatims, the numeric-entry investment splits, the
# consent item, the attention screener and the randomization assignments all
# carry either no options or no question, and none of them is something a
# reader would explore.
#
# Background items are excluded too - the personal characteristics the survey
# collects to describe respondents rather than to report: gender, race,
# income, education, party, ideology and trust in government. They earn their
# place as splits, which is where they appear, not as findings. Nothing is
# deleted: the rows stay in the variable reference so the record of the
# instrument is complete.
# A show condition the reader can act on. The sheet keeps the instrument's own
# `fusion_know = 1`; the dashboard shows `asked_if_plain`, which says the same
# thing in words. A condition with no plain text would print nothing where a
# caveat belongs, so it stops the build instead.
unplained <- reference |> filter(!is.na(asked_if), is.na(asked_if_plain))
if (nrow(unplained) > 0) {
  print(unplained |> select(variable, asked_if))
  stop("Rows above have a show condition with no asked_if_plain.")
}

eligible <- reference |>
  filter(question_type %in% c("question", "checkbox_item"), n_options >= 2,
         question_focus != "background")

background <- reference |>
  filter(question_type %in% c("question", "checkbox_item"), n_options >= 2,
         question_focus == "background")

# Single-response questions, one plot each.
questions <- eligible |> filter(is.na(battery))

# Select-all-that-apply items are a battery, not ten questions. Drawn one plot
# each they are ten charts of "6% yes, 94% no" that a reader has to hold in
# memory to compare; drawn together they are the one thing the battery asks -
# which of these did people pick. Membership is declared in the reference
# rather than inferred from the shared stem, so editing one item's wording
# cannot silently split a battery in two.
batteries <- eligible |>
  filter(!is.na(battery)) |>
  group_split(battery)
names(batteries) <- map_chr(batteries, ~.x$battery[1])

# Every item in a battery must sit under the same stem and have been asked in
# the same waves. Either failing means the battery is really two.
for (b in batteries) {
  if (n_distinct(b$question_intro) > 1) {
    print(unique(b$question_intro))
    stop("Battery ", b$battery[1], " spans more than one stem.")
  }
  # Each wave either asked every item in the battery or none of them.
  consistent <- map_lgl(waves$column, ~n_distinct(is.na(b[[.x]])) == 1)
  if (!all(consistent)) {
    print(b |> select(variable, all_of(waves$column)))
    stop("Battery ", b$battery[1], " was not asked in the same waves ",
         "throughout - its items would rest on different samples.")
  }
}

message("Questions to build: ", nrow(questions), " single-response + ",
        length(batteries), " select-all batteries (",
        sum(map_int(batteries, nrow)), " items), ",
        nrow(background), " background items held back")

# response_options is a fixed format this project writes and reads:
# "1 = Label | 2 | 3 = Label", where a bare number is a scale point the
# instrument left unlabelled. Reading it back is not the same as parsing prose
# - the format is the contract, not a guess about meaning.
parse_options <- function(text) {
  pieces <- str_split_1(text, fixed(" | "))
  matched <- str_match(pieces, "^([^=]+?)\\s*=\\s*(.*)$")
  value <- if_else(is.na(matched[, 2]), str_squish(pieces),
                   str_squish(matched[, 2]))
  label <- if_else(is.na(matched[, 3]), NA_character_, str_squish(matched[, 3]))
  tibble(value = value, label = label)
}

# A partly-labelled scale carries its number on every bar, so "0 - No trust"
# through "10 - Complete trust" still reads as a scale once the middle bars
# have no words. A fully labelled set is left as its wording alone, which is
# what the instrument shows the respondent.
display_labels <- function(options) {
  if (any(is.na(options$label))) {
    options |> mutate(label = if_else(is.na(label), value,
                                      paste0(value, " - ", label)))
  } else {
    options
  }
}

# A count the reader can act on: what response format this is, before they
# click. Derived from the options rather than declared, so it cannot drift.
response_kind <- function(options, scale) {
  n <- nrow(options)
  if (scale == "checkbox") return("Select all that apply")
  unlabelled <- sum(str_detect(options$label, "^\\d+ - "))
  codes <- suppressWarnings(as.integer(options$value))
  if (unlabelled > 0 && !anyNA(codes)) {
    paste0(min(codes), "-", max(codes), " scale")
  } else {
    paste0(n, " categories")
  }
}

# Distributions ----------------------------------------------------------------
# srvyr on the wave weights, which are raked to Census margins within each
# wave. Pooling two waves stacks them and lets each contribute in proportion to
# its weighted size, which is how wxdash pools its 22 waves.
#
# survey_prop(proportion = TRUE) is the logit-scale interval. It is used
# whether or not the front end is showing intervals, so the point estimate a
# reader sees never changes when they tick the box.
distribution <- function(d, split_id, option_values) {
  design <- d |>
    filter(!is.na(.data[[split_id]])) |>
    rename(group = all_of(split_id)) |>
    as_survey_design(weights = weight)

  out <- design |>
    group_by(group, resp) |>
    summarise(p = survey_prop(proportion = TRUE, vartype = "ci"),
              .groups = "drop") |>
    transmute(group, resp,
              p = round(100 * p, 2),
              p_low = round(100 * p_low, 2),
              p_upp = round(100 * p_upp, 2))

  # Response codes are character, and grouping alone sorts them as strings:
  # that puts 10 between 1 and 2 on every eleven-point scale and rotates the
  # income follow-ups, whose codes run 6-10 and 11-15. Ordered by the
  # instrument's own option order instead, which is also right where the codes
  # are not a sequence at all.
  order_rows(out, split_id, option_values)
}

# A select-all battery is not a distribution. Each item is its own proportion -
# the share of the people shown the battery who ticked that box - so they are
# estimated one at a time with survey_mean rather than normalised against each
# other, and they do not sum to 100. The question file says so, and the caption
# repeats it, because a reader who assumes otherwise reads every bar as smaller
# than it is.
multi_distribution <- function(d, split_id, items) {
  design <- d |>
    filter(!is.na(.data[[split_id]])) |>
    rename(group = all_of(split_id)) |>
    as_survey_design(weights = weight)

  map(items, function(item) {
    design |>
      group_by(group) |>
      summarise(p = survey_mean(.data[[item]] == "1", proportion = TRUE,
                                vartype = "ci"),
                .groups = "drop") |>
      transmute(group, resp = item,
                p = round(100 * p, 2),
                p_low = round(100 * p_low, 2),
                p_upp = round(100 * p_upp, 2))
  }) |>
    bind_rows()
}

# Category and series order, settled here for the same reason as the
# single-response charts: the front end draws them in the order this file
# lists them.
order_rows <- function(out, split_id, resp_order) {
  order <- group_order[[split_id]]
  groups <- if (is.null(order)) sort(unique(out$group)) else order
  out <- out |>
    mutate(group = factor(group, levels = groups)) |>
    arrange(group, match(resp, resp_order))
  if (anyNA(out$group)) {
    print(setdiff(unique(as.character(out$group)), groups))
    stop("Groups above are in the data but not in group_order for ", split_id)
  }
  out |> mutate(group = as.character(group))
}

# Reproduction code -------------------------------------------------------------
# Every chart carries the R that rebuilds it from the released CSVs and nothing
# else. Generated here, by the script that did the computing, so it cannot
# drift from what was computed - the same property that makes 04 carry numbers
# rather than calculate them.
#
# One script per (arm, split), not one template with placeholders, because a
# script for a specific plot should name that plot's variables and nothing
# more. Splitting by gender should not make a reader read a roster of thirteen
# grouping columns, and it should say `Gender`, not `.data[[SPLIT]]`. So the
# splits differ enough that a template would have to be read around rather
# than read.
#
# Rules the generated code follows, and they are the point of it:
#   - no helper functions. Every step is a call the reader can run on its own.
#   - column names written where they are used, never through .data[[ ]].
#   - only the columns this plot needs.
#
# Checked against this script's own output below - see `verify_r_code`.

r_quote <- function(x) paste0('"', gsub('([\\\\"])', '\\\\\\1', x), '"')

# c("a", "b", ...) wrapped to fit. Breaks between elements only: strwrap()
# breaks at any whitespace, which puts a newline inside a response label and
# quietly changes the string. The verification below caught that.
r_vec <- function(x, indent) {
  pad <- strrep(" ", indent)
  parts <- paste0(r_quote(x), c(rep(",", length(x) - 1), ""))
  lines <- character(0)
  cur <- ""
  for (piece in parts) {
    if (!nzchar(cur)) {
      cur <- piece
    } else if (indent + nchar(cur) + 1 + nchar(piece) > 78) {
      lines <- c(lines, cur)
      cur <- piece
    } else {
      cur <- paste(cur, piece)
    }
  }
  paste0("c(", paste(c(lines, cur), collapse = paste0("\n", pad)), ")")
}

# The two derived splits, written out where they are used. A reader with this
# script and the CSV has everything; a reader sent to look up derive_groups()
# does not.
r_derive <- list(
  IDEOL_GROUP = paste0(
    "      IDEOL_GROUP = case_when(\n",
    "        ideol %in% 1:3 ~ \"Liberal\",\n",
    "        ideol == 4     ~ \"Moderate\",\n",
    "        ideol %in% 5:7 ~ \"Conservative\"\n",
    "      ),"),
  GCC_GROUP = paste0(
    "      GCC_GROUP = case_when(\n",
    "        gcc == 1 ~ \"Greenhouse gases are warming the planet\",\n",
    "        gcc == 0 ~ \"They are not\"\n",
    "      ),")
)

# A question stem runs to 539 characters in this survey. One string literal
# that long is a line nobody can read, so it is broken into fragments.
r_title <- function(title) {
  if (nchar(title) <= 60) return(r_quote(title))
  parts <- strwrap(title, 60)
  paste0("paste(\n      ",
         paste(r_quote(parts), collapse = ",\n      "), "\n    )")
}

r_script <- function(title, intro, asked, options, split, group_order = NULL,
                     items = NULL, multi = FALSE, arm_label = NULL,
                     split_label = split) {
  obj <- paste0("fu", substr(asked$wave, 3, 4))     # fu25, fu26
  grp <- if (split == "All") NULL else split

  # What each wave contributes: the weight, the grouping column if there is
  # one, and the answer.
  stack <- pmap_chr(list(obj, asked$year, asked$column, asked$arm_column,
                         asked$arm_value),
    function(o, year, col, arm_col, arm_value) {
      pre <- if (is.na(arm_col)) "" else
        paste0(" |>\n    filter(", arm_col, " == ", r_quote(arm_value), ")")
      lines <- c("      weight = as.numeric(weight)")
      if (!is.null(grp)) {
        if (grp == "survey_year") lines <- c(lines,
          paste0("      survey_year = ", r_quote(as.character(year))))
        else if (!is.null(r_derive[[grp]]))
          lines <- c(lines, sub(",$", "", r_derive[[grp]]))
        else lines <- c(lines, paste0("      ", grp))
      }
      answers <- if (multi)
        paste0("      ", items$variable, " = ", items[[o]])
      else paste0("      resp = ", col)
      paste0("  ", o, pre, " |>\n    transmute(\n",
             paste(c(lines, answers), collapse = ",\n"), "\n    )")
    })

  drop_na <- c(if (multi) paste0("!is.na(", items$variable[1], ")")
               else "!is.na(resp)",
               if (!is.null(grp) && grp != "survey_year")
                 paste0("!is.na(", grp, ")"))

  # Estimation. A single-response question is a distribution over its options;
  # a select-all battery is one proportion per item, each over the same people,
  # so the items do not sum to 100.
  est <- if (multi) paste0(
    "# Each item is its own proportion - the share of the people shown the\n",
    "# battery who ticked that box - so the bars do not sum to 100.\n",
    "design <- as_survey_design(d, weights = weight)\n\n",
    "est <- bind_rows(\n",
    paste(paste0(
      "  design |>\n",
      if (is.null(grp)) "" else paste0("    group_by(", grp, ") |>\n"),
      "    summarise(p = survey_mean(", items$variable, " == \"1\",\n",
      "                              proportion = TRUE, vartype = \"ci\")) |>\n",
      "    mutate(resp = ", r_quote(items$variable), ")"),
      collapse = ",\n"),
    "\n)\n")
  else paste0(
    "est <- d |>\n",
    "  as_survey_design(weights = weight) |>\n",
    "  group_by(", paste(c(grp, "resp"), collapse = ", "), ") |>\n",
    "  summarise(p = survey_prop(proportion = TRUE, vartype = \"ci\"),\n",
    "            .groups = \"drop\")\n")

  # Order. Response codes are character, so sorting them as strings puts 10
  # between 1 and 2; the instrument's order is used instead.
  order_block <- paste0(
    "est <- est |>\n",
    "  mutate(\n",
    "    p = 100 * p, p_low = 100 * p_low, p_upp = 100 * p_upp,\n",
    "    resp = factor(\n",
    "      resp,\n",
    "      levels = ", r_vec(options$value, 17), ",\n",
    "      labels = ", r_vec(options$label, 17), "\n",
    "    )",
    if (!is.null(group_order)) paste0(",\n    ", grp, " = factor(\n",
      "      ", grp, ",\n      levels = ",
      r_vec(group_order, 17), "\n    )") else "",
    "\n  )\n")

  fill <- if (is.null(grp)) "" else paste0(", fill = ", grp)
  dodge <- if (is.null(grp)) "" else
    "\n                position = position_dodge2(reverse = TRUE),"
  plot <- paste0(
    "ggplot(est, aes(x = p, y = fct_rev(resp)", fill, ")) +\n",
    "  geom_col(", if (is.null(grp)) "" else
      "position = position_dodge2(reverse = TRUE), ", "width = 0.8) +\n",
    "  geom_errorbar(aes(xmin = p_low, xmax = p_upp),", dodge, "\n",
    "                width = 0.2, linewidth = 0.3) +\n",
    "  labs(\n",
    "    title = str_wrap(", r_title(title), ", 70),\n",
    "    x = ", r_quote(if (multi) "Share who picked it (%)"
                       else "Share of respondents (%)"), ",\n",
    "    y = NULL", if (is.null(grp)) "" else paste0(",\n    fill = ",
                                                    r_quote(split_label)), "\n",
    "  ) +\n",
    "  theme_minimal()\n")

  paste0(
    paste(strwrap(title, 76, prefix = "# "), collapse = "\n"), "\n",
    if (!is.na(intro) && nzchar(intro))
      paste0("#\n", paste(strwrap(intro, 76, prefix = "# "), collapse = "\n"),
             "\n") else "",
    "#\n",
    "# IPPRA Fusion Energy Survey. Rebuilds this plot from the released data\n",
    "# files and nothing else.\n",
    if (is.null(arm_label)) "" else
      paste0("# Version shown to this half of the sample: ", arm_label, "\n"),
    if (split == "All") "" else
      paste0("# Split by ", split_label, " (the `", split, "` column).\n"),
    "\n",
    "library(tidyverse)\n",
    "library(srvyr)\n\n",
    "# Read as character: the two files type the same item differently once a\n",
    "# wave has a column that is empty for its first thousand rows. Reading as\n",
    "# character removes the guess rather than widening it.\n",
    paste0(obj, " <- read_csv(", r_quote(basename(asked$file)),
           ",\n", strrep(" ", nchar(obj) + 13),
           "col_types = cols(.default = col_character()))",
           collapse = "\n"), "\n\n",
    if (any(!is.na(asked$arm_column)))
      paste0("# This question was split-sampled - respondents did not all read the\n",
             "# same thing - so this arm is estimated on its own. Pooling them\n",
             "# would average across the treatment.\n") else "",
    "d <- bind_rows(\n", paste(stack, collapse = ",\n"), "\n) |>\n",
    "  filter(", paste(drop_na, collapse = ", "), ")\n\n",
    est, "\n", order_block, "\n", plot)
}

wjson <- function(x, path, pretty = FALSE) {
  write_json(x, file.path(out, path), pretty = pretty, auto_unbox = TRUE,
             na = "null", digits = NA)
}

# Does the generated script actually rebuild the chart? Checked, not asserted.
# Each script is run against the same CSVs a reader would download and its
# estimates compared with the ones written to the question file. Publishing
# code that does not reproduce the plot would be worse than publishing none,
# and a generator is exactly the kind of thing that goes subtly wrong.
#
# read_csv is shimmed to a cache in the evaluation environment, so the build
# does not read the two files a thousand times. Same arguments, same result.
r_code_cache <- new.env(parent = emptyenv())
cached_read_csv <- function(file, ...) {
  key <- file.path(data_dir, file)
  if (is.null(r_code_cache[[key]])) {
    r_code_cache[[key]] <- readr::read_csv(key, ...)
  }
  r_code_cache[[key]]
}

r_code_checks <- 0L
r_code_scripts <- 0L

verify_r_code <- function(script, expect, options, label) {
  e <- new.env(parent = globalenv())
  assign("read_csv", cached_read_csv, envir = e)
  ok <- try(suppressWarnings(suppressMessages(
    eval(parse(text = script), envir = e))), silent = TRUE)
  if (inherits(ok, "try-error")) {
    cat(script)
    stop("The generated R for ", label, " does not run: ",
         conditionMessage(attr(ok, "condition")))
  }

  # The script labels its responses, so the published codes are labelled to
  # match rather than the other way round: comparing on the codes would not
  # notice a levels/labels pairing that had drifted.
  got <- get("est", envir = e) |> as_tibble()
  gcol <- setdiff(names(got), c("resp", "p", "p_low", "p_upp", "p_se"))
  got <- got |>
    transmute(group = if (length(gcol) == 1) as.character(.data[[gcol]])
                      else "All",
              resp = as.character(resp), gen = round(p, 2))
  want <- expect |>
    left_join(options, by = c("resp" = "value")) |>
    transmute(group = as.character(group), resp = label, pub = round(p, 2))

  cmp <- full_join(want, got, by = c("group", "resp"))
  if (any(is.na(cmp$pub)) || any(is.na(cmp$gen)) ||
      max(abs(cmp$pub - cmp$gen)) > 0.011) {
    print(cmp |> filter(is.na(pub) | is.na(gen) | abs(pub - gen) > 0.011))
    stop("The generated R for ", label, " does not reproduce its chart.")
  }
  r_code_checks <<- r_code_checks + 1L
}

# Which (arm, split) pairs get run. Every question is checked, and within it
# every shape the generator can produce - no grouping, a plain column, a
# derived column, the wave - plus every arm at least once. Running all ~1,100
# would add minutes for no more coverage than this.
verify_pairs <- function(arm_ids, split_ids) {
  shapes <- c("All",
              setdiff(split_ids, c("All", "IDEOL_GROUP", "GCC_GROUP",
                                   "survey_year"))[1],
              intersect(c("IDEOL_GROUP", "GCC_GROUP"), split_ids)[1],
              intersect("survey_year", split_ids))
  shapes <- unique(shapes[!is.na(shapes)])
  c(map(shapes, ~list(arm = arm_ids[1], split = .x)),
    map(arm_ids[-1], ~list(arm = .x, split = "All")))
}

dropped_report <- list()
boundary_report <- list()
catalog <- list()

for (i in seq_len(nrow(questions))) {
  q <- questions[i, ]

  # Which waves asked it, and under which column name in each. column_field is
  # the reference column that holds those names, kept so the assignment column
  # can be looked up the same way.
  asked <- waves |>
    mutate(column_field = column, column = map_chr(column, ~q[[.x]])) |>
    filter(!is.na(column))

  options <- parse_options(q$response_options) |> display_labels()

  # One frame for this question: the answer column renamed, whichever wave it
  # came from, plus the raw assignment where the question was split-sampled.
  # The assignment column is named differently in each wave (FU25 calls
  # rand_dist "distance"), so it is looked up in the reference like any other.
  arm_row <- if (is.na(q$arm_variable)) NULL else
    reference |> filter(variable == q$arm_variable)

  d <- pmap(list(asked$wave, asked$column, asked$column_field),
            function(w, col, field) {
    src <- responses |> filter(wave == w)
    arm_col <- if (is.null(arm_row)) NULL else arm_row[[field]]
    src |>
      transmute(across(all_of(c("survey_year", "weight", "All",
                                split_columns, "IDEOL_GROUP", "GCC_GROUP"))),
                wave = w,
                resp = .data[[col]],
                arm_raw = if (is.null(arm_col) || is.na(arm_col)) NA_character_
                          else .data[[arm_col]])
  }) |>
    bind_rows() |>
    filter(!is.na(resp))

  # A code in the data that the instrument does not document means either a
  # miscoded column or a reference row that is out of date. Either way the bar
  # would be drawn with no label.
  undocumented <- setdiff(unique(d$resp), options$value)
  if (length(undocumented) > 0) {
    print(undocumented)
    stop("Codes above appear in the data for ", q$variable,
         " but not in its response_options.")
  }

  # A split-sample question is really one question per arm. Pooling them
  # averages across the treatment, so each arm is estimated on its own and the
  # reader picks which to look at.
  # The CSV and the arm column for each wave, for the reproduction script:
  # both differ between waves (FU25 calls rand_dist "distance"), and the code
  # a reader runs has to name the file and column they actually have.
  asked <- asked |>
    mutate(file = data,
           arm_column = if (is.null(arm_row)) NA_character_
                        else map_chr(column_field, ~arm_row[[.x]]))

  arms_cfg <- NULL
  if (!is.na(q$arm_variable)) {
    if (nrow(arm_row) != 1) {
      stop("Question ", q$variable, " names arm variable ", q$arm_variable,
           ", which is not one row of the reference.")
    }
    arm_map <- arms_table |> filter(arm_variable == q$arm_variable)

    d <- d |> mutate(arm = arm_raw)
    unmapped <- d |>
      distinct(wave, arm) |>
      anti_join(arm_map, by = c("wave", "arm" = "value"))
    if (nrow(unmapped) > 0) {
      print(unmapped)
      stop("Assignment values above are in the data for ", q$variable,
           " but not in arms.csv.")
    }
    d <- d |>
      left_join(arm_map |> select(wave, value, arm_id),
                by = c("wave", "arm" = "value")) |>
      mutate(arm = arm_id) |>
      select(-arm_id)

    if (anyNA(d$arm)) {
      stop(sum(is.na(d$arm)), " respondents answered ", q$variable,
           " with no arm recorded - they would vanish from every arm.")
    }
    arms_cfg <- arm_map |>
      distinct(arm_id, label, arm_order) |>
      arrange(arm_order)
  }

  # One pass per arm, or a single unnamed pass when the question has none.
  arm_ids <- if (is.null(arms_cfg)) NA_character_ else arms_cfg$arm_id
  arm_splits <- list()
  arm_summaries <- list()

  for (a in arm_ids) {
  d_all <- d
  if (!is.na(a)) d <- d_all |> filter(arm == a)

  splits_out <- list()
  summaries_out <- list()

  for (j in seq_len(nrow(splits))) {
    s <- splits$id[j]
    if (s == "survey_year" && nrow(asked) < 2) next
    if (identical(splits$source[j], q$variable)) next
    have <- d |> filter(!is.na(.data[[s]]))
    if (nrow(have) == 0) next

    rows <- distribution(have, s, options$value)
    splits_out[[s]] <- rows

    # A group where every respondent gave the same answer. The logit interval
    # degenerates there - glm.fit warns that it did not converge and returns
    # [100, 100], which is narrower than the handful of respondents behind it
    # can support. Counted rather than silenced, so the warnings in the console
    # have a number beside them.
    stuck <- rows |> filter(p == 0 | p == 100)
    if (nrow(stuck) > 0) {
      boundary_report[[length(boundary_report) + 1]] <-
        stuck |> transmute(variable = q$variable, split = s, group, resp, p)
    }

    sizes <- have |> count(.data[[s]], name = "n")
    smallest <- sizes |> slice_min(n, n = 1, with_ties = FALSE)
    summaries_out[[s]] <- list(
      n = nrow(have),
      years = paste(sort(unique(have$survey_year)), collapse = "-"),
      smallest = smallest[[1]],
      smallest_n = smallest$n,
      # What the split cost: respondents who answered the question but have no
      # value for this grouping. Shown in the caption rather than absorbed.
      dropped = nrow(d) - nrow(have)
    )
    if (nrow(d) - nrow(have) > 0) {
      dropped_report[[length(dropped_report) + 1]] <- tibble(
        variable = q$variable, split = s, dropped = nrow(d) - nrow(have)
      )
    }
  }

  key <- if (is.na(a)) "all" else a
  arm_splits[[key]] <- splits_out
  arm_summaries[[key]] <- summaries_out
  d <- d_all
  }

  # One script per (arm, split): a script for a specific plot names that
  # plot's variables and nothing else, and the splits differ by more than a
  # name - some need a derived column, some an order, Everyone needs none.
  arm_keys <- names(arm_splits)
  r_code <- list()
  for (ak in arm_keys) {
    per_split <- list()
    for (sp in names(arm_splits[[ak]])) {
      per_split[[sp]] <- r_script(
        title = q$question_text, intro = q$question_intro,
        asked = asked |> mutate(
          arm_value = if (ak == "all") NA_character_ else
            arm_map$value[match(paste(wave, ak),
                                paste(arm_map$wave, arm_map$arm_id))],
          arm_column = if (ak == "all") NA_character_ else arm_column),
        options = options, split = sp, group_order = group_order[[sp]],
        split_label = splits$label[match(sp, splits$id)],
        arm_label = if (ak == "all") NULL else
          arms_cfg$label[match(ak, arms_cfg$arm_id)])
    }
    r_code[[ak]] <- per_split
    r_code_scripts <- r_code_scripts + length(per_split)
  }

  for (pair in verify_pairs(arm_keys, names(arm_splits[[1]]))) {
    verify_r_code(r_code[[pair$arm]][[pair$split]],
                  arm_splits[[pair$arm]][[pair$split]], options,
                  paste(q$variable, pair$arm, pair$split))
  }

  wjson(list(
    id = q$variable,
    variable = q$variable,
    topic = q$topic,
    question = q$question_text,
    intro = q$question_intro,
    response_scale = q$response_scale,
    experimental = q$experimental,
    asked_if = q$asked_if_plain,
    multi_response = FALSE,
    # Years, not FU25/FU26: the wave code is the instrument's name for the
    # fielding and means nothing to a reader. as.list keeps this an array in
    # the JSON - auto_unbox turns a length-one vector into a bare string, and
    # the front end joins it.
    waves = as.list(as.character(asked$year)),
    options = options,
    # Split-sample questions carry one set of splits per arm and the roster to
    # pick between; everything else carries the single set under "all". The
    # front end reads whichever arm is selected either way, so there is one
    # code path rather than two.
    # NA rather than NULL: jsonlite writes NULL as {}, which is truthy in
    # JavaScript, so every question would look split-sampled.
    arms = if (is.null(arms_cfg)) NA else
      pmap(arms_cfg, function(arm_id, label, arm_order)
        list(id = arm_id, label = label)),
    arm_prompt = if (is.null(arms_cfg)) NA_character_ else arm_map$prompt[1],
    splits = arm_splits,
    summaries = arm_summaries,
    # The scripts live in their own file, fetched only when a reader asks for
    # one: fusion_reg_choice has three arms and twelve splits, and 174 KB of
    # code nobody clicked has no business riding along with every chart.
    has_r_code = TRUE
  ), file.path("q", paste0(q$variable, ".json")))
  wjson(r_code, file.path("rcode", paste0(q$variable, ".json")))

  catalog[[length(catalog) + 1]] <- tibble(
    id = q$variable,
    topic = q$topic,
    question = q$question_text,
    intro = coalesce(q$question_intro, ""),
    variable = q$variable,
    response_scale = q$response_scale,
    keywords = q$keywords,
    kind = response_kind(options, q$response_scale),
    waves = paste(asked$year, collapse = ", "),
    experimental = q$experimental,
    ref_row = q$ref_row
  )

  if (i %% 25 == 0) cat("  ", i, "/", nrow(questions), "\n", sep = "")
}

# Batteries --------------------------------------------------------------------
# One plot per set. The chart's categories are the items and each bar is the
# share of the people shown the battery who ticked that box.
for (b in batteries) {
  bid <- b$battery[1]

  if (n_distinct(b$topic) > 1) {
    print(b |> select(variable, topic))
    stop("Battery ", bid, " spans more than one topic.")
  }

  # Which waves asked it, and under which column names. A battery carries one
  # column per item per wave rather than the single column a question has.
  asked <- waves |>
    mutate(cols = map(column, ~b[[.x]])) |>
    filter(map_lgl(cols, ~!all(is.na(.x))))

  # Items renamed to their canonical names so the two waves stack, which is
  # what carries FU25's fusion_source_1..10 onto FU26's names.
  d <- map2(asked$wave, asked$cols, function(w, cols) {
    src <- responses |> filter(wave == w)
    bind_cols(
      src |> select(all_of(c("survey_year", "weight", "All", split_columns,
                             "IDEOL_GROUP", "GCC_GROUP"))),
      src[cols] |> set_names(b$variable)
    )
  }) |>
    bind_rows()

  # The base is everyone shown the battery. Checked rather than assumed: if the
  # items disagree about who is missing, one denominator cannot serve them all
  # and the bars would rest on different samples while looking comparable.
  missing_counts <- map_int(b$variable, ~sum(is.na(d[[.x]])))
  if (n_distinct(missing_counts) > 1) {
    print(tibble(item = b$variable, missing = missing_counts))
    stop("Items above disagree about who was shown battery ", bid, ".")
  }
  d <- d |> filter(!is.na(.data[[b$variable[1]]]))

  codes <- unique(unlist(map(b$variable, ~unique(d[[.x]]))))
  if (!all(codes %in% c("0", "1"))) {
    print(setdiff(codes, c("0", "1")))
    stop("Codes above are in battery ", bid, ", which must be 0/1 indicators.")
  }

  # Items are ranked by how often they were picked, most-picked at the top,
  # because that is the question a select-all battery answers and the
  # instrument's own order is arbitrary (it was randomized on screen anyway).
  #
  # Two things keep the ranking honest. It is taken from the Everyone
  # distribution and then used for every split, so changing the split
  # re-colours the chart rather than reshuffling it and the reader can compare
  # one picture with the next. And a residual option sinks to the bottom
  # whatever its share: "Other (please specify)" is not a finding that beat the
  # options below it, it is where the rest went.
  #
  # Which option is residual is read from the wording and cross-checked against
  # the naming convention. A wave that breaks either stops the build rather
  # than quietly ranking Other among the real answers.
  by_text <- str_starts(b$question_text, "Other")
  by_name <- str_ends(b$variable, "_oth")
  if (!identical(by_text, by_name)) {
    print(tibble(variable = b$variable, question_text = b$question_text,
                 by_text, by_name))
    stop("Battery ", bid, ": the residual option cannot be identified - its ",
         "wording and its name disagree.")
  }

  ranking <- multi_distribution(d, "All", b$variable) |> select(resp, p)
  item_order <- tibble(resp = b$variable, residual = by_text) |>
    left_join(ranking, by = "resp") |>
    arrange(residual, desc(p)) |>
    pull(resp)

  b <- b |> arrange(match(variable, item_order))
  options <- tibble(value = b$variable, label = b$question_text)
  splits_out <- list()
  summaries_out <- list()

  for (j in seq_len(nrow(splits))) {
    s <- splits$id[j]
    if (s == "survey_year" && nrow(asked) < 2) next
    have <- d |> filter(!is.na(.data[[s]]))
    if (nrow(have) == 0) next

    rows <- multi_distribution(have, s, b$variable) |>
      order_rows(s, b$variable)
    splits_out[[s]] <- rows

    stuck <- rows |> filter(p == 0 | p == 100)
    if (nrow(stuck) > 0) {
      boundary_report[[length(boundary_report) + 1]] <-
        stuck |> transmute(variable = bid, split = s, group, resp, p)
    }

    sizes <- have |> count(.data[[s]], name = "n")
    smallest <- sizes |> slice_min(n, n = 1, with_ties = FALSE)
    summaries_out[[s]] <- list(
      n = nrow(have),
      years = paste(sort(unique(have$survey_year)), collapse = "-"),
      smallest = smallest[[1]],
      smallest_n = smallest$n,
      dropped = nrow(d) - nrow(have)
    )
    if (nrow(d) - nrow(have) > 0) {
      dropped_report[[length(dropped_report) + 1]] <- tibble(
        variable = bid, split = s, dropped = nrow(d) - nrow(have)
      )
    }
  }

  # The reproduction script. `items` carries each item's canonical name beside
  # the column it lives in per wave, which is what stacks FU25's
  # fusion_source_1..10 onto FU26's names inside the generated code too.
  items <- b |> select(variable, all_of(waves$column))
  names(items) <- c("variable", paste0("fu", substr(waves$wave, 3, 4)))
  items <- items |> arrange(match(variable, b$variable))

  asked_b <- asked |> mutate(file = data, arm_column = NA_character_,
                             arm_value = NA_character_, column = NA_character_)
  r_code <- list(all = map(set_names(names(splits_out)), function(sp)
    r_script(title = b$question_intro[1], intro = NA_character_,
             asked = asked_b, options = options, split = sp,
             group_order = group_order[[sp]], items = items, multi = TRUE,
             split_label = splits$label[match(sp, splits$id)])))

  r_code_scripts <- r_code_scripts + length(r_code[["all"]])
  for (pair in verify_pairs("all", names(splits_out))) {
    verify_r_code(r_code[["all"]][[pair$split]], splits_out[[pair$split]],
                  options, paste(bid, pair$split))
  }

  wjson(list(
    id = bid,
    variable = bid,
    topic = b$topic[1],
    # The stem is the question here: the items are the answer options.
    question = b$question_intro[1],
    intro = NA_character_,
    response_scale = "checkbox",
    experimental = any(b$experimental),
    asked_if = b$asked_if_plain[1],
    multi_response = TRUE,
    waves = as.list(as.character(asked$year)),
    options = options,
    # No battery is split-sampled, so the single set sits under "all" - the
    # same shape the front end reads for every question.
    arms = NA,
    arm_prompt = NA_character_,
    splits = list(all = splits_out),
    summaries = list(all = summaries_out),
    has_r_code = TRUE
  ), file.path("q", paste0(bid, ".json")))
  wjson(r_code, file.path("rcode", paste0(bid, ".json")))

  catalog[[length(catalog) + 1]] <- tibble(
    id = bid,
    topic = b$topic[1],
    question = b$question_intro[1],
    intro = "",
    variable = bid,
    response_scale = "checkbox",
    # Search covers every item's own wording, so "podcast" still finds the
    # battery whose stem never uses the word.
    keywords = paste(c(unique(unlist(str_split(b$keywords, fixed(" | ")))),
                       b$question_text), collapse = " | "),
    kind = paste0("Select all that apply (", nrow(b), " options)"),
    waves = paste(asked$year, collapse = ", "),
    experimental = any(b$experimental),
    # A battery takes the position of its first item, so "Where have you heard
    # about fusion energy?" sits where it was asked rather than at the end of
    # the table with the other batteries.
    ref_row = min(b$ref_row)
  )
}

catalog <- bind_rows(catalog) |> arrange(ref_row) |> select(-ref_row)
wjson(catalog, "questions.json", pretty = TRUE)
wjson(splits, "splits.json", pretty = TRUE)

wjson(list(
  waves = map2(waves_data$year, waves_data$raw,
               ~list(year = .x, n = nrow(.y))),
  respondents = sum(map_int(waves_data$raw, nrow)),
  questions = nrow(catalog),
  compiled = format(Sys.time(), "%Y-%m-%d %H:%M")
), "meta.json", pretty = TRUE)

message("Written to ", out)
message("  ", nrow(catalog), " questions, ",
        sum(map_int(waves_data$raw, nrow)), " respondents")
message("  reproduction scripts: ", r_code_scripts, " written, ",
        r_code_checks, " run and checked against their own chart")

# Respondents lost to a missing grouping value, reported rather than absorbed:
# a split whose caption says 2,444 answered while the bars rest on 1,900 is the
# kind of quiet difference this pipeline exists to avoid.
if (length(dropped_report) > 0) {
  message("Respondents dropped by a missing grouping value:")
  bind_rows(dropped_report) |>
    summarise(questions = n(), max_dropped = max(dropped), .by = split) |>
    arrange(desc(max_dropped)) |>
    print(n = Inf)
}

if (length(boundary_report) > 0) {
  boundary <- bind_rows(boundary_report)
  message("Groups with no variation (the glm.fit warnings above): ",
          nrow(boundary))
  boundary |> print(n = Inf)
}
