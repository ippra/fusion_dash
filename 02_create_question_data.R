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
# rather than calculate them. A snippet assembled in the front end would agree
# on the day it was written and quietly stop agreeing after the next change
# here.
#
# Two placeholders are left for the page to fill in, because the reader is
# looking at one split and one arm and the code should be for that plot:
# {{SPLIT}} and {{ARM}}. They are substituted into string literals the reader
# can then edit, which is why they are named constants at the top of the script
# rather than woven through it.
#
# The generated script is checked against this script's own output further
# down - see `verify_r_code`. Publishing code that does not reproduce the chart
# would be worse than publishing none.

r_quote <- function(x) paste0('"', gsub('([\\\\"])', '\\\\\\1', x), '"')

r_vector <- function(x, indent = 2) {
  pad <- strrep(" ", indent)
  paste0("c(\n", pad, paste(r_quote(x), collapse = paste0(",\n", pad)),
         "\n", strrep(" ", max(0, indent - 2)), ")")
}

# The banding in derive_groups(), written out rather than referenced, because
# the reader has this script and nothing else.
r_derive_groups <- paste0(
  "      IDEOL_GROUP = case_when(\n",
  "        ideol %in% 1:3 ~ \"Liberal\",\n",
  "        ideol == 4     ~ \"Moderate\",\n",
  "        ideol %in% 5:7 ~ \"Conservative\",\n",
  "        TRUE           ~ NA_character_\n",
  "      ),\n",
  "      GCC_GROUP = case_when(\n",
  "        gcc == 1 ~ \"Greenhouse gases are warming the planet\",\n",
  "        gcc == 0 ~ \"They are not\",\n",
  "        TRUE     ~ NA_character_\n",
  "      ),")

r_code_for <- function(title, asked, options, split_ids, arms_cfg = NULL,
                       arm_rowfield = NULL, items = NULL, multi = FALSE,
                       intro = NA_character_) {
  keep <- c("survey_year", "weight", "All", split_columns,
            "IDEOL_GROUP", "GCC_GROUP")

  # One prep() call per wave. `resp` for a single-response question; for a
  # battery the item columns come across under their canonical names, because
  # FU25 released ten of them under names its own instrument no longer uses.
  wave_calls <- pmap_chr(list(asked$wave, asked$year, asked$column,
                              asked$arm_column, asked$file),
    function(wave, year, col, arm_col, file) {
      cols <- if (multi)
        paste0("      ",
               paste0(items$variable, " = ", items[[paste0("col_", tolower(wave))]],
                      collapse = ",\n      "))
      else paste0("      resp = ", col)
      paste0(
        "  prep(read_wave(file.path(DATA_DIR, ", r_quote(basename(file)), ")),\n",
        "       ", r_quote(as.character(year)), ",\n",
        "       ", if (is.na(arm_col)) "NULL" else r_quote(arm_col), ") |>\n",
        "    transmute(across(all_of(KEEP)), arm_raw,\n", cols, ")")
    })

  arm_block <- if (is.null(arms_cfg)) "" else paste0(
    "\n# ---- 3. Pick the arm ---------------------------------------------------\n",
    "# This question was split-sampled: respondents did not all read the same\n",
    "# thing, so each arm is estimated on its own. Pooling them would average\n",
    "# across the treatment the experiment was built to measure. The raw\n",
    "# assignment value differs between waves, so it is mapped, not matched.\n",
    "ARM <- \"{{ARM}}\"   # one of: ",
    paste(unique(arms_cfg$arm_id), collapse = ", "), "\n\n",
    "arm_map <- tribble(\n",
    "  ~survey_year, ~value, ~arm_id,\n",
    paste0("  ", pmap_chr(list(arms_cfg$year, arms_cfg$value, arms_cfg$arm_id),
      function(y, v, a) paste(r_quote(as.character(y)), r_quote(v), r_quote(a),
                              sep = ", ")), collapse = ",\n"), "\n)\n\n",
    "d <- d |>\n",
    "  left_join(arm_map, by = c(\"survey_year\", \"arm_raw\" = \"value\")) |>\n",
    "  filter(arm_id == ARM)\n")

  est_block <- if (multi) paste0(
    "# A select-all battery is not a distribution. Each item is its own\n",
    "# proportion - the share of the people shown the battery who ticked that\n",
    "# box - so they are estimated one at a time with survey_mean rather than\n",
    "# normalised against each other. They do not sum to 100.\n",
    "design <- d |>\n",
    "  filter(!is.na(.data[[SPLIT]])) |>\n",
    "  rename(group = all_of(SPLIT)) |>\n",
    "  as_survey_design(weights = weight)\n\n",
    "est <- map(OPTIONS$value, function(item) {\n",
    "  design |>\n",
    "    group_by(group) |>\n",
    "    summarise(p = survey_mean(.data[[item]] == \"1\", proportion = TRUE,\n",
    "                              vartype = \"ci\"),\n",
    "              .groups = \"drop\") |>\n",
    "    transmute(group, resp = item, p = 100 * p,\n",
    "              p_low = 100 * p_low, p_upp = 100 * p_upp)\n",
    "}) |>\n  bind_rows()\n")
  else paste0(
    "# survey_prop(proportion = TRUE) is the logit-scale interval, used whether\n",
    "# or not the intervals are drawn, so the point estimate never moves when\n",
    "# they are switched on.\n",
    "est <- d |>\n",
    "  filter(!is.na(.data[[SPLIT]])) |>\n",
    "  rename(group = all_of(SPLIT)) |>\n",
    "  as_survey_design(weights = weight) |>\n",
    "  group_by(group, resp) |>\n",
    "  summarise(p = survey_prop(proportion = TRUE, vartype = \"ci\"),\n",
    "            .groups = \"drop\") |>\n",
    "  transmute(group, resp, p = 100 * p,\n",
    "            p_low = 100 * p_low, p_upp = 100 * p_upp)\n")

  paste0(
    "# ", title, "\n",
    if (!is.na(intro) && nzchar(intro))
      paste0(paste(strwrap(intro, 76, prefix = "# "), collapse = "\n"), "\n")
    else "",
    "#\n",
    "# IPPRA Fusion Energy Survey. This script rebuilds the chart of the same\n",
    "# name from the released data files and nothing else. It was generated by\n",
    "# the same script that produced the published estimates, and is checked\n",
    "# against them on every build.\n",
    "#\n",
    "# Needs: ", paste(basename(asked$file), collapse = ", "), "\n\n",
    "library(tidyverse)\n",
    "library(srvyr)\n\n",
    "DATA_DIR <- \".\"   # where the CSVs are\n",
    "# Any of these can go in SPLIT:\n",
    paste(strwrap(paste(split_ids, collapse = ", "), 74, prefix = "#   "),
          collapse = "\n"), "\n",
    "SPLIT <- \"{{SPLIT}}\"\n\n",
    "# ---- 1. Read the waves -------------------------------------------------\n",
    "# Every column as character: the two files type the same item differently\n",
    "# once a wave has a column that is empty for its first thousand rows.\n",
    "# Reading as character removes the guess rather than widening it.\n",
    "read_wave <- function(path) {\n",
    "  read_csv(path, col_types = cols(.default = col_character()),\n",
    "           na = c(\"\", \"NA\"), guess_max = Inf)\n",
    "}\n\n",
    "# The splits the dashboard offers. The seven demographics are the vendor's\n",
    "# derived columns, not the self-reported items: 2025 has no self-reported\n",
    "# demographics at all, so splitting on those would drop it without saying so.\n",
    "KEEP <- ", r_vector(keep), "\n\n",
    "prep <- function(raw, year, arm_col) {\n",
    "  raw |>\n",
    "    mutate(\n",
    r_derive_groups, "\n",
    "      All = \"All\",\n",
    "      survey_year = year,\n",
    "      weight = as.numeric(weight),\n",
    "      arm_raw = if (is.null(arm_col)) NA_character_ else .data[[arm_col]]\n",
    "    )\n",
    "}\n\n",
    "# ---- 2. Stack the waves ------------------------------------------------\n",
    "d <- bind_rows(\n",
    paste(wave_calls, collapse = ",\n"), "\n) |>\n",
    if (multi) paste0("  filter(if_any(", r_vector(items$variable, 4),
                      ", ~ !is.na(.x)))\n")
    else "  filter(!is.na(resp))\n",
    arm_block,
    "\n# ---- ", if (is.null(arms_cfg)) "3" else "4",
    ". The response options, in the instrument's order ------------\n",
    "# Response codes are character, and sorting them as strings puts 10 between\n",
    "# 1 and 2 on every eleven-point scale. Ordered by the instrument instead.\n",
    "OPTIONS <- tribble(\n",
    "  ~value, ~label,\n",
    paste0("  ", map2_chr(options$value, options$label,
      ~paste(r_quote(.x), r_quote(.y), sep = ", ")), collapse = ",\n"), "\n)\n\n",
    "# ---- ", if (is.null(arms_cfg)) "4" else "5",
    ". Estimate, on the wave weights ------------------------------\n",
    est_block,
    "\n# ---- ", if (is.null(arms_cfg)) "5" else "6",
    ". Draw -------------------------------------------------------\n",
    "# Group order matters where the split is ordinal: alphabetical puts\n",
    "# \"Liberal, Moderate, Conservative\" in the wrong order in every locale.\n",
    "GROUP_ORDER <- list(\n",
    paste0("  ", names(group_order), " = ",
           map_chr(group_order, r_vector, indent = 4), collapse = ",\n"),
    "\n)\n\n",
    "plot_data <- est |>\n",
    "  mutate(\n",
    "    resp = factor(resp, levels = OPTIONS$value, labels = OPTIONS$label),\n",
    "    group = factor(group, levels = if (is.null(GROUP_ORDER[[SPLIT]]))\n",
    "                      sort(unique(group)) else GROUP_ORDER[[SPLIT]])\n",
    "  ) |>\n",
    "  arrange(group, resp)\n\n",
    "ggplot(plot_data, aes(x = p, y = fct_rev(resp), fill = group)) +\n",
    "  geom_col(position = position_dodge2(reverse = TRUE, padding = 0.1),\n",
    "           width = 0.8) +\n",
    "  geom_errorbar(aes(xmin = p_low, xmax = p_upp),\n",
    "                position = position_dodge2(reverse = TRUE, padding = 0.1),\n",
    "                width = 0.25, linewidth = 0.3) +\n",
    "  scale_x_continuous(labels = function(x) paste0(x, \"%\"),\n",
    "                     expand = expansion(mult = c(0, 0.05))) +\n",
    "  scale_y_discrete(labels = function(l) str_wrap(l, 40)) +\n",
    "  labs(title = str_wrap(", r_quote(title), ", 70),\n",
    "       x = ", if (multi) r_quote("Share who picked it")
                 else r_quote("Share of respondents"), ",\n",
    "       y = NULL, fill = SPLIT,\n",
    "       caption = \"IPPRA Fusion Energy Survey. Weighted; bars show 95% CIs.\") +\n",
    "  theme_minimal(base_size = 11) +\n",
    "  theme(legend.position = if (SPLIT == \"All\") \"none\" else \"right\",\n",
    "        panel.grid.major.y = element_blank())\n")
}

wjson <- function(x, path, pretty = FALSE) {
  write_json(x, file.path(out, path), pretty = pretty, auto_unbox = TRUE,
             na = "null", digits = NA)
}

# Does the generated script actually rebuild the chart? Checked, not asserted.
# Each question's code is run against the same CSVs a reader would download and
# its estimates compared with the ones written to the question file. Publishing
# code that does not reproduce the plot would be worse than publishing none,
# and a generator is exactly the kind of thing that goes subtly wrong.
#
# read_csv is shimmed to a cache in the evaluation environment: the generated
# script defines read_wave() during eval, so its closure finds this binding by
# lexical scope. Same arguments, same result, 158 file reads become four.
r_code_cache <- new.env(parent = emptyenv())
cached_read_csv <- function(file, ...) {
  key <- normalizePath(file, mustWork = FALSE)
  if (is.null(r_code_cache[[key]])) {
    r_code_cache[[key]] <- readr::read_csv(file, ...)
  }
  r_code_cache[[key]]
}

r_code_checks <- 0L

verify_r_code <- function(code, expect, split, arm, label) {
  script <- gsub("{{SPLIT}}", split, code, fixed = TRUE)
  if (!is.na(arm)) script <- gsub("{{ARM}}", arm, script, fixed = TRUE)
  script <- sub('DATA_DIR <- "."', paste0("DATA_DIR <- ", encodeString(data_dir,
                quote = '"')), script, fixed = TRUE)

  e <- new.env(parent = globalenv())
  assign("read_csv", cached_read_csv, envir = e)
  ok <- try(suppressWarnings(suppressMessages(
    eval(parse(text = script), envir = e))), silent = TRUE)
  if (inherits(ok, "try-error")) {
    cat(script, sep = "\n")
    stop("The generated R for ", label, " does not run: ",
         conditionMessage(attr(ok, "condition")))
  }

  got <- get("est", envir = e) |>
    transmute(group = as.character(group), resp = as.character(resp),
              p = round(p, 2)) |>
    arrange(group, resp)
  want <- expect |>
    transmute(group = as.character(group), resp = as.character(resp),
              p = round(p, 2)) |>
    arrange(group, resp)

  if (!isTRUE(all.equal(as.data.frame(got), as.data.frame(want),
                        tolerance = 1e-6))) {
    print(full_join(want, got, by = c("group", "resp"),
                    suffix = c("_published", "_generated")) |>
            filter(is.na(p_published) | is.na(p_generated) |
                   abs(p_published - p_generated) > 0.01))
    stop("The generated R for ", label, " does not reproduce its chart.")
  }
  r_code_checks <<- r_code_checks + 1L
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

  # The splits this question actually offers, so the SPLIT constant in the
  # generated script lists what will work rather than the whole roster.
  offered <- names(arm_splits[[1]])
  r_code <- r_code_for(
    title = q$question_text, asked = asked, options = options,
    split_ids = offered, intro = q$question_intro,
    arms_cfg = if (is.null(arms_cfg)) NULL else
      arm_map |> left_join(waves |> select(wave, year), by = "wave") |>
        select(year, value, arm_id))

  verify_r_code(r_code, arm_splits[[1]][[offered[1]]], offered[1],
                if (is.null(arms_cfg)) NA_character_ else arms_cfg$arm_id[1],
                q$variable)

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
    r_code = r_code
  ), file.path("q", paste0(q$variable, ".json")))

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
  names(items) <- c("variable", paste0("col_", tolower(waves$wave)))
  r_code <- r_code_for(
    title = b$question_intro[1],
    asked = asked |> mutate(file = data, arm_column = NA_character_,
                            column = NA_character_),
    options = options, split_ids = names(splits_out),
    items = items |> arrange(match(variable, b$variable)), multi = TRUE)

  verify_r_code(r_code, splits_out[[1]], names(splits_out)[1],
                NA_character_, bid)

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
    r_code = r_code
  ), file.path("q", paste0(bid, ".json")))

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
message("  reproduction scripts checked against their own charts: ",
        r_code_checks, " of ", nrow(catalog))

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
