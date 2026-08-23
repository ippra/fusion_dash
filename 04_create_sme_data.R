library(tidyverse)
library(srvyr)
library(jsonlite)

source(here::here("00_paths.R"))

# SME Question Data ------------------------------------------------------------
# The subject-matter-expert survey: 153 people identified as having relevant
# expertise, fielded once in 2026.
#
# Run after 03, before 05:
#   Rscript 04_create_sme_data.R
#
# Writes outputs/04_sme_data/.
#
# THIS IS NOT A POPULATION SURVEY AND CARRIES NO WEIGHTS. The released file has
# no weight column, because a purposive sample of experts is not a sample of
# anything you could weight to. Every percentage here is a plain share of the
# experts who answered, and the page says so. The design below is built with
# weights of 1 rather than skipping srvyr, so the interval is the same logit
# interval the public estimates use and the output files have the same shape -
# which is what lets the front end draw both with one component instead of two.
#
# The other half of this survey asks experts to predict what the public said.
# Those comparisons are declared in the reference's `compare_to` column and
# assembled at the bottom of this script. They are never matched on the column
# name: 26 SME columns share a name with a public variable and only five of
# them are the same question.

out <- file.path(outputs, "04_sme_data")
unlink(out, recursive = TRUE)
dir.create(file.path(out, "q"), recursive = TRUE)

reference <- read_csv(sme_reference, guess_max = Inf, show_col_types = FALSE)
public_reference <- read_csv(variable_reference, guess_max = Inf,
                             show_col_types = FALSE)

raw <- read_csv(sme_data, col_types = cols(.default = col_character()),
                na = c("", "NA"), guess_max = Inf)

message("SME respondents: ", nrow(raw))

# Every variable the sheet says exists must exist, checked before anything is
# computed rather than discovered halfway through the charts.
needs_column <- reference |> filter(question_type != "checkbox_parent")
gone <- setdiff(needs_column$variable, names(raw))
if (length(gone) > 0) {
  print(gone)
  stop("Variables above are in sme_variable_reference.csv but not in the data.")
}

# Splits -----------------------------------------------------------------------
# Everyone, plus years of experience. That is the whole roster, and the reason
# is in the data rather than in taste: every other professional characteristic
# - sector, field, role, audiences communicated with - is select-all, so one
# person is both Academia and National laboratory and cannot be a group in a
# bar chart without inventing a rule for which one wins.
#
# The instrument's six bands are collapsed to three because 153 respondents do
# not support six, and the collapse is made here, once.
splits <- tribble(
  ~id,          ~label,                 ~phrase,
  "All",        "Everyone",             NA_character_,
  "EXP_GROUP",  "Years in fusion work", "experience group"
)

group_order <- list(
  EXP_GROUP = c("Under 10 years", "10 to 19 years", "20 years or more")
)

d <- raw |>
  mutate(
    All = "All",
    EXP_GROUP = case_when(
      exp_years %in% c("1", "2") ~ "Under 10 years",
      exp_years %in% c("3", "4") ~ "10 to 19 years",
      exp_years %in% c("5", "6") ~ "20 years or more",
      TRUE                       ~ NA_character_
    ),
    weight = 1
  )

message("Experience groups: ",
        paste(names(table(d$EXP_GROUP)), table(d$EXP_GROUP),
              sep = " n=", collapse = ", "))

# Options ----------------------------------------------------------------------
parse_options <- function(text) {
  if (is.na(text) || !nzchar(text)) return(tibble(value = character(),
                                                  label = character()))
  parts <- str_split(text, fixed(" | "))[[1]]
  tibble(
    value = str_trim(str_extract(parts, "^[^=]+")),
    label = str_trim(coalesce(str_extract(parts, "(?<== ).*$"),
                              str_extract(parts, "^[^=]+")))
  )
}

wjson <- function(x, path, pretty = FALSE) {
  write_json(x, file.path(out, path), pretty = pretty, auto_unbox = TRUE,
             na = "null", digits = NA)
}

order_rows <- function(rows, split_id, resp_order) {
  order <- group_order[[split_id]]
  groups <- if (is.null(order)) sort(unique(rows$group)) else order
  rows <- rows |>
    mutate(group = factor(group, levels = groups)) |>
    arrange(group, match(resp, resp_order))
  if (anyNA(rows$group)) {
    print(setdiff(unique(as.character(rows$group)), groups))
    stop("Groups above are in the data but not in group_order for ", split_id)
  }
  rows |> mutate(group = as.character(group))
}

# Estimation -------------------------------------------------------------------
# Three shapes, and the question file says which so the front end can label the
# axis rather than assume a percentage:
#
#   share      the distribution of a single-response question, or the share of
#              respondents who ticked one box of a select-all. Sums to 100 for
#              the first; for the second it does not, and where the battery was
#              capped at two picks it sums to about 200.
#   mean_rank  a drag-to-order item. The bar is the mean placing, and a LOWER
#              number is a higher placing, which the axis has to say out loud.
#   mean_pct   an allocation the respondent typed as a percentage. The bar is
#              the mean of what they typed, not a share of them.
distribution <- function(frame, split_id, option_values) {
  design <- frame |>
    filter(!is.na(.data[[split_id]]), !is.na(resp)) |>
    rename(group = all_of(split_id)) |>
    as_survey_design(weights = weight)
  rows <- design |>
    group_by(group, resp) |>
    summarise(p = survey_prop(proportion = TRUE, vartype = "ci"),
              .groups = "drop") |>
    transmute(group, resp, p = round(100 * p, 2),
              p_low = round(100 * p_low, 2), p_upp = round(100 * p_upp, 2))
  order_rows(rows, split_id, option_values)
}

multi_distribution <- function(frame, split_id, items) {
  design <- frame |>
    filter(!is.na(.data[[split_id]])) |>
    rename(group = all_of(split_id)) |>
    as_survey_design(weights = weight)
  map(items, function(item) {
    design |>
      group_by(group) |>
      summarise(p = survey_mean(.data[[item]] == "1", proportion = TRUE,
                                vartype = "ci"), .groups = "drop") |>
      transmute(group, resp = item, p = round(100 * p, 2),
                p_low = round(100 * p_low, 2), p_upp = round(100 * p_upp, 2))
  }) |>
    bind_rows()
}

# Mean of a numeric column, for ranks and for typed percentages. The interval is
# a normal interval on the mean, not the logit interval a proportion gets - a
# mean rank of 2.4 is not a share of anything.
mean_of <- function(frame, split_id, items) {
  design <- frame |>
    filter(!is.na(.data[[split_id]])) |>
    rename(group = all_of(split_id)) |>
    as_survey_design(weights = weight)
  map(items, function(item) {
    design |>
      filter(!is.na(.data[[item]])) |>
      group_by(group) |>
      summarise(p = survey_mean(as.numeric(.data[[item]]), vartype = "ci"),
                .groups = "drop") |>
      transmute(group, resp = item, p = round(p, 2),
                p_low = round(p_low, 2), p_upp = round(p_upp, 2))
  }) |>
    bind_rows()
}

summarise_group <- function(frame, split_id, base_n) {
  have <- frame |> filter(!is.na(.data[[split_id]]))
  sizes <- have |> count(.data[[split_id]], name = "n")
  smallest <- sizes |> slice_min(n, n = 1, with_ties = FALSE)
  list(n = nrow(have), years = "2026", smallest = smallest[[1]],
       smallest_n = smallest$n, dropped = base_n - nrow(have))
}

# Charts -----------------------------------------------------------------------
# One per single-response question and one per battery, the same rule the public
# page follows, minus the background block: sector, field, role, experience and
# the two participation questions describe who answered rather than what they
# think, and they are the splits and the denominator rather than findings.
catalog <- list()
value_kind_for <- function(scale) {
  if (scale %in% c("rank_4", "rank_9")) "mean_rank"
  else if (scale == "numeric_0_100") "mean_pct"
  else "share"
}

singles <- reference |>
  filter(question_type == "question", question_focus != "background",
         response_scale != "open_text")

for (i in seq_len(nrow(singles))) {
  q <- singles[i, ]
  options <- parse_options(q$response_options)
  kind <- value_kind_for(q$response_scale)

  splits_out <- list()
  summaries_out <- list()
  for (s in splits$id) {
    frame <- d
    if (kind == "mean_pct") {
      rows <- mean_of(frame, s, q$variable) |> mutate(resp = q$variable)
      rows <- order_rows(rows, s, q$variable)
    } else {
      rows <- distribution(frame |> mutate(resp = .data[[q$variable]]), s,
                           options$value)
    }
    if (nrow(rows) == 0) next
    splits_out[[s]] <- rows
    base <- frame |> filter(!is.na(.data[[q$variable]]))
    summaries_out[[s]] <- summarise_group(base, s, nrow(base))
  }

  # A typed percentage has no option list, so the single bar is labelled with
  # the question itself rather than with a response.
  if (kind == "mean_pct") options <- tibble(value = q$variable, label = q$question_text)

  wjson(list(
    id = q$variable, variable = q$variable, topic = q$topic,
    question = q$question_text, intro = q$question_intro,
    response_scale = q$response_scale, experimental = FALSE,
    asked_if = q$asked_if_plain, multi_response = FALSE,
    value_kind = kind,
    waves = as.list("2026"), options = options,
    arms = NA, arm_prompt = NA_character_,
    splits = list(all = splits_out), summaries = list(all = summaries_out)
  ), file.path("q", paste0(q$variable, ".json")))

  catalog[[length(catalog) + 1]] <- tibble(
    id = q$variable, topic = q$topic, question = q$question_text,
    intro = coalesce(q$question_intro, ""), variable = q$variable,
    response_scale = q$response_scale, keywords = q$keywords,
    kind = if (nrow(options) > 2) "Scale" else "Categorical",
    waves = "2026", experimental = FALSE, ref_row = i)
}

# Batteries --------------------------------------------------------------------
# Select-all sets and drag-to-rank sets alike: one plot per battery, the items
# as categories. A capped battery ("select the two most significant") is still
# one share per item over the same people, so the bars simply do not sum to 100
# - the caption says which cap applied.
battery_rows <- reference |>
  filter(question_type %in% c("checkbox_item", "rank_item"),
         question_focus != "background")
batteries <- split(battery_rows, battery_rows$battery)

for (bid in names(batteries)) {
  b <- batteries[[bid]]
  parent <- reference |> filter(variable == bid)
  kind <- value_kind_for(b$response_scale[1])
  items <- b$variable

  # Items are ranked by the Everyone result and that order is then used for
  # every split, so changing the split recolours the chart rather than
  # reshuffling it. A residual "Other" sinks to the bottom whatever its value:
  # it is where the rest went, not a finding that beat the options below it.
  residual <- str_ends(items, "_oth")
  headline <- if (kind == "mean_rank") mean_of(d, "All", items)
              else multi_distribution(d, "All", items)
  item_order <- tibble(resp = items, residual = residual) |>
    left_join(headline |> select(resp, p), by = "resp") |>
    arrange(residual, if (kind == "mean_rank") p else desc(p)) |>
    pull(resp)
  b <- b |> arrange(match(variable, item_order))
  options <- tibble(value = b$variable, label = b$question_text)

  splits_out <- list()
  summaries_out <- list()
  for (s in splits$id) {
    rows <- if (kind == "mean_rank") mean_of(d, s, b$variable)
            else multi_distribution(d, s, b$variable)
    rows <- order_rows(rows, s, b$variable)
    splits_out[[s]] <- rows
    base <- d |> filter(if_any(all_of(b$variable), ~ !is.na(.x)))
    summaries_out[[s]] <- summarise_group(base, s, nrow(base))
  }

  wjson(list(
    id = bid, variable = bid, topic = b$topic[1],
    question = parent$question_text, intro = NA_character_,
    response_scale = b$response_scale[1], experimental = FALSE,
    asked_if = b$asked_if_plain[1], multi_response = kind == "share",
    value_kind = kind,
    waves = as.list("2026"), options = options,
    arms = NA, arm_prompt = NA_character_,
    splits = list(all = splits_out), summaries = list(all = summaries_out)
  ), file.path("q", paste0(bid, ".json")))

  catalog[[length(catalog) + 1]] <- tibble(
    id = bid, topic = b$topic[1], question = parent$question_text,
    intro = "", variable = bid, response_scale = b$response_scale[1],
    keywords = b$keywords[1],
    kind = if (kind == "mean_rank") "Ranking" else "Select all",
    waves = "2026", experimental = FALSE, ref_row = 100 + which(names(batteries) == bid))
}

catalog <- bind_rows(catalog) |> arrange(ref_row)
wjson(catalog, "questions.json", pretty = TRUE)
message("SME charts: ", nrow(catalog))

# Expert against public --------------------------------------------------------
# The point of the survey. Half of it asks experts to predict what the public
# said, and the instrument promises participants they will be able to compare
# their perceptions with what was observed.
#
# Every pair is declared in the reference's `compare_to`, never matched on the
# column name. 26 SME columns share a name with a public variable and only five
# ask the same question - the three risk/cost/benefit batteries reuse the
# public item names for a different stem ("which would you most want to
# understand" against "which do non-experts most need to understand"), and
# stacking those by name would produce a comparison that looks valid.
#
# The public side is computed here, from the same files 02 reads, and then
# checked against what 02 actually published. A comparison that disagreed with
# the public page would be worse than no comparison.
public_raw <- map(waves$data, ~read_csv(.x, col_types = cols(.default = col_character()),
                                        na = c("", "NA"), guess_max = Inf))
public <- map2(public_raw, waves$year, function(x, year) {
  x |> mutate(survey_year = as.character(year), weight = as.numeric(.data[[weight_var]]))
}) |>
  bind_rows()

public_column <- function(variable) {
  row <- public_reference |> filter(variable == !!variable)
  if (nrow(row) != 1) stop("No single public reference row for ", variable)
  cols <- c(row$column_fu25, row$column_fu26)
  cols[!is.na(cols)]
}

# One column per wave, stacked under the canonical name - which is what carries
# FU25's renamed columns onto FU26's names.
public_answers <- function(variable) {
  row <- public_reference |> filter(variable == !!variable)
  map2(waves$wave, waves$column, function(w, field) {
    col <- row[[field]]
    if (is.na(col)) return(NULL)
    public |> filter(survey_year == as.character(waves$year[waves$wave == w])) |>
      transmute(weight, resp = .data[[col]])
  }) |>
    bind_rows() |>
    filter(!is.na(resp))
}

public_share <- function(variable, recode = NULL) {
  a <- public_answers(variable)
  if (!is.null(recode)) a <- a |> mutate(resp = recode(resp))
  a |>
    as_survey_design(weights = weight) |>
    group_by(resp) |>
    summarise(p = survey_prop(proportion = TRUE, vartype = "ci"), .groups = "drop") |>
    transmute(resp, p = round(100 * p, 2),
              p_low = round(100 * p_low, 2), p_upp = round(100 * p_upp, 2))
}

# Guard: the five same-question comparisons must reproduce 02's published rows.
published <- function(variable) {
  path <- file.path(outputs, "02_question_data", "q", paste0(variable, ".json"))
  if (!file.exists(path)) return(NULL)
  read_json(path, simplifyVector = TRUE)$splits$all$All |>
    as_tibble() |> transmute(resp = as.character(resp), p)
}

comparisons <- list()
add_comparison <- function(id, title, note, rows, categories, benchmark = NULL,
                           value_kind = "share", axis = "Share of respondents") {
  comparisons[[length(comparisons) + 1]] <<- list(
    id = id, title = title, note = note, value_kind = value_kind, axis = axis,
    categories = as.list(categories), rows = rows,
    benchmark = if (is.null(benchmark)) NA else benchmark)
}

same <- reference |> filter(compare_kind == "same_question")
for (i in seq_len(nrow(same))) {
  q <- same[i, ]
  options <- parse_options(q$response_options)
  expert <- distribution(d |> mutate(resp = .data[[q$variable]]), "All",
                         options$value) |>
    transmute(group = "Experts", resp, p, p_low, p_upp)
  pub <- public_share(q$compare_to) |>
    transmute(group = "The public", resp, p, p_low, p_upp)

  check <- published(q$compare_to)
  if (!is.null(check)) {
    cmp <- full_join(check, pub |> select(resp, p2 = p), by = "resp")
    if (any(is.na(cmp$p)) || any(is.na(cmp$p2)) ||
        max(abs(cmp$p - cmp$p2)) > 0.011) {
      print(cmp)
      stop("The public side of the ", q$variable, " comparison does not match ",
           "what 02 published for ", q$compare_to, ".")
    }
  }

  rows <- bind_rows(expert, pub) |>
    left_join(options, by = c("resp" = "value")) |>
    transmute(group, category = label, p, p_low, p_upp)
  add_comparison(
    paste0("cmp_", q$variable),
    q$question_text,
    paste0("Both surveys asked this question in the same words. ",
           "Expert shares are unweighted counts of 153 people; public shares ",
           "are weighted to the population."),
    rows, options$label)
}

# The prediction items. Each needs its own bridge to the public result, because
# what the expert was asked to estimate differs: a band, an average, a share, or
# which response was most common.
sme_mean <- function(variable) {
  d |> filter(!is.na(.data[[variable]])) |>
    summarise(m = mean(as.numeric(.data[[variable]])), n = n())
}

# Support: experts typed three percentages meant to sum to 100; the public
# answered a 7-point scale. Collapsed to the same three bands here.
support_band <- function(x) case_when(x %in% c("1","2","3") ~ "Opposed",
                                      x == "4" ~ "Neither",
                                      x %in% c("5","6","7") ~ "Supported")
pub_support <- public_share("new_fusion", support_band)
# `pair` rather than `p`: inside transmute() a variable called p is the column,
# not the argument, and the label silently became a number.
exp_support <- map_dfr(
  list(c("fusion_pub_opp","Opposed"), c("fusion_pub_mid","Neither"),
       c("fusion_pub_sup","Supported")),
  function(pair) mean_of(d, "All", pair[1]) |>
    transmute(category = pair[2], p, p_low, p_upp))
add_comparison("cmp_support",
  "How much of the public supports building fusion power plants?",
  paste0("Experts were asked to split 100 points across the three; the public ",
         "answered a seven-point scale, collapsed here to the same three bands. ",
         "The expert bar is the mean of what they typed, so the three need not ",
         "sum to exactly 100."),
  bind_rows(exp_support |> mutate(group = "Experts' guess"),
            pub_support |> left_join(tibble(resp = c("Opposed","Neither","Supported"),
                                            category = c("Opposed","Neither","Supported")),
                                     by = "resp") |>
              transmute(group = "The public, actually", category, p, p_low, p_upp)),
  c("Opposed", "Neither", "Supported"))

# Risk-benefit balance: same shape, the public's seven points collapsed.
rb_band <- function(x) case_when(x %in% c("1","2","3") ~ "Risks outweigh benefits",
                                 x == "4" ~ "About equal",
                                 x %in% c("5","6","7") ~ "Benefits outweigh risks")
pub_rb <- public_share("fusion_risk_ben", rb_band)
exp_rb <- map_dfr(
  list(c("fusion_pub_rb_risk","Risks outweigh benefits"),
       c("fusion_pub_rb_mid","About equal"),
       c("fusion_pub_rb_ben","Benefits outweigh risks")),
  function(pair) mean_of(d, "All", pair[1]) |>
    transmute(category = pair[2], p, p_low, p_upp))
add_comparison("cmp_riskben",
  "How does the public weigh the risks and benefits of fusion energy?",
  paste0("Experts were asked to split 100 points across the three; the public ",
         "answered a seven-point balance scale, collapsed here to the same ",
         "three bands."),
  bind_rows(exp_rb |> mutate(group = "Experts' guess"),
            pub_rb |> transmute(group = "The public, actually", category = resp,
                                p, p_low, p_upp)),
  c("Risks outweigh benefits", "About equal", "Benefits outweigh risks"))

# Timeline: experts picked the response they thought was most common. Their
# distribution of guesses sits beside the public's actual distribution. The two
# option lists are the same six bands in the same order, but the SME instrument
# reproduces FU25's overlapping wording - see NOTES.md.
tl <- parse_options(reference$response_options[reference$variable == "fusion_time"])
exp_tl <- distribution(d |> mutate(resp = fusion_pub_time), "All", tl$value) |>
  transmute(group = "Experts' guess", resp, p, p_low, p_upp)
pub_tl <- public_share("fusion_time") |>
  transmute(group = "The public, actually", resp, p, p_low, p_upp)
add_comparison("cmp_timeline",
  "How long until fusion energy is ready for widespread use?",
  paste0("Experts were asked which response they thought was most common. ",
         "Their guesses are shown as a distribution beside what the public ",
         "actually said. The expert item repeats the 2025 wording of these ",
         "bands, which overlap at the edges; the public answered the 2026 ",
         "wording, which does not."),
  bind_rows(exp_tl, pub_tl) |> left_join(tl, by = c("resp" = "value")) |>
    transmute(group, category = label, p, p_low, p_upp),
  tl$label)

# Awareness: experts picked a band, the public gave a yes or no, so the actual
# is one number rather than a distribution. Marked on the expert's own scale.
know_opts <- parse_options(reference$response_options[reference$variable == "fusion_pub_know"])
pub_know <- public_share("fusion_know")
heard <- pub_know$p[pub_know$resp == "1"]
know_band <- know_opts$label[findInterval(heard, c(0, 20.001, 40.001, 60.001, 80.001))]
add_comparison("cmp_awareness",
  "What share of the public had heard of fusion energy?",
  paste0("Experts picked a band. The public was asked a yes or no question, so ",
         "the answer is a single number rather than a distribution: ",
         format(round(heard, 1)), "% said they had heard of fusion energy ",
         "before reading a description of it."),
  distribution(d |> mutate(resp = fusion_pub_know), "All", know_opts$value) |>
    left_join(know_opts, by = c("resp" = "value")) |>
    transmute(group = "Experts' guess", category = label, p, p_low, p_upp),
  know_opts$label,
  benchmark = list(label = "The public, actually", value = round(heard, 1),
                   category = know_band),
  axis = "Share of experts")

# Feeling about their own word associations: experts estimated the average, so
# the actual average is the benchmark rather than a second series.
feel_opts <- parse_options(reference$response_options[reference$variable == "fusion_pub_feel"])
pub_feel_mean <- public_answers("word_1_feel") |>
  as_survey_design(weights = weight) |>
  summarise(m = survey_mean(as.numeric(resp))) |> pull(m)
add_comparison("cmp_feeling",
  "How did the public feel about the words fusion energy brought to mind?",
  paste0("Experts estimated the average. The public's actual average across ",
         "their first word association was ", format(round(pub_feel_mean, 2)),
         " on this five-point scale. The public scale labels 2 and 4 ",
         "“Negative” and “Positive”; the expert scale says ",
         "“Somewhat”."),
  distribution(d |> mutate(resp = fusion_pub_feel), "All", feel_opts$value) |>
    left_join(feel_opts, by = c("resp" = "value")) |>
    transmute(group = "Experts' guess", category = label, p, p_low, p_upp),
  feel_opts$label,
  benchmark = list(label = "The public's actual average",
                   value = round(pub_feel_mean, 2),
                   category = feel_opts$label[round(pub_feel_mean)]),
  axis = "Share of experts")

wjson(comparisons, "comparisons.json", pretty = TRUE)
wjson(list(
  respondents = nrow(raw),
  charts = nrow(catalog),
  comparisons = length(comparisons),
  compiled = format(Sys.time(), "%Y-%m-%d %H:%M")
), "meta.json", pretty = TRUE)
message("Comparisons: ", length(comparisons))
message("Written to ", out)
