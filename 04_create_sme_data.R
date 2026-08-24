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
# The point of the survey, and the page that carries it is a set of findings in
# two parts, because the survey asks two different kinds of question and
# running them together is what made the first version of this page hard to
# follow:
#
#   Part one  both groups answered the same question in the same words, so a
#             difference is a difference of view.
#   Part two  experts were asked to predict what the public said, so a
#             difference is a mistake - and can be right or wrong in a way a
#             difference of view cannot.
#
# No charts. Each card is a headline, the numbers behind it, a paragraph
# saying what they mean, and links to the pages where the distributions live.
# Nine small bar charts were what made the page look like data rather than
# read like findings.
#
# Every number and every sentence is computed here, from the same values, so a
# headline cannot drift from the figures beneath it. Every pair is declared in
# the reference's `compare_to`, never matched on the column name: 26 SME
# columns share a name with a public variable and only five ask the same
# question.
public_raw <- map(waves$data, ~read_csv(.x, col_types = cols(.default = col_character()),
                                        na = c("", "NA"), guess_max = Inf))
public <- map2(public_raw, waves$year, function(x, year) {
  x |> mutate(survey_year = as.character(year), weight = as.numeric(.data[[weight_var]]))
}) |>
  bind_rows()

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

# The weighted share of the public giving any of a set of answers, and the
# plain share of experts doing the same. Whole numbers: a decimal implies a
# precision neither sample has.
pub_pct <- function(variable, values) {
  a <- public_answers(variable) |> mutate(hit = resp %in% values)
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
sme_n <- function(variable) sum(!is.na(d[[variable]]))
pub_n <- function(variable) nrow(public_answers(variable))

public_share <- function(variable, recode = NULL) {
  a <- public_answers(variable)
  if (!is.null(recode)) a <- a |> mutate(resp = recode(resp))
  a |>
    as_survey_design(weights = weight) |>
    group_by(resp) |>
    summarise(p = survey_prop(proportion = TRUE, vartype = "ci"), .groups = "drop") |>
    transmute(resp, p = round(100 * p, 2))
}

# Guard: any public number a card shows must match what 02 published.
published <- function(variable) {
  path <- file.path(outputs, "02_question_data", "q", paste0(variable, ".json"))
  if (!file.exists(path)) return(NULL)
  read_json(path, simplifyVector = TRUE)$splits$all$All |>
    as_tibble() |> transmute(resp = as.character(resp), p)
}
check_against_02 <- function(variable) {
  want <- published(variable)
  if (is.null(want)) return(invisible(NULL))
  got <- public_share(variable)
  cmp <- full_join(want, got |> select(resp, p2 = p), by = "resp")
  if (any(is.na(cmp$p)) || any(is.na(cmp$p2)) || max(abs(cmp$p - cmp$p2)) > 0.011) {
    print(cmp)
    stop("A card's public numbers do not match what 02 published for ",
         variable, ".")
  }
}

findings <- list()
add_finding <- function(id, part, kicker, headline, lede, stats, compare,
                        note, links, factor_links = NULL) {
  findings[[length(findings) + 1]] <<- list(
    id = id, part = part, kicker = kicker, headline = headline, lede = lede,
    stats = stats, compare = compare, note = note, links = links,
    factor_links = if (is.null(factor_links)) NA else factor_links)
}
stat <- function(value, label, caption = NULL) {
  list(value = value, label = label,
       caption = if (is.null(caption)) NA else caption)
}
# The aligned number block that replaces each chart. Two columns of figures
# against a row label, with the larger of the pair marked so a reader scanning
# down the column sees the shape without reading every number.
compare_block <- function(columns, items) {
  list(columns = as.list(columns), items = items)
}
crow <- function(label, a, b, suffix = "%") {
  list(label = label,
       values = as.list(c(paste0(a, suffix), paste0(b, suffix))),
       lead = if (a > b) 0L else if (b > a) 1L else -1L)
}
link <- function(label, page, q = NULL, grouping = NULL) {
  query <- c(if (!is.null(q)) paste0("q=", q),
             if (!is.null(grouping)) paste0("grouping=", grouping))
  list(label = label,
       href = if (length(query) == 0) paste0("#", page)
              else paste0("?", paste(query, collapse = "&"), "#", page))
}

P1 <- "Part one - what each group thinks"
P2 <- "Part two - what experts think the public thinks"

# ==============================================================================
# PART ONE. The same question, put to both groups.
# ==============================================================================

# 1. Timelines -----------------------------------------------------------------
TL <- list(c("Within 10 years", "1", "2"), c("11 to 25 years", "3"),
           c("26 years or more", "4", "5"), c("Never", "6"))
tl <- map_dfr(TL, function(b) tibble(
  label = b[1], experts = sme_pct("fusion_time", b[-1]),
  publics = pub_pct("fusion_time", b[-1])))
add_finding("views_time", 1L, "Timelines",
  "The public is both more hopeful and more dismissive than the experts.",
  paste0("Experts converge: ", tl$experts[tl$label == "11 to 25 years"],
         "% put fusion between eleven and twenty-five years away, and just ",
         tl$experts[tl$label == "Within 10 years"],
         "% think it will be ready within ten. The public spreads out in both ",
         "directions - ", tl$publics[tl$label == "Within 10 years"],
         "% say within ten years, and ", tl$publics[tl$label == "Never"],
         "% say never, against ", tl$experts[tl$label == "Never"],
         "% of experts. Optimism about fusion is not something the public ",
         "has to be given; on this question it already has more of it."),
  list(stat(paste0(tl$publics[tl$label == "Within 10 years"], "%"),
            "of the public say within ten years"),
       stat(paste0(tl$experts[tl$label == "Within 10 years"], "%"),
            "of experts say the same")),
  compare_block(c("Experts", "The public"),
                pmap(list(tl$label, tl$experts, tl$publics), crow)),
  paste0("Both groups were asked the same question in the same words, on the ",
         "same six bands. ", sme_n("fusion_time"), " experts and ",
         format(pub_n("fusion_time"), big.mark = ","),
         " members of the public answered."),
  list(link("See the public answers", "explore", "fusion_time"),
       link("See the expert answers", "sme-survey", "fusion_time")))

# 2. Risk, cost and benefit ----------------------------------------------------
LV <- list(c("Risk", "fusion_risk"), c("Cost", "fusion_cost"),
           c("Benefit", "fusion_ben"))
lv <- map_dfr(LV, function(b) tibble(
  label = b[1], variable = b[2],
  experts = sme_pct(b[2], c("4", "5")), publics = pub_pct(b[2], c("4", "5"))))
add_finding("views_level", 1L, "Risk, cost and benefit",
  "The two groups agree about the risk. They disagree about what it buys.",
  paste0("Almost exactly the same share of each group calls the risk high: ",
         lv$experts[lv$label == "Risk"], "% of experts and ",
         lv$publics[lv$label == "Risk"],
         "% of the public. That is the one place on this page where expert ",
         "and public judgement line up. On benefit they part company - ",
         lv$experts[lv$label == "Benefit"], "% of experts call it high ",
         "against ", lv$publics[lv$label == "Benefit"],
         "% of the public - and experts also expect it to cost more. The gap ",
         "between the two groups is not about danger. It is about worth."),
  list(stat(paste0(lv$experts[lv$label == "Risk"], "% v ",
                   lv$publics[lv$label == "Risk"], "%"),
            "call the risk high", "experts against the public"),
       stat(paste0(lv$experts[lv$label == "Benefit"], "% v ",
                   lv$publics[lv$label == "Benefit"], "%"),
            "call the benefit high", "the largest gap of the three")),
  compare_block(c("Experts", "The public"),
                pmap(list(lv$label, lv$experts, lv$publics), crow)),
  paste0("The share choosing High or Very high on each five-point scale. All ",
         "three questions were put to both groups in the same words."),
  list(link("See the public on risk", "explore", "fusion_risk"),
       link("See the public on benefit", "explore", "fusion_ben"),
       link("See the expert answers", "sme-survey", "fusion_ben")))

# 3. The balance ----------------------------------------------------------------
RB <- list(c("Risks and costs outweigh benefits", "1", "2", "3"),
           c("About equally balanced", "4"),
           c("Benefits outweigh risks and costs", "5", "6", "7"))
rb <- map_dfr(RB, function(b) tibble(
  label = b[1], experts = sme_pct("fusion_risk_ben", b[-1]),
  publics = pub_pct("fusion_risk_ben", b[-1])))
far_e <- sme_pct("fusion_risk_ben", "7")
far_p <- pub_pct("fusion_risk_ben", "7")
add_finding("views_balance", 1L, "The overall balance",
  "Experts come down firmly on the benefits. The public sits on the fence.",
  paste0(rb$experts[3], "% of experts say the benefits outweigh the risks and ",
         "costs, against ", rb$publics[3], "% of the public - and ", far_e,
         "% of experts pick the far end of the scale, where only ", far_p,
         "% of the public does. The public's most common answer is that the ",
         "two are about equal. Read with the card before it, the pattern is ",
         "consistent: the public is not more frightened of fusion than ",
         "experts are, it is less convinced that it will pay off."),
  list(stat(paste0(rb$experts[3], "%"), "of experts say benefits win"),
       stat(paste0(rb$publics[3], "%"), "of the public say the same"),
       stat(paste0(rb$publics[2], "%"), "of the public say it is a wash",
            paste0("against ", rb$experts[2], "% of experts"))),
  compare_block(c("Experts", "The public"),
                pmap(list(rb$label, rb$experts, rb$publics), crow)),
  paste0("A seven-point balance scale, collapsed to three. Both groups were ",
         "asked in the same words."),
  list(link("See the public answers", "explore", "fusion_risk_ben"),
       link("See the expert answers", "sme-survey", "fusion_risk_ben")))

# ==============================================================================
# PART TWO. Experts asked to predict what the public said.
# ==============================================================================

# 4. Support ---------------------------------------------------------------------
SUP <- list(c("Opposed", "1", "2", "3"), c("Neither", "4"),
            c("Supported", "5", "6", "7"))
sup <- map_dfr(SUP, function(b) tibble(label = b[1],
                                       publics = pub_pct("new_fusion", b[-1])))
sup$guess <- c(round(mean(as.numeric(d$fusion_pub_opp), na.rm = TRUE)),
               round(mean(as.numeric(d$fusion_pub_mid), na.rm = TRUE)),
               round(mean(as.numeric(d$fusion_pub_sup), na.rm = TRUE)))
add_finding("guess_support", 2L, "Support",
  paste0("Experts underestimate public support by ",
         sup$publics[3] - sup$guess[3], " points."),
  paste0("Asked to split a hundred people into opposed, neither and ",
         "supportive, experts put ", sup$guess[3],
         " in the supportive column. The real figure is ", sup$publics[3],
         ". They read opposition almost exactly right - ", sup$guess[1],
         " against ", sup$publics[1],
         " - so the error is not that they think the public is hostile. It ",
         "is that they expect it to be undecided. The people experts placed ",
         "on the fence are, in fact, already in favour."),
  list(stat(paste0(sup$guess[3], "%"), "experts' guess"),
       stat(paste0(sup$publics[3], "%"), "the public, actually")),
  compare_block(c("Experts' guess", "Actually"),
                pmap(list(sup$label, sup$guess, sup$publics), crow)),
  paste0("The expert figures are the mean of what ",
         sme_n("fusion_pub_sup"), " experts typed; they were asked to make ",
         "the three add to 100. The public answered a seven-point scale, ",
         "collapsed here to the same three bands."),
  list(link("See public support", "explore", "new_fusion"),
       link("See the expert guesses", "sme-survey", "fusion_pub_sup")))

# 5. Awareness --------------------------------------------------------------------
heard <- pub_pct("fusion_know", "1")
know_opts <- parse_options(reference$response_options[reference$variable == "fusion_pub_know"])
know_rows <- map_dfr(seq_len(nrow(know_opts)), function(i) tibble(
  label = know_opts$label[i],
  guess = sme_pct("fusion_pub_know", know_opts$value[i])))
low <- sme_pct("fusion_pub_know", c("1", "2"))
right_band <- know_opts$label[findInterval(heard, c(0, 20.5, 40.5, 60.5, 80.5))]
add_finding("guess_aware", 2L, "Awareness",
  paste0("Nearly half the public had heard of fusion. Most experts guessed ",
         "far fewer."),
  paste0(heard, "% said they had heard of fusion energy before the survey ",
         "described it - the ", right_band, " band. Only ",
         know_rows$guess[know_rows$label == right_band],
         "% of experts picked that band; ", low,
         "% guessed 40% or fewer. Underrating what the public already knows ",
         "is the sort of error that shapes how a field talks: an audience ",
         "assumed to be starting from nothing gets explained to rather than ",
         "argued with."),
  list(stat(paste0(heard, "%"), "of the public had heard of it"),
       stat(paste0(low, "%"), "of experts guessed 40% or fewer")),
  compare_block(c("Experts guessing this band"),
                pmap(list(know_rows$label, know_rows$guess,
                          rep(NA_integer_, nrow(know_rows))),
                     function(l, g, x) list(label = l,
                                            values = list(paste0(g, "%")),
                                            lead = -1L))),
  paste0("Experts picked a band; the public answered yes or no, so the truth ",
         "is a single number rather than a distribution. ",
         sme_n("fusion_pub_know"), " experts answered."),
  list(link("See public awareness", "explore", "fusion_know"),
       link("See the expert guesses", "sme-survey", "fusion_pub_know")))

# 6. Timelines, predicted ----------------------------------------------------------
tlg <- map_dfr(TL, function(b) tibble(
  label = b[1], guess = sme_pct("fusion_pub_time", b[-1]),
  publics = pub_pct("fusion_time", b[-1])))
add_finding("guess_time", 2L, "Timelines",
  "Experts expected the public to be as cautious as they are.",
  paste0("Asked which answer the public gave most often, ", tlg$guess[1],
         "% of experts said within ten years. ", tlg$publics[1],
         "% of the public actually did. The guess tracks the experts' own ",
         "view from part one far more closely than it tracks the public - ",
         "which is what projecting your own frame onto an audience looks ",
         "like in data."),
  list(stat(paste0(tlg$publics[1], "%"), "of the public say within ten years"),
       stat(paste0(tlg$guess[1], "%"), "of experts expected that"),
       stat(paste0(tl$experts[tl$label == "Within 10 years"], "%"),
            "of experts believe it themselves",
            "from part one, for comparison")),
  compare_block(c("Experts' guess", "Actually"),
                pmap(list(tlg$label, tlg$guess, tlg$publics), crow)),
  paste0("The expert prediction item repeats the 2025 wording of these bands, ",
         "which overlap at the edges; the public answered the 2026 wording, ",
         "which does not. The bands still line up one to one in order."),
  list(link("See public timelines", "explore", "fusion_time"),
       link("See the expert guesses", "sme-survey", "fusion_pub_time")))

# 7. The balance, predicted --------------------------------------------------------
rbg <- tibble(
  label = c("Risks outweigh benefits", "About equal", "Benefits outweigh risks"),
  guess = c(round(mean(as.numeric(d$fusion_pub_rb_risk), na.rm = TRUE)),
            round(mean(as.numeric(d$fusion_pub_rb_mid), na.rm = TRUE)),
            round(mean(as.numeric(d$fusion_pub_rb_ben), na.rm = TRUE))),
  publics = rb$publics)
add_finding("guess_balance", 2L, "The overall balance",
  "This one they read right.",
  paste0("On how the public weighs risks against benefits the experts were ",
         "within a few points on all three answers - ", rbg$guess[3],
         "% guessed against ", rbg$publics[3],
         "% actual for benefits outweighing. It is worth saying plainly ",
         "because it bounds the rest of this page: expert intuition about ",
         "the public is not uniformly poor. It fails on how much the public ",
         "knows and how warm it is, and holds on how the public reasons ",
         "about trade-offs."),
  list(stat(paste0(rbg$guess[3], "%"), "experts' guess"),
       stat(paste0(rbg$publics[3], "%"), "the public, actually"),
       stat(paste0(abs(rbg$guess[3] - rbg$publics[3])), "points apart",
            "the closest call on the page")),
  compare_block(c("Experts' guess", "Actually"),
                pmap(list(rbg$label, rbg$guess, rbg$publics), crow)),
  paste0("Experts split 100 points across the three. The public answered the ",
         "same seven-point balance scale as in part one."),
  list(link("See the public answers", "explore", "fusion_risk_ben"),
       link("See the expert guesses", "sme-survey", "fusion_pub_rb_ben")))

# 8. Word associations -------------------------------------------------------------
feel_opts <- parse_options(reference$response_options[reference$variable == "fusion_pub_feel"])
pub_feel_mean <- public_answers("word_1_feel") |>
  as_survey_design(weights = weight) |>
  summarise(m = survey_mean(as.numeric(resp))) |> pull(m)
exp_feel_mean <- sme_avg("fusion_pub_feel")
feel_rows <- map_dfr(seq_len(nrow(feel_opts)), function(i) tibble(
  label = feel_opts$label[i],
  guess = sme_pct("fusion_pub_feel", feel_opts$value[i])))
add_finding("guess_feeling", 2L, "Word associations",
  "The words fusion brings to mind leave the public flat, and experts knew it.",
  paste0("Asked how the public felt about the first three words fusion ",
         "energy brought to mind, experts averaged ",
         format(round(exp_feel_mean, 2), nsmall = 2),
         " on a five-point scale. The public's own average was ",
         format(round(pub_feel_mean, 2), nsmall = 2),
         ". Both sit just above the midpoint: the public is not hostile to ",
         "the words, it is indifferent to them, and experts saw that."),
  list(stat(format(round(exp_feel_mean, 2), nsmall = 2), "experts' average guess"),
       stat(format(round(pub_feel_mean, 2), nsmall = 2), "the public's actual average",
            "3 is neither positive nor negative")),
  compare_block(c("Experts guessing this"),
                pmap(list(feel_rows$label, feel_rows$guess,
                          rep(NA_integer_, nrow(feel_rows))),
                     function(l, g, x) list(label = l,
                                            values = list(paste0(g, "%")),
                                            lead = -1L))),
  paste0("The public scale labels 2 and 4 “Negative” and ",
         "“Positive”; the expert scale says “Somewhat”, so ",
         "the two are not quite the same ruler."),
  list(link("See the words the public gave", "public-qual"),
       link("See the expert guesses", "sme-survey", "fusion_pub_feel")))

# 9. What actually drives support --------------------------------------------------
# Experts named up to three factors they thought were the strongest correlates
# of public support, and the correlates can be computed. Strength is eta,
# bias-corrected: the share of the variation in support that lies between a
# factor's groups rather than within them. One measure for all ten so they rank
# against each other - it assumes no ordering, which race and awareness do not
# have, and it catches a relationship that is not a straight line.
correlates <- read_csv(sme_correlates, show_col_types = FALSE)

splits_available <- read_json(file.path(outputs, "02_question_data",
                                        "splits.json"),
                              simplifyVector = TRUE)$id
bad_split <- setdiff(correlates$explore_split, splits_available)
if (length(bad_split) > 0) {
  print(bad_split)
  stop("sme_correlates.csv sends readers to splits above, which the public ",
       "explore page does not offer.")
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

eta_for <- function(column, waves_used) {
  frame <- public |>
    filter(waves_used != "fu26" | survey_year == "2026",
           !is.na(new_fusion), !is.na(.data[[column]])) |>
    transmute(w = weight, y = as.numeric(new_fusion),
              g = as.character(.data[[column]]))
  W <- sum(frame$w)
  grand <- sum(frame$w * frame$y) / W
  by_group <- frame |>
    summarise(Wg = sum(w), mg = sum(w * y) / sum(w), .by = g)
  ss_between <- sum(by_group$Wg * (by_group$mg - grand)^2)
  ss_total <- sum(frame$w * (frame$y - grand)^2)
  k <- nrow(by_group)
  ms_within <- (ss_total - ss_between) / (nrow(frame) - k)
  tibble(eta_adj = sqrt(max(0, (ss_between - (k - 1) * ms_within) /
                              (ss_total + ms_within))),
         spread = max(by_group$mg) - min(by_group$mg))
}

calibration <- correlates |>
  mutate(stat = pmap(list(public_column, waves), eta_for)) |>
  unnest(stat) |>
  arrange(desc(eta_adj)) |>
  mutate(actual_rank = row_number()) |>
  left_join(multi_distribution(d, "All", correlates$sme_item) |>
              transmute(sme_item = resp, picked = round(p)) |>
              arrange(desc(picked)) |>
              mutate(expert_rank = row_number()),
            by = "sme_item") |>
  arrange(actual_rank)

message("Correlates of public support, strongest first:")
calibration |>
  transmute(label = str_trunc(label, 38), eta = round(eta_adj, 2),
            actual_rank, expert_rank, picked) |>
  print(n = Inf)

# The single largest underestimate and overestimate, taken from the table
# rather than typed, so the sentence follows the data if it changes.
gap <- calibration |> mutate(miss = expert_rank - actual_rank)
under <- gap |> slice_max(miss, n = 1, with_ties = FALSE)
over <- gap |> slice_min(miss, n = 1, with_ties = FALSE)

add_finding("guess_drivers", 2L, "What drives support",
  paste0("Experts looked for the driver of support in politics and climate. ",
         "It is mostly ", str_to_lower(calibration$label[1]), "."),
  paste0("The strongest thing that goes with public support for fusion is ",
         "what people already think about nuclear fission; experts placed it ",
         scales::ordinal(calibration$expert_rank[1]), " of ten. The biggest ",
         "miss in the other direction is ", str_to_lower(under$label), ", the ",
         scales::ordinal(under$actual_rank), " strongest correlate, named by ",
         "only ", under$picked, "% of experts - men sit ",
         format(round(under$spread, 1), nsmall = 1),
         " points above women on the seven-point support scale. And ",
         over$picked, "% named ", str_to_lower(over$label),
         ", which comes last of the ten on every measure tried."),
  list(stat(scales::ordinal(calibration$expert_rank[1]),
            paste0("where experts placed ", str_to_lower(calibration$label[1])),
            "it is actually the strongest"),
       stat(paste0(under$picked, "%"),
            paste0("named ", str_to_lower(under$label)),
            paste0("actually ", scales::ordinal(under$actual_rank), " of ten")),
       stat(paste0(over$picked, "%"),
            paste0("named ", str_to_lower(over$label)),
            paste0("actually ", scales::ordinal(over$actual_rank), " of ten"))),
  compare_block(c("Experts' place", "Actual place"),
                pmap(list(calibration$label, calibration$expert_rank,
                          calibration$actual_rank),
                     function(l, e, a) list(label = l,
                       values = as.list(c(scales::ordinal(e), scales::ordinal(a))),
                       lead = if (a < e) 1L else if (e < a) 0L else -1L))),
  paste0("Strength is the share of the variation in support lying between a ",
         "factor's groups rather than within them, corrected for the fact ",
         "that a factor with more categories scores higher by chance. Two ",
         "caveats: views on nuclear power were asked in 2026 only, so that ",
         "one rests on half the sample; and trust is trust in scientists as a ",
         "source of information about fusion, which is partly downstream of ",
         "fusion attitudes. Measuring partisanship as ideology rather than ",
         "party lifts it from ",
         format(round(calibration$eta_adj[calibration$sme_item == "fusion_sup_cor_party"], 2), nsmall = 2),
         " to 0.15, and environmental concern as perceived climate risk from ",
         "0.00 to 0.10 - neither moves it across the table."),
  list(link("See what experts picked", "sme-survey", "fusion_sup_cor")),
  factor_links = list(
    label = "Every one of these is now a split on the public page. Cut support by:",
    items = pmap(list(calibration$label, calibration$explore_split),
      function(label, split_id)
        list(label = label,
             href = paste0("?q=new_fusion&grouping=", split_id, "#explore")))))

# Every public number on this page traces back to a question 02 published.
for (v in c("new_fusion", "fusion_time", "fusion_risk_ben", "fusion_know",
            "fusion_risk", "fusion_cost", "fusion_ben")) {
  check_against_02(v)
}
message("Public sides checked against 02: 7 questions")

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
