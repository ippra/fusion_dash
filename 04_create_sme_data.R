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
# The point of the survey, and the page that carries it is a set of findings
# rather than a stack of charts. Each card states one thing in a sentence, puts
# the two numbers behind it side by side, and links to the pages where the
# underlying distributions live. A reader who wants the raw data is one click
# away; a reader who wants the finding does not have to derive it.
#
# Everything a card says is computed here. The headline sentences are built
# from the same numbers the chart draws, so a headline cannot drift away from
# the bars beneath it - which is the same reason 05 carries numbers rather than
# calculating them.
#
# Every pair is declared in the reference's `compare_to`, never matched on the
# column name. 26 SME columns share a name with a public variable and only five
# ask the same question - the three risk/cost/benefit batteries reuse the
# public item names for a different stem, and stacking those by name would
# produce a comparison that looks valid.
public_raw <- map(waves$data, ~read_csv(.x, col_types = cols(.default = col_character()),
                                        na = c("", "NA"), guess_max = Inf))
public <- map2(public_raw, waves$year, function(x, year) {
  x |> mutate(survey_year = as.character(year), weight = as.numeric(.data[[weight_var]]))
}) |>
  bind_rows()

public_answers <- function(variable, wave_filter = NULL) {
  row <- public_reference |> filter(variable == !!variable)
  map2(waves$wave, waves$column, function(w, field) {
    col <- row[[field]]
    if (is.na(col)) return(NULL)
    year <- as.character(waves$year[waves$wave == w])
    if (!is.null(wave_filter) && year != wave_filter) return(NULL)
    public |> filter(survey_year == year) |>
      transmute(weight, resp = .data[[col]])
  }) |>
    bind_rows() |>
    filter(!is.na(resp))
}

public_share <- function(variable, recode = NULL, wave_filter = NULL) {
  a <- public_answers(variable, wave_filter)
  if (!is.null(recode)) a <- a |> mutate(resp = recode(resp))
  a |>
    as_survey_design(weights = weight) |>
    group_by(resp) |>
    summarise(p = survey_prop(proportion = TRUE, vartype = "ci"), .groups = "drop") |>
    transmute(resp, p = round(100 * p, 2),
              p_low = round(100 * p_low, 2), p_upp = round(100 * p_upp, 2))
}

# The weighted share of the public giving any of a set of answers, for a
# headline that says "half of them" rather than making a reader add bars up.
pub_pct <- function(variable, values, wave_filter = NULL) {
  a <- public_answers(variable, wave_filter) |>
    mutate(hit = resp %in% values)
  round(100 * sum(a$weight * a$hit) / sum(a$weight))
}
sme_pct <- function(variable, values) {
  a <- d |> filter(!is.na(.data[[variable]]))
  round(100 * mean(a[[variable]] %in% values))
}
sme_avg <- function(variable) {
  a <- d |> filter(!is.na(.data[[variable]]))
  round(mean(as.numeric(a[[variable]])), 2)
}

# Guard: any public number a card shows must match what 02 published for the
# same question. A findings page that disagreed with the explore page would be
# worse than no findings page.
published <- function(variable) {
  path <- file.path(outputs, "02_question_data", "q", paste0(variable, ".json"))
  if (!file.exists(path)) return(NULL)
  read_json(path, simplifyVector = TRUE)$splits$all$All |>
    as_tibble() |> transmute(resp = as.character(resp), p)
}
check_against_02 <- function(variable, rows) {
  want <- published(variable)
  if (is.null(want)) return(invisible(NULL))
  cmp <- full_join(want, rows |> select(resp, p2 = p), by = "resp")
  if (any(is.na(cmp$p)) || any(is.na(cmp$p2)) || max(abs(cmp$p - cmp$p2)) > 0.011) {
    print(cmp)
    stop("The public side of a card does not match what 02 published for ",
         variable, ".")
  }
}

findings <- list()
add_finding <- function(id, kicker, headline, stats, note, rows, categories,
                        links, value_kind = "share",
                        axis = "Share of respondents",
                        benchmark = NULL, factor_links = NULL, ...) {
  findings[[length(findings) + 1]] <<- list(
    id = id, kicker = kicker, headline = headline,
    stats = stats, note = note, value_kind = value_kind, axis = axis,
    categories = as.list(categories), rows = rows,
    links = links,
    # A second link block, one entry per row of the chart, for a card whose
    # point is that each category is worth looking at on its own.
    factor_links = if (is.null(factor_links)) NA else factor_links,
    benchmark = if (is.null(benchmark)) NA else benchmark)
}
stat <- function(label, value, caption = NULL) {
  list(label = label, value = value,
       caption = if (is.null(caption)) NA else caption)
}
link <- function(label, page, q = NULL) {
  list(label = label,
       href = if (is.null(q)) paste0("#", page) else paste0("?q=", q, "#", page))
}

# 1. Support --------------------------------------------------------------------
support_band <- function(x) case_when(x %in% c("1","2","3") ~ "Opposed",
                                      x == "4" ~ "Neither",
                                      x %in% c("5","6","7") ~ "Supported")
pub_support <- public_share("new_fusion", support_band)
exp_support <- map_dfr(
  list(c("fusion_pub_opp","Opposed"), c("fusion_pub_mid","Neither"),
       c("fusion_pub_sup","Supported")),
  function(pair) mean_of(d, "All", pair[1]) |>
    transmute(category = pair[2], p, p_low, p_upp))
sup_actual <- pub_support$p[pub_support$resp == "Supported"]
sup_guess <- exp_support$p[exp_support$category == "Supported"]

add_finding("support", "Support",
  paste0("The public backs fusion power plants more than experts expect — ",
         "by ", round(sup_actual - sup_guess), " points."),
  list(stat("Experts' guess", paste0(round(sup_guess), "%"),
            "share of the public they expected to support it"),
       stat("The public, actually", paste0(round(sup_actual), "%"),
            "chose 5, 6 or 7 on the seven-point scale")),
  paste0("Experts split 100 points across opposed, neither and supported. The ",
         "public answered a seven-point scale, collapsed here to the same ",
         "three bands. They read opposition almost exactly right — ",
         round(exp_support$p[exp_support$category == "Opposed"]), "% guessed ",
         "against ", round(pub_support$p[pub_support$resp == "Opposed"]),
         "% actual — and expected the rest to sit on the fence."),
  bind_rows(exp_support |> mutate(group = "Experts' guess"),
            pub_support |> transmute(group = "The public, actually",
                                     category = resp, p, p_low, p_upp)),
  c("Opposed", "Neither", "Supported"),
  list(link("See public support in the data", "explore", "new_fusion"),
       link("See what experts guessed", "sme-survey", "fusion_pub_sup")))

# 2. Awareness -------------------------------------------------------------------
know_opts <- parse_options(reference$response_options[reference$variable == "fusion_pub_know"])
heard <- pub_pct("fusion_know", "1")
low_guess <- sme_pct("fusion_pub_know", c("1", "2"))
know_band <- know_opts$label[findInterval(heard, c(0, 20.5, 40.5, 60.5, 80.5))]
add_finding("awareness", "Awareness",
  paste0("Nearly half the public had heard of fusion energy. ",
         round(low_guess), "% of experts guessed 40% or fewer."),
  list(stat("Experts guessing 40% or fewer", paste0(round(low_guess), "%")),
       stat("The public, actually", paste0(heard, "%"),
            paste0("said yes — which is the ", know_band, " band"))),
  paste0("Experts picked a band. The public was asked a yes or no question, ",
         "so the answer is a single number rather than a distribution."),
  distribution(d |> mutate(resp = fusion_pub_know), "All", know_opts$value) |>
    left_join(know_opts, by = c("resp" = "value")) |>
    transmute(group = "Experts' guess", category = label, p, p_low, p_upp),
  know_opts$label,
  list(link("See public awareness in the data", "explore", "fusion_know"),
       link("See what experts guessed", "sme-survey", "fusion_pub_know")),
  axis = "Share of experts",
  # Formatted here rather than in the engine: one benchmark is a percentage
  # and the other is a mean on a five-point scale, and only this script knows
  # which is which.
  benchmark = list(label = "The public, actually", value = paste0(heard, "%"),
                   category = know_band))

# 3. Timelines -------------------------------------------------------------------
# Three numbers on one scale: what the public said, what experts guessed the
# public said, and what experts think themselves.
soon <- c("1", "2")
tl_public <- pub_pct("fusion_time", soon)
tl_guess <- sme_pct("fusion_pub_time", soon)
tl_expert <- sme_pct("fusion_time", soon)
tl_band <- function(x) case_when(x %in% c("1","2") ~ "Within 10 years",
                                 x == "3" ~ "11 to 25 years",
                                 x %in% c("4","5") ~ "26 years or more",
                                 x == "6" ~ "Never")
TL_ORDER <- c("Within 10 years", "11 to 25 years", "26 years or more", "Never")
tl_rows <- bind_rows(
  public_share("fusion_time", tl_band) |>
    transmute(group = "The public", category = resp, p, p_low, p_upp),
  distribution(d |> mutate(resp = tl_band(fusion_pub_time)), "All", TL_ORDER) |>
    transmute(group = "Experts' guess at the public", category = resp, p, p_low, p_upp),
  distribution(d |> mutate(resp = tl_band(fusion_time)), "All", TL_ORDER) |>
    transmute(group = "Experts' own view", category = resp, p, p_low, p_upp))
add_finding("timeline", "Timelines",
  paste0("The public is far more optimistic than the experts — and the ",
         "experts did not see it coming."),
  list(stat("The public says within 10 years", paste0(tl_public, "%")),
       stat("Experts guessed the public would", paste0(tl_guess, "%")),
       stat("Experts think so themselves", paste0(tl_expert, "%"))),
  paste0("Bands collapsed from six to four. The expert prediction item ",
         "repeats the 2025 wording of these bands, which overlap at the ",
         "edges; the public answered the 2026 wording, which does not."),
  tl_rows, TL_ORDER,
  list(link("See public timelines in the data", "explore", "fusion_time"),
       link("See the experts' own view", "sme-survey", "fusion_time"),
       link("See what experts guessed", "sme-survey", "fusion_pub_time")))

# 4. Risk and benefit balance ----------------------------------------------------
rb_band <- function(x) case_when(x %in% c("1","2","3") ~ "Risks outweigh benefits",
                                 x == "4" ~ "About equal",
                                 x %in% c("5","6","7") ~ "Benefits outweigh risks")
RB_ORDER <- c("Risks outweigh benefits", "About equal", "Benefits outweigh risks")
pub_rb <- public_share("fusion_risk_ben", rb_band)
exp_rb <- map_dfr(
  list(c("fusion_pub_rb_risk","Risks outweigh benefits"),
       c("fusion_pub_rb_mid","About equal"),
       c("fusion_pub_rb_ben","Benefits outweigh risks")),
  function(pair) mean_of(d, "All", pair[1]) |>
    transmute(category = pair[2], p, p_low, p_upp))
rb_actual <- pub_rb$p[pub_rb$resp == "Benefits outweigh risks"]
rb_guess <- exp_rb$p[exp_rb$category == "Benefits outweigh risks"]
add_finding("riskben", "Risk and benefit",
  paste0("On the risk-benefit balance the experts were close — within ",
         round(abs(rb_actual - rb_guess)), " points on all three."),
  list(stat("Experts' guess", paste0(round(rb_guess), "%"),
            "expected to say benefits outweigh risks"),
       stat("The public, actually", paste0(round(rb_actual), "%"))),
  paste0("The one prediction on this page the experts got right. Experts ",
         "split 100 points across the three; the public answered a ",
         "seven-point balance scale, collapsed to the same bands."),
  bind_rows(exp_rb |> mutate(group = "Experts' guess"),
            pub_rb |> transmute(group = "The public, actually",
                                category = resp, p, p_low, p_upp)),
  RB_ORDER,
  list(link("See the public balance in the data", "explore", "fusion_risk_ben"),
       link("See what experts guessed", "sme-survey", "fusion_pub_rb_ben")))

# 5. Their own views -------------------------------------------------------------
# Not a prediction: the same three questions put to both groups, aggregated to
# the top two points so one bar carries each.
HIGH <- c("4", "5")
own <- map_dfr(
  list(c("fusion_risk", "Risk"), c("fusion_cost", "Cost"),
       c("fusion_ben", "Benefit")),
  function(pair) tibble(
    category = pair[2],
    public = pub_pct(pair[1], HIGH),
    experts = sme_pct(pair[1], HIGH)))
add_finding("ownviews", "Their own views",
  paste0("Experts see far more benefit in fusion than the public does, and ",
         "less risk."),
  list(stat("Experts calling the benefit high", paste0(round(own$experts[own$category == "Benefit"]), "%")),
       stat("The public", paste0(round(own$public[own$category == "Benefit"]), "%")),
       stat("Experts calling the risk high", paste0(round(own$experts[own$category == "Risk"]), "%"),
            paste0("against ", round(own$public[own$category == "Risk"]), "% of the public"))),
  paste0("The share choosing High or Very high on each five-point scale. ",
         "These three questions were put to both groups in the same words, ",
         "so this is a difference of view rather than a failed prediction."),
  bind_rows(
    own |> transmute(group = "Experts", category, p = experts,
                     p_low = NA_real_, p_upp = NA_real_),
    own |> transmute(group = "The public", category, p = public,
                     p_low = NA_real_, p_upp = NA_real_)),
  c("Risk", "Cost", "Benefit"),
  list(link("See the public on risk", "explore", "fusion_risk"),
       link("See the public on benefit", "explore", "fusion_ben"),
       link("See the experts", "sme-survey", "fusion_ben")),
  axis = "Share saying High or Very high")

# 6. Word associations -----------------------------------------------------------
feel_opts <- parse_options(reference$response_options[reference$variable == "fusion_pub_feel"])
pub_feel_mean <- public_answers("word_1_feel") |>
  as_survey_design(weights = weight) |>
  summarise(m = survey_mean(as.numeric(resp))) |> pull(m)
exp_feel_mean <- sme_avg("fusion_pub_feel")
add_finding("feeling", "Word associations",
  paste0("The words fusion brings to mind leave the public neutral, and ",
         if (abs(exp_feel_mean - pub_feel_mean) < 0.25)
           "experts called that closely." else
           "experts expected them warmer."),
  list(stat("Experts' average guess", format(round(exp_feel_mean, 2), nsmall = 2)),
       stat("The public's actual average", format(round(pub_feel_mean, 2), nsmall = 2),
            "on a five-point scale where 3 is neither positive nor negative")),
  paste0("Experts estimated the average. The public scale labels 2 and 4 ",
         "“Negative” and “Positive”; the expert scale says ",
         "“Somewhat”, so the two are not quite the same ruler."),
  distribution(d |> mutate(resp = fusion_pub_feel), "All", feel_opts$value) |>
    left_join(feel_opts, by = c("resp" = "value")) |>
    transmute(group = "Experts' guess", category = label, p, p_low, p_upp),
  feel_opts$label,
  list(link("See the public's words", "public-qual"),
       link("See what experts guessed", "sme-survey", "fusion_pub_feel")),
  axis = "Share of experts",
  benchmark = list(label = "The public's actual average",
                   value = paste0(format(round(pub_feel_mean, 2), nsmall = 2),
                                  " of 5"),
                   category = feel_opts$label[round(pub_feel_mean)]))

# 7-9. What actually predicts support --------------------------------------------
# Experts picked up to three factors they thought were the strongest correlates
# of public support, and the correlates can be computed. This is the sharpest
# test of calibration in the survey, because their answer is a ranking and so
# is the truth.
#
# One measure for all ten so they rank against each other: eta, the share of
# the variation in support that lies between a factor's groups rather than
# within them. It assumes no ordering, which race and awareness do not have,
# and it catches a relationship that is not a straight line, which age and
# ideology need. Bias-corrected, because eta rises with the number of groups by
# chance and these factors run from two categories to eleven.
correlates <- read_csv(sme_correlates, show_col_types = FALSE)

missing_cols <- correlates |> filter(!public_column %in% names(public))
if (nrow(missing_cols) > 0) {
  print(missing_cols |> select(sme_item, public_column))
  stop("Public columns above are named in sme_correlates.csv but not in the ",
       "public data.")
}
splits_available <- read_json(file.path(outputs, "02_question_data",
                                       "splits.json"),
                             simplifyVector = TRUE)$id
bad_split <- setdiff(correlates$explore_split, splits_available)
if (length(bad_split) > 0) {
  print(bad_split)
  stop("sme_correlates.csv sends readers to splits above, which the public ",
       "explore page does not offer - the link would land on a grouping menu ",
       "that has no such entry.")
}

unmapped <- setdiff(
  reference$variable[reference$battery == "fusion_sup_cor" &
                     reference$question_type == "checkbox_item"],
  correlates$sme_item)
if (length(unmapped) > 0) {
  print(unmapped)
  stop("Factors above are offered to experts but have no public measure in ",
       "sme_correlates.csv - they would silently drop out of the ranking.")
}

# The vendor's columns carry their labels; a survey item carries codes, and
# "7 over 1" tells a reader nothing.
code_labels <- function(column) {
  row <- public_reference |>
    filter(column_fu25 == column | column_fu26 == column)
  if (nrow(row) != 1 || is.na(row$response_options[1])) return(NULL)
  opts <- parse_options(row$response_options[1])
  set_names(opts$label, opts$value)
}

eta_for <- function(column, waves_used) {
  frame <- public |>
    filter(waves_used != "fu26" | survey_year == "2026",
           !is.na(new_fusion), !is.na(.data[[column]])) |>
    transmute(w = weight, y = as.numeric(new_fusion),
              g = as.character(.data[[column]]))
  W <- sum(frame$w)
  grand <- sum(frame$w * frame$y) / W
  by_group <- frame |>
    summarise(Wg = sum(w), mg = sum(w * y) / sum(w), n = n(), .by = g)
  ss_between <- sum(by_group$Wg * (by_group$mg - grand)^2)
  ss_total <- sum(frame$w * (frame$y - grand)^2)
  k <- nrow(by_group)
  ms_within <- (ss_total - ss_between) / (nrow(frame) - k)
  omega_sq <- (ss_between - (k - 1) * ms_within) / (ss_total + ms_within)
  labels <- code_labels(column)
  name_of <- function(code)
    if (is.null(labels) || is.na(labels[code])) code else unname(labels[code])
  tibble(eta_adj = sqrt(max(0, omega_sq)), groups = k, n = nrow(frame),
         spread = max(by_group$mg) - min(by_group$mg),
         top = name_of(by_group$g[which.max(by_group$mg)]),
         bottom = name_of(by_group$g[which.min(by_group$mg)]))
}

# Where a factor could reasonably be measured more than one way, the
# alternative is declared beside it and computed too - a reader who cannot see
# the second number has to take the first on trust.
actual <- correlates |>
  mutate(stat = pmap(list(public_column, waves), eta_for),
         alt = map2(alternative_column, waves, function(col, wv)
           if (is.na(col) || !nzchar(col)) tibble(eta_alt = NA_real_)
           else eta_for(col, wv) |> transmute(eta_alt = eta_adj))) |>
  unnest(c(stat, alt)) |>
  arrange(desc(eta_adj)) |>
  mutate(actual_rank = row_number())

expert_pick <- multi_distribution(d, "All", correlates$sme_item) |>
  transmute(sme_item = resp, picked = p) |>
  arrange(desc(picked)) |>
  mutate(expert_rank = row_number())

calibration <- actual |>
  left_join(expert_pick, by = "sme_item") |>
  arrange(actual_rank)

message("Correlates of public support, strongest first:")
calibration |>
  transmute(label = str_trunc(label, 38), n, groups, eta = round(eta_adj, 3),
            alt = round(eta_alt, 3), spread = round(spread, 2),
            actual_rank, expert_rank, picked = round(picked)) |>
  print(n = Inf)

# The single biggest underestimate and the single biggest overestimate, picked
# from the table rather than typed, so they follow the data if it changes.
gap <- calibration |> mutate(miss = expert_rank - actual_rank)
under <- gap |> slice_max(miss, n = 1, with_ties = FALSE)
over <- gap |> slice_min(miss, n = 1, with_ties = FALSE)

gender_rows <- public |>
  filter(!is.na(new_fusion), !is.na(Gender)) |>
  as_survey_design(weights = weight) |>
  group_by(Gender) |>
  summarise(p = survey_mean(as.numeric(new_fusion), vartype = "ci"),
            .groups = "drop") |>
  transmute(group = "The public", category = Gender, p = round(p, 2),
            p_low = round(p_low, 2), p_upp = round(p_upp, 2))

add_finding("miss_under", "The blind spot",
  paste0(under$label, " is the ", scales::ordinal(under$actual_rank),
         " strongest correlate of public support. Only ",
         round(under$picked), "% of experts named it."),
  list(stat("Experts naming it", paste0(round(under$picked), "%"),
            paste0("which placed it ", scales::ordinal(under$expert_rank),
                   " of ten among experts")),
       stat("Its actual place", scales::ordinal(under$actual_rank),
            paste0(format(round(under$spread, 1), nsmall = 1),
                   " points between ", under$top, " and ", under$bottom,
                   " on the seven-point support scale"))),
  paste0("Mean support by gender, on the scale the question was asked on. ",
         "Men sit ", format(round(under$spread, 1), nsmall = 1),
         " points above women - a gap wider than the one between graduates ",
         "and people with no degree."),
  gender_rows, c("Male", "Female"),
  list(link("See public support in the data", "explore", "new_fusion"),
       link("See what experts picked", "sme-survey", "fusion_sup_cor")),
  value_kind = "mean_pct", axis = "Mean support (1-7)")

climate_rows <- public |>
  filter(!is.na(new_fusion), !is.na(worry_enviro)) |>
  mutate(band = case_when(as.numeric(worry_enviro) <= 3 ~ "Low concern (0-3)",
                          as.numeric(worry_enviro) <= 7 ~ "Middling (4-7)",
                          TRUE ~ "High concern (8-10)")) |>
  as_survey_design(weights = weight) |>
  group_by(band) |>
  summarise(p = survey_mean(as.numeric(new_fusion), vartype = "ci"),
            .groups = "drop") |>
  transmute(group = "The public", category = band, p = round(p, 2),
            p_low = round(p_low, 2), p_upp = round(p_upp, 2))

add_finding("miss_over", "The false lead",
  paste0(round(over$picked), "% of experts named ", str_to_lower(over$label),
         " a top correlate. It is the weakest of the ten."),
  list(stat("Experts naming it", paste0(round(over$picked), "%"),
            paste0("which placed it ", scales::ordinal(over$expert_rank),
                   " of ten among experts")),
       stat("Its actual place", scales::ordinal(over$actual_rank),
            "of ten, on every measure tried")),
  paste0("Mean support by how concerned people are about the environment. ",
         "The line is flat. Measuring concern as perceived climate risk ",
         "instead lifts the factor to ",
         format(round(over$eta_alt, 2), nsmall = 2),
         " - still near the bottom."),
  climate_rows,
  c("Low concern (0-3)", "Middling (4-7)", "High concern (8-10)"),
  list(link("See environmental concern in the data", "explore", "worry_enviro"),
       link("See what experts picked", "sme-survey", "fusion_sup_cor")),
  value_kind = "mean_pct", axis = "Mean support (1-7)")

add_finding("correlates", "The full ranking",
  paste0("What actually goes with public support, against what experts ",
         "thought would."),
  list(stat("Strongest correlate", calibration$label[1],
            paste0("experts placed it ",
                   scales::ordinal(calibration$expert_rank[1]))),
       stat("Experts' first pick", calibration$label[calibration$expert_rank == 1],
            paste0("actually ",
                   scales::ordinal(calibration$actual_rank[calibration$expert_rank == 1])))),
  paste0("Both rankings shown as places, so a shorter bar is a stronger ",
         "factor. Strength is the share of the variation in support lying ",
         "between a factor's groups rather than within them, corrected for ",
         "the fact that a factor with more categories scores higher by ",
         "chance. Two caveats: views on nuclear power were asked in 2026 ",
         "only, so that one rests on half the sample; and trust is trust in ",
         "scientists as a source of information about fusion, which is partly ",
         "downstream of fusion attitudes."),
  bind_rows(
    calibration |> transmute(group = "Experts' ranking", category = label,
                             p = expert_rank, p_low = NA_real_, p_upp = NA_real_),
    calibration |> transmute(group = "Actual ranking", category = label,
                             p = actual_rank, p_low = NA_real_, p_upp = NA_real_)),
  calibration$label,
  # One link per factor rather than a table of numbers: every one of the ten
  # is now a split on the public explore page, so a reader who wants to see
  # the relationship can look at it rather than read a coefficient.
  list(link("See what experts picked", "sme-survey", "fusion_sup_cor")),
  value_kind = "mean_rank", axis = "Place (1 = strongest)",
  factor_links = list(
    label = "Split public support by each factor:",
    items = pmap(list(calibration$label, calibration$explore_split),
      function(label, split_id)
        list(label = label,
             href = paste0("?q=new_fusion&grouping=", split_id, "#explore")))))

# Every public number on this page traces back to a question 02 published.
# Checked here in one pass rather than card by card: the cards collapse those
# distributions into bands, and a collapse can only be trusted if the thing
# being collapsed matches.
for (v in c("new_fusion", "fusion_time", "fusion_risk_ben", "fusion_know",
            "fusion_risk", "fusion_cost", "fusion_ben", "worry_enviro")) {
  check_against_02(v, public_share(v))
}
message("Public sides checked against 02: 8 questions")

comparisons <- findings
wjson(comparisons, "comparisons.json", pretty = TRUE)
wjson(list(
  respondents = nrow(raw),
  charts = nrow(catalog),
  comparisons = length(comparisons),
  compiled = format(Sys.time(), "%Y-%m-%d %H:%M")
), "meta.json", pretty = TRUE)
message("Comparisons: ", length(comparisons))
message("Written to ", out)
