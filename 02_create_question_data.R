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

reference <- read_csv(variable_reference, guess_max = Inf,
                      show_col_types = FALSE)

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

wjson <- function(x, path, pretty = FALSE) {
  write_json(x, file.path(out, path), pretty = pretty, auto_unbox = TRUE,
             na = "null", digits = NA)
}

dropped_report <- list()
boundary_report <- list()
catalog <- list()

for (i in seq_len(nrow(questions))) {
  q <- questions[i, ]

  # Which waves asked it, and under which column name in each.
  asked <- waves |>
    mutate(column = map_chr(column, ~q[[.x]])) |>
    filter(!is.na(column))

  options <- parse_options(q$response_options) |> display_labels()

  # One frame for this question: the answer column renamed, whichever wave it
  # came from.
  d <- map2(asked$wave, asked$column, function(w, col) {
    responses |>
      filter(wave == w) |>
      transmute(across(all_of(c("survey_year", "weight", "All",
                                split_columns, "IDEOL_GROUP", "GCC_GROUP"))),
                resp = .data[[col]])
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

  wjson(list(
    id = q$variable,
    variable = q$variable,
    topic = q$topic,
    question = q$question_text,
    intro = q$question_intro,
    response_scale = q$response_scale,
    experimental = q$experimental,
    asked_if = q$asked_if,
    multi_response = FALSE,
    # as.list keeps this an array in the JSON. auto_unbox turns a length-one
    # vector into a bare string, and the front end joins this - a question
    # asked in one wave would arrive as "FU26" where a string has no join().
    waves = as.list(asked$wave),
    options = options,
    splits = splits_out,
    summaries = summaries_out
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
    waves = paste(asked$wave, collapse = ", "),
    experimental = q$experimental
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

  wjson(list(
    id = bid,
    variable = bid,
    topic = b$topic[1],
    # The stem is the question here: the items are the answer options.
    question = b$question_intro[1],
    intro = NA_character_,
    response_scale = "checkbox",
    experimental = any(b$experimental),
    asked_if = b$asked_if[1],
    multi_response = TRUE,
    waves = as.list(asked$wave),
    options = options,
    splits = splits_out,
    summaries = summaries_out
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
    waves = paste(asked$wave, collapse = ", "),
    experimental = any(b$experimental)
  )
}

catalog <- bind_rows(catalog)
wjson(catalog, "questions.json", pretty = TRUE)
wjson(splits, "splits.json", pretty = TRUE)

wjson(list(
  waves = map2(waves_data$wave, waves_data$raw,
               ~list(wave = .x, n = nrow(.y))),
  respondents = sum(map_int(waves_data$raw, nrow)),
  questions = nrow(catalog),
  compiled = format(Sys.time(), "%Y-%m-%d %H:%M")
), "meta.json", pretty = TRUE)

message("Written to ", out)
message("  ", nrow(catalog), " questions, ",
        sum(map_int(waves_data$raw, nrow)), " respondents")

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
