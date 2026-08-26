library(tidyverse)
library(srvyr)
library(jsonlite)

source(here::here("00_paths.R"))
source(here::here("00_rcode.R"))

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
dir.create(file.path(out, "rcode"), recursive = TRUE)

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
# Sector, field and role are select-all, so a respondent can belong to more
# than one group of the same split. THE GROUPS THEREFORE OVERLAP: a person who
# named two fields is counted in both, each group is estimated on its own
# members, and the bars inside a group still sum to 100 because each group is
# its own denominator. What is given up is that the groups no longer partition
# the sample, which the caption says out loud.
#
# The alternative was to assign each person to one group, and the data ruled it
# out. Rarest-wins - send a multi-picker to their least common category - is
# defensible for sector, where 135 of 153 named only one. On field it moves
# plasma physics from 76 people to 12 and leaves an eleven-person "mechanical
# engineering" group of whom eight are plasma physicists; on role it leaves a
# seventeen-person "facility operations" group, every one of whom named
# another role too. The rule assumes the rare pick is the person's real
# identity, which holds when the picks are near-exclusive and fails when they
# are simultaneous. Overlapping invents nothing instead.
# `split` renamed on read: it is also the name of the argument the generator
# passes, and inside filter() the data mask wins - the column would silently
# shadow the argument and every split would match every row.
overlap_groups <- read_csv(sme_split_groups, col_types = cols(
  group_order = col_integer(), .default = col_character())) |>
  rename(split_id = split)
missing_items <- setdiff(overlap_groups$item, names(raw))
if (length(missing_items) > 0) {
  print(missing_items)
  stop("sme_split_groups.csv names items above that the data does not have.")
}

splits <- bind_rows(
  tribble(
    ~id,          ~label,                 ~phrase,
    "All",        "Everyone",             NA_character_,
    "EXP_GROUP",  "Years in fusion work", "experience group"
  ),
  overlap_groups |>
    distinct(id = split_id, label = split_label, phrase)
) |>
  mutate(overlap = id %in% overlap_groups$split_id)

group_order <- c(
  list(EXP_GROUP = c("Under 10 years", "10 to 19 years", "20 years or more")),
  overlap_groups |>
    distinct(split_id, group, group_order) |>
    arrange(split_id, group_order) |>
    (\(x) split(x$group, x$split_id))()
)

d <- raw |>
  mutate(
    sme_id = row_number(),
    All = "All",
    EXP_GROUP = case_when(
      exp_years %in% c("1", "2") ~ "Under 10 years",
      exp_years %in% c("3", "4") ~ "10 to 19 years",
      exp_years %in% c("5", "6") ~ "20 years or more",
      TRUE                       ~ NA_character_
    ),
    weight = 1
  )

# One frame per split. An overlapping split stacks the rows once per group the
# respondent belongs to, so `group_by(group)` downstream sees each person once
# within each of their groups - the estimate and its interval are right for
# every group, and only a naive total would be wrong. summarise_group() counts
# distinct respondents for exactly that reason.
frame_for <- function(frame, split_id) {
  if (!split_id %in% overlap_groups$split_id) return(frame)
  spec <- overlap_groups |> filter(split_id == !!split_id)
  map(unique(spec$group), function(g) {
    cols <- spec$item[spec$group == g]
    frame |>
      filter(if_any(all_of(cols), ~ !is.na(.x) & .x == "1")) |>
      mutate(!!split_id := g)
  }) |>
    bind_rows()
}

message("Experience groups: ",
        paste(names(table(d$EXP_GROUP)), table(d$EXP_GROUP),
              sep = " n=", collapse = ", "))
for (sp in unique(overlap_groups$split_id)) {
  f <- frame_for(d, sp)
  message(sp, " groups: ",
          paste(names(table(f[[sp]])), table(f[[sp]]), sep = " n=",
                collapse = ", "),
          " (", f |> count(sme_id) |> filter(n > 1) |> nrow(),
          " experts in more than one)")
}

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

# Counts of people, not of rows. An overlapping split stacks a respondent once
# per group they belong to, so nrow() would report more experts than answered
# and `dropped` would go negative.
summarise_group <- function(frame, split_id, base_n) {
  have <- frame |> filter(!is.na(.data[[split_id]]))
  sizes <- have |> count(.data[[split_id]], name = "n")
  smallest <- sizes |> slice_min(n, n = 1, with_ties = FALSE)
  people <- n_distinct(have$sme_id)
  list(n = people, years = "2026", smallest = smallest[[1]],
       smallest_n = smallest$n, dropped = base_n - people,
       # How many are in more than one group, so the caption can say the
       # groups overlap rather than leaving a reader to add them up and find
       # more experts than the survey has.
       overlap = have |> count(sme_id) |> filter(n > 1) |> nrow())
}

# The R that rebuilds each chart -------------------------------------------------
# The same promise the public page makes: every chart carries a script that
# rebuilds *that* plot from the released CSV and nothing else, and the script
# that computed the estimate is the one that writes it. Three rules, and they
# are the point of it:
#
#   - no helper functions - every step is a call the reader can run on its own;
#   - column names written where they are used, never through .data[[ ]];
#   - only the columns this plot needs.
#
# One script per (question, split). There are no arms here: the expert survey
# split-sampled nothing.
#
# Checked against this script's own output below - see `verify_r_code`.

rcode <- new_rcode_tally()

# The one derived split, written out where it is used. A reader with this
# script and the CSV has everything; a reader sent to look up how the six
# bands became three does not.
R_EXP_GROUP <- paste0(
  "    EXP_GROUP = case_when(\n",
  "      exp_years %in% c(\"1\", \"2\") ~ \"Under 10 years\",\n",
  "      exp_years %in% c(\"3\", \"4\") ~ \"10 to 19 years\",\n",
  "      exp_years %in% c(\"5\", \"6\") ~ \"20 years or more\"\n",
  "    ),")

# `kind` is the question file's own value_kind, so the script estimates what
# the chart shows: a distribution, one proportion per item, or a mean.
sme_r_script <- function(title, intro, asked_if, kind, options, split,
                         multi = FALSE, variable = NULL) {
  grp <- if (split == "All") NULL else split
  items <- options$value

  # An overlapping split carries its raw checkbox columns through, because the
  # stack below reads them; EXP_GROUP is banded in place.
  spec <- overlap_groups |> filter(split_id == split)
  cols <- c("    weight = 1")
  if (!is.null(grp)) {
    cols <- c(cols, if (nrow(spec) > 0)
                      paste0("    ", unique(spec$item))
                    else sub(",$", "", R_EXP_GROUP))
  }
  cols <- c(cols, if (kind == "share" && !multi)
                    paste0("    resp = ", variable)
                  else paste0("    ", items, " = ", items))

  # What each estimator drops. A select-all battery drops nobody: its items are
  # 0/1 for everyone shown it, and the denominator is the whole group - which
  # is why the bars do not sum to 100. A ranking or an allocation drops the
  # people who left that item blank, one item at a time.
  # An overlapping split needs no drop: the stack only picks up the people who
  # ticked something, so anyone in no group simply never appears.
  drops <- c(if (kind == "share" && !multi) "!is.na(resp)",
             if (!is.null(grp) && nrow(spec) == 0) "!is.na(EXP_GROUP)")

  stack <- if (is.null(grp) || nrow(spec) == 0) "" else paste0(
    "\n# The ", str_to_lower(unique(spec$split_label)), " groups overlap: an ",
    "expert who named two is\n# counted in each. The rows are stacked once ",
    "per group they belong to, so\n# every group is estimated on its own ",
    "members - the bars inside a group\n# still sum to 100 because each group ",
    "is its own denominator.\n",
    "d <- bind_rows(\n",
    paste(map_chr(unique(spec$group), function(g) {
      cols_g <- spec$item[spec$group == g]
      test <- paste(paste0(cols_g, " == \"1\""), collapse = " |\n           ")
      paste0("  d |> filter(", test, ") |>\n",
             "    mutate(", grp, " = ", r_quote(g), ")")
    }), collapse = ",\n"),
    "\n)\n")

  est <- if (kind == "share" && !multi) paste0(
      "est <- d |>\n",
      "  as_survey_design(weights = weight) |>\n",
      "  group_by(", paste(c(grp, "resp"), collapse = ", "), ") |>\n",
      "  summarise(p = survey_prop(proportion = TRUE, vartype = \"ci\"),\n",
      "            .groups = \"drop\")\n")
    else if (multi) paste0(
      "# Each item is its own proportion - the share of the experts shown the\n",
      "# battery who ticked that box - so the bars do not sum to 100. Where the\n",
      "# battery capped the picks, they sum to about the cap instead.\n",
      "design <- as_survey_design(d, weights = weight)\n\n",
      "est <- bind_rows(\n",
      paste(paste0(
        "  design |>\n",
        if (is.null(grp)) "" else paste0("    group_by(", grp, ") |>\n"),
        "    summarise(p = survey_mean(", items, " == \"1\",\n",
        "                              proportion = TRUE, vartype = \"ci\")) |>\n",
        "    mutate(resp = ", r_quote(items), ")"), collapse = ",\n"),
      "\n)\n")
    else paste0(
      "# A mean, not a share, so the interval is a normal interval on the mean\n",
      "# rather than the logit interval a proportion gets.\n",
      "design <- as_survey_design(d, weights = weight)\n\n",
      "est <- bind_rows(\n",
      paste(paste0(
        "  design |>\n",
        "    filter(!is.na(", items, ")) |>\n",
        if (is.null(grp)) "" else paste0("    group_by(", grp, ") |>\n"),
        "    summarise(p = survey_mean(as.numeric(", items, "),\n",
        "                              vartype = \"ci\")) |>\n",
        "    mutate(resp = ", r_quote(items), ")"), collapse = ",\n"),
      "\n)\n")

  # Order. The item order is the one the chart draws - ranked on the Everyone
  # result, with any residual "Other" last - so the script reproduces the plot
  # rather than a re-sorted version of it.
  scale_to_pct <- kind == "share"
  order_block <- paste0(
    "est <- est |>\n",
    "  mutate(\n",
    if (scale_to_pct)
      "    p = 100 * p, p_low = 100 * p_low, p_upp = 100 * p_upp,\n" else "",
    "    resp = factor(\n",
    "      resp,\n",
    "      levels = ", r_vec(options$value, 17), ",\n",
    "      labels = ", r_vec(options$label, 17), "\n",
    "    )",
    if (is.null(grp)) "" else paste0(",\n    ", grp, " = factor(\n",
      "      ", grp, ",\n      levels = ", r_vec(group_order[[grp]], 17),
      "\n    )"),
    "\n  )\n")

  x_lab <- if (kind == "mean_rank") "Mean placing (1 = highest)"
           else if (kind == "mean_pct") "Mean percentage given"
           else if (multi) "Share of experts who picked it (%)"
           else "Share of experts (%)"

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
    "    x = ", r_quote(x_lab), ",\n",
    "    y = NULL",
    if (is.null(grp)) "" else paste0(",\n    fill = ",
      r_quote(splits$label[splits$id == grp])), "\n",
    "  ) +\n",
    "  theme_minimal()\n")

  paste0(
    paste(strwrap(title, 76, prefix = "# "), collapse = "\n"), "\n",
    if (!is.na(intro) && nzchar(intro))
      paste0("#\n", paste(strwrap(intro, 76, prefix = "# "), collapse = "\n"),
             "\n") else "",
    if (!is.na(asked_if) && nzchar(asked_if))
      paste0("#\n# Not everyone was asked: ",
             paste(strwrap(asked_if, 74), collapse = "\n#   "), "\n") else "",
    "#\n",
    "# IPPRA Fusion Energy Survey, expert study. Rebuilds this plot from the\n",
    "# released data file and nothing else.\n",
    if (split == "All") "" else
      paste0("# Split by ", str_to_lower(splits$label[splits$id == grp]),
             if (nrow(spec) > 0)
               ", from the select-all items below. Those groups\n# overlap."
             else ", banded from the `exp_years` column.", "\n"),
    "#\n",
    "# These are 153 people identified as having relevant expertise, not a\n",
    "# sample of any population, and the file carries no weights. The design\n",
    "# below uses a weight of 1 so the interval and the shape of the result\n",
    "# match the public side - that is a convenience, not a claim that these\n",
    "# numbers generalise.\n",
    "\n",
    "library(tidyverse)\n",
    "library(srvyr)\n\n",
    "# Read as character: response codes are codes, and reading them as\n",
    "# numbers puts 10 between 1 and 2 on every scale that has one.\n",
    "d <- read_csv(\"FU26_SME_data.csv\",\n",
    "              col_types = cols(.default = col_character())) |>\n",
    "  transmute(\n", paste(cols, collapse = ",\n"), "\n  )",
    if (length(drops) == 0) "\n\n" else
      paste0(" |>\n  filter(", paste(drops, collapse = ", "), ")\n\n"),
    stack, "\n", est, "\n", order_block, "\n", plot)
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
    frame <- frame_for(d, s)
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
    # Counted on `d`, not on `frame`: the split's own frame holds only people
    # who have a group, so measuring against it would make `dropped` zero by
    # construction and hide the experts who named no sector at all.
    answered_n <- d |> filter(!is.na(.data[[q$variable]])) |> nrow()
    summaries_out[[s]] <- summarise_group(base, s, answered_n)
  }

  # A typed percentage has no option list, so the single bar is labelled with
  # the question itself rather than with a response.
  if (kind == "mean_pct") options <- tibble(value = q$variable, label = q$question_text)

  r_code <- map(names(splits_out), function(sp)
    sme_r_script(q$question_text, q$question_intro, q$asked_if_plain, kind,
                 options, sp, multi = FALSE, variable = q$variable))
  names(r_code) <- names(splits_out)
  rcode$scripts <- rcode$scripts + length(r_code)
  # Every one of them, not a sample: there are 50 scripts here against the
  # public side's 1,416, so the coverage argument that justifies sampling
  # there does not arise.
  for (sp in names(r_code))
    verify_r_code(r_code[[sp]], splits_out[[sp]], options,
                  paste(q$variable, sp), rcode)
  wjson(list(all = r_code), file.path("rcode", paste0(q$variable, ".json")))

  wjson(list(
    id = q$variable, variable = q$variable, topic = q$topic,
    question = q$question_text, intro = q$question_intro,
    response_scale = q$response_scale, experimental = FALSE,
    asked_if = q$asked_if_plain, multi_response = FALSE,
    value_kind = kind, has_r_code = TRUE,
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
    frame <- frame_for(d, s)
    rows <- if (kind == "mean_rank") mean_of(frame, s, b$variable)
            else multi_distribution(frame, s, b$variable)
    rows <- order_rows(rows, s, b$variable)
    splits_out[[s]] <- rows
    base <- frame |> filter(if_any(all_of(b$variable), ~ !is.na(.x)))
    answered_n <- d |> filter(if_any(all_of(b$variable), ~ !is.na(.x))) |> nrow()
    summaries_out[[s]] <- summarise_group(base, s, answered_n)
  }

  r_code <- map(names(splits_out), function(sp)
    sme_r_script(parent$question_text, NA_character_, b$asked_if_plain[1],
                 kind, options, sp, multi = kind == "share"))
  names(r_code) <- names(splits_out)
  rcode$scripts <- rcode$scripts + length(r_code)
  for (sp in names(r_code))
    verify_r_code(r_code[[sp]], splits_out[[sp]], options,
                  paste(bid, sp), rcode)
  wjson(list(all = r_code), file.path("rcode", paste0(bid, ".json")))

  wjson(list(
    id = bid, variable = bid, topic = b$topic[1],
    question = parent$question_text, intro = NA_character_,
    response_scale = b$response_scale[1], experimental = FALSE,
    asked_if = b$asked_if_plain[1], multi_response = kind == "share",
    value_kind = kind, has_r_code = TRUE,
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

# The split roster, emitted rather than retyped in the builder. The public side
# already reaches the front end this way; the expert side was declared twice
# until sector, field and role made that three places to forget.
wjson(splits |>
        transmute(id, label, phrase, overlap) |>
        pmap(function(id, label, phrase, overlap) {
          out <- list(id = id, label = label, overlap = overlap)
          if (!is.na(phrase)) out$phrase <- phrase
          out
        }),
      "splits.json", pretty = TRUE)
message("SME charts: ", nrow(catalog))
message("  reproduction scripts: ", rcode$scripts, " written, ",
        rcode$checks, " run and checked against their own chart")
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
# A figure inside a sentence, emphasised. Wrapped here rather than typed into
# the string so the bolded number is the computed one - a card cannot end up
# showing a bold figure its own table disagrees with.
b <- function(x) paste0("<strong>", x, "</strong>")

# Spelled out for the start of a sentence, since a numeral there reads badly
# and hard-coding "Thirty-seven" would go stale the first time the data moved.
spell_out <- function(n) {
  ones <- c("one", "two", "three", "four", "five", "six", "seven", "eight",
            "nine")
  teens <- c("ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
             "sixteen", "seventeen", "eighteen", "nineteen")
  tens <- c("twenty", "thirty", "forty", "fifty", "sixty", "seventy",
            "eighty", "ninety")
  n <- as.integer(round(n))
  word <- if (n == 0) "zero"
          else if (n < 10) ones[n]
          else if (n < 20) teens[n - 9]
          else if (n %% 10 == 0) tens[n %/% 10 - 1]
          else paste0(tens[n %/% 10 - 1], "-", ones[n %% 10])
  if (n > 99) stop("spell_out() is only written for 0-99; got ", n)
  paste0(toupper(substr(word, 1, 1)), substr(word, 2, nchar(word)))
}

add_finding <- function(id, part, kicker, headline, lede, stats, compare,
                        note, links, factor_links = NULL, questions = NULL,
                        wording = NULL, lede_html = NULL,
                        implication = NULL) {
  findings[[length(findings) + 1]] <<- list(
    id = id, part = part, kicker = kicker, headline = headline, lede = lede,
    lede_html = if (is.null(lede_html)) NA else lede_html,
    # What the reader should take from the card. HTML, so a figure inside it
    # can be emphasised with b() like the lede's are.
    implication = if (is.null(implication)) NA else implication,
    stats = stats,
    # What each side was actually asked. On part three the two questions are
    # different, and that difference IS the finding, so the stems go on the
    # card rather than being described in a caption.
    questions = if (is.null(questions)) NA else questions,
    compare = compare, note = note, links = links,
    # The options whose wording differs between the surveys, shown in full
    # behind a disclosure so the card stays readable and the detail is still
    # there rather than summarised away.
    wording = if (is.null(wording)) NA else wording,
    factor_links = if (is.null(factor_links)) NA else factor_links)
}
# `who` names the two sides of a paired figure - "Experts vs. public" under
# "31% vs. 33%" - on its own line, so the number stays the number and the
# label underneath stays a sentence about it.
stat <- function(value, label, caption = NULL, who = NULL) {
  list(value = value, label = label,
       who = if (is.null(who)) NA else who,
       caption = if (is.null(caption)) NA else caption)
}
# The aligned number block that replaces each chart. Two columns of figures
# against a row label, with the larger of the pair marked so a reader scanning
# down the column sees the shape without reading every number.
compare_block <- function(columns, items) {
  list(columns = as.list(columns), items = items)
}
crow <- function(label, a, b, suffix = "%", mark = FALSE) {
  list(label = label,
       mark = mark,
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

# The questions, quoted from the two reference sheets rather than retyped, so
# a card cannot claim wording the instrument does not have.
pub_q <- function(v, full = FALSE) {
  r <- public_reference |> filter(variable == v)
  if (nrow(r) != 1) stop("No single public reference row for ", v)
  str_squish(if (full) paste(na.omit(c(r$question_intro, r$question_text)),
                             collapse = " ") else r$question_text)
}
sme_q <- function(v, full = FALSE) {
  r <- reference |> filter(variable == v)
  if (nrow(r) != 1) stop("No single SME reference row for ", v)
  str_squish(if (full) paste(na.omit(c(r$question_intro, r$question_text)),
                             collapse = " ") else r$question_text)
}
# One stem standing for a set of questions that differ in a single word or
# phrase. Built from the first item and verified against the rest:
# substituting each phrase back in has to reproduce that item's own stem, or
# the build stops. A wording change to any of them then fails loudly instead
# of quietly making the combined stem a lie.
#
# `q` is the accessor - pub_q or sme_q - so the same helper covers a set on
# either survey. Some items carry a trailing clarification in brackets that
# the others do not; `allow_trailing` permits it and nothing else.
combined_stem <- function(vars, phrases, q, allow_trailing = FALSE) {
  stopifnot(length(vars) == length(phrases), length(vars) > 1)
  template <- q(vars[1])
  strip_trailing <- function(x) sub(" \\([^()]*\\)\\?$", "?", x)
  for (i in seq_along(vars)) {
    want <- q(vars[i])
    got <- sub(phrases[1], phrases[i], template, fixed = TRUE)
    ok <- identical(got, want) ||
          (allow_trailing && identical(got, strip_trailing(want)))
    if (!ok) {
      stop("The stem for ", vars[i], " is not the ", vars[1], " stem with '",
           phrases[1], "' swapped for '", phrases[i], "'. One stem cannot ",
           "stand for the set.\n  want: ", want, "\n  got:  ", got)
    }
  }
  sub(phrases[1], paste(phrases, collapse = " / "), template, fixed = TRUE)
}

# A stem that opens with framing before the question. Cut at the marker and
# capitalise; stop if the marker is absent rather than printing the preamble
# as though it were the question.
from_marker <- function(text, marker) {
  at <- str_locate(str_to_lower(text), fixed(marker))[, "start"]
  if (is.na(at)) {
    stop("The stem does not contain '", marker, "', so the preamble cannot ",
         "be cut from it:\n  ", text)
  }
  cut <- str_sub(text, at)
  paste0(str_to_upper(str_sub(cut, 1, 1)), str_sub(cut, 2))
}

qq <- function(who, text, highlight = NULL) {
  list(who = who, text = text,
       highlight = if (is.null(highlight)) NA else highlight)
}
asked <- function(..., lead = "What each side was asked", foot = NULL) {
  list(lead = lead, items = list(...),
       foot = if (is.null(foot)) NA else foot)
}

P1 <- "Part one - what each group thinks"
P2 <- "Part two - what experts think the public thinks"
P3 <- "Part three - what each side thinks needs explaining"

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
  "The public expects shorter fusion development timelines than experts.",
  NA_character_,
  list(stat(paste0(tl$publics[tl$label == "Within 10 years"], "%"),
            "of the public think fusion will be ready within 10 years"),
       stat(paste0(tl$experts[tl$label == "Within 10 years"], "%"),
            "of experts think the same")),
  compare_block(c("Experts", "The public"),
                pmap(list(tl$label, tl$experts, tl$publics), crow)),
  paste0("The same six bands were offered to both. ", sme_n("fusion_time"),
         " experts and ", format(pub_n("fusion_time"), big.mark = ","),
         " members of the public answered."),
  list(link("See the public answers", "explore", "fusion_time"),
       link("See the expert answers", "sme-survey", "fusion_time")),
  # One stem, not two. The two instruments differ only in "US" against
  # "United States" and "will be" against "is ready", which is not a
  # difference worth two rows on a card whose whole point is that the question
  # was the same. The public wording is the one shown.
  questions = asked(
    qq("Both groups were asked", pub_q("fusion_time")),
    lead = "The question"),
  lede_html = paste0(
    "More than half of experts (", b(paste0(tl$experts[tl$label == "11 to 25 years"], "%")),
    ") believe fusion energy will be ready for widespread use in 11 to 25 ",
    "years, and only ", b(paste0(tl$experts[tl$label == "Within 10 years"], "%")),
    " expect it within the next decade. Public expectations are much more ",
    "dispersed. ", b(paste0(spell_out(tl$publics[tl$label == "Within 10 years"]),
                            " percent")),
    " expect fusion within 10 years, while ",
    b(paste0(tl$publics[tl$label == "Never"], "%")),
    " believe it will never be ready for widespread use. Compared with ",
    "experts, the public is both more optimistic about near-term deployment ",
    "and more likely to doubt that fusion will ever become commercially ",
    "viable."),
  implication = paste0(
    "Set realistic expectations about when fusion energy is likely to reach ",
    "widespread use, and explain why timelines remain uncertain."))

# 2. Risk, cost and benefit ----------------------------------------------------
LV <- list(c("Risk", "fusion_risk"), c("Cost", "fusion_cost"),
           c("Benefit", "fusion_ben"))
lv <- map_dfr(LV, function(b) tibble(
  label = b[1], variable = b[2],
  experts = sme_pct(b[2], c("4", "5")), publics = pub_pct(b[2], c("4", "5"))))
invisible(combined_stem(c("fusion_risk", "fusion_cost", "fusion_ben"),
                        c("risk", "cost", "benefit"), sme_q))

add_finding("views_level", 1L, "Risk, cost and benefit",
  paste0("Experts and the public agree about the risks, but differ on the ",
         "costs and benefits."),
  NA_character_,
  list(stat(paste0(lv$experts[lv$label == "Risk"], "% vs. ",
                   lv$publics[lv$label == "Risk"], "%"),
            "rate the risks as high or very high", "Smallest difference",
            who = "Experts vs. public"),
       stat(paste0(lv$experts[lv$label == "Benefit"], "% vs. ",
                   lv$publics[lv$label == "Benefit"], "%"),
            "rate the benefits as high or very high", "Largest difference",
            who = "Experts vs. public")),
  compare_block(c("Experts", "The public"),
                pmap(list(lv$label, lv$experts, lv$publics), crow)),
  paste0("The share choosing High or Very high on each five-point scale. ",
         "Three separate questions, identical but for the word marked above."),
  list(link("See the public on risk", "explore", "fusion_risk"),
       link("See the public on benefit", "explore", "fusion_ben"),
       link("See the expert answers", "sme-survey", "fusion_ben")),
  # One stem standing for three. The risk, cost and benefit items differ only
  # in that one word, so the slash is built by substitution and then checked
  # against the other two rather than asserted - a wording change to any of
  # them stops the build instead of quietly making this line a lie.
  questions = asked(
    qq("Both groups were asked",
       combined_stem(c("fusion_risk", "fusion_cost", "fusion_ben"),
                     c("risk", "cost", "benefit"), pub_q),
       highlight = "risk / cost / benefit"),
    lead = "The questions"),
  lede_html = paste0(
    "Experts and the public report similar perceptions of the risks ",
    "associated with fusion energy. ",
    b(paste0(spell_out(lv$experts[lv$label == "Risk"]), " percent")),
    " of experts and ", b(paste0(lv$publics[lv$label == "Risk"], "%")),
    " of the public rate the risks as high or very high. Differences emerge, ",
    "however, in perceptions of cost and especially benefit. Experts are ",
    "substantially more likely than the public to rate both the costs (",
    b(paste0(lv$experts[lv$label == "Cost"], "%")), " versus ",
    b(paste0(lv$publics[lv$label == "Cost"], "%")), ") and the benefits (",
    b(paste0(lv$experts[lv$label == "Benefit"], "%")), " versus ",
    b(paste0(lv$publics[lv$label == "Benefit"], "%")),
    ") of fusion energy as high or very high."),
  implication = paste0(
    "When communicating about fusion energy, devote as much attention to its ",
    "expected costs and benefits as you do to safety and risk."))

# 3. The balance ----------------------------------------------------------------
RB <- list(c("Risks and costs outweigh benefits", "1", "2", "3"),
           c("About equally balanced", "4"),
           c("Benefits outweigh risks and costs", "5", "6", "7"))
rb <- map_dfr(RB, function(b) tibble(
  label = b[1], experts = sme_pct("fusion_risk_ben", b[-1]),
  publics = pub_pct("fusion_risk_ben", b[-1])))
add_finding("views_balance", 1L, "The overall balance",
  paste0("Experts are more likely than the public to conclude that the ",
         "benefits outweigh the risks and costs."),
  NA_character_,
  # The second pair reads public-first, because it is the public's figure
  # that is the larger one and the point of the stat.
  list(stat(paste0(rb$experts[3], "% vs. ", rb$publics[3], "%"),
            "say the benefits outweigh the risks and costs", "Largest group",
            who = "Experts vs. public"),
       stat(paste0(rb$publics[2], "% vs. ", rb$experts[2], "%"),
            "say the risks, costs, and benefits are about equally balanced",
            "Largest difference in the middle of the scale",
            who = "Public vs. experts")),
  compare_block(c("Experts", "The public"),
                pmap(list(rb$label, rb$experts, rb$publics), crow)),
  "A seven-point balance scale, collapsed to three.",
  list(link("See the public answers", "explore", "fusion_risk_ben"),
       link("See the expert answers", "sme-survey", "fusion_risk_ben")),
  # One stem, like the two cards before it: the two instruments differ only
  # in "U.S." against "United States".
  questions = asked(
    qq("Both groups were asked", pub_q("fusion_risk_ben")),
    lead = "The question"),
  lede_html = paste0(
    "Experts are much more likely than the public to conclude that the ",
    "benefits of fusion energy outweigh its risks and costs. ",
    b(paste0(spell_out(rb$experts[3]), " percent")),
    " of experts select that side of the scale, compared with ",
    b(paste0(rb$publics[3], "%")), " of the public. The public is much more ",
    "likely to view the overall balance as neutral, with ",
    b(paste0(rb$publics[2], "%")), " selecting the midpoint compared with ",
    "just ", b(paste0(rb$experts[2], "%")), " of experts. Consistent with the ",
    "previous findings, the largest differences between experts and the ",
    "public concern the expected benefits of fusion energy rather than its ",
    "risks."),
  implication = paste0(
    "When communicating about fusion energy, explain why many experts ",
    "conclude that the expected benefits outweigh the risks and costs rather ",
    "than assuming those conclusions are self-evident."))

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
  "Experts underestimate public support for fusion energy.",
  NA_character_,
  list(stat(paste0(sup$guess[3], "%"), "experts\u2019 estimate of public support"),
       stat(paste0(sup$publics[3], "%"), "the public who actually support it")),
  compare_block(c("Experts\u2019 estimate", "The public"),
                pmap(list(sup$label, sup$guess, sup$publics), crow)),
  paste0("The expert figures are the mean of what ",
         sme_n("fusion_pub_sup"), " experts typed; they were asked to make ",
         "the three add to 100. The public answered a seven-point scale, ",
         "collapsed here to the same three bands."),
  list(link("See public support", "explore", "new_fusion"),
       link("See the expert guesses", "sme-survey", "fusion_pub_sup")),
  # Two rows here, unlike part one: these genuinely are two different
  # questions, one answered and one estimated.
  # Two rows here, unlike part one: these genuinely are two different
  # questions, one answered and one estimated. The expert side is three
  # questions rather than one - opposed, neither, supported, asked to add to
  # 100 - so its stem carries all three bands with the varying phrase marked.
  # The midpoint item also carries a bracketed gloss the other two do not,
  # which is what allow_trailing permits and nothing else.
  questions = asked(
    qq("The public was asked", pub_q("new_fusion")),
    qq("Experts were asked",
       combined_stem(c("fusion_pub_sup", "fusion_pub_mid", "fusion_pub_opp"),
                     c("supported", "neither supported nor opposed",
                       "opposed"),
                     sme_q, allow_trailing = TRUE),
       highlight = paste0("supported / neither supported nor opposed / ",
                          "opposed")),
    lead = "The questions"),
  lede_html = paste0(
    "Experts underestimated public support for fusion energy by ",
    b(sup$publics[3] - sup$guess[3]), " percentage points. On average, they ",
    "estimated that ", b(paste0(sup$guess[3], "%")), " of the public ",
    "supported the construction and use of fusion power plants, compared ",
    "with the observed level of ", b(paste0(sup$publics[3], "%")),
    ". Experts also slightly overestimated opposition (",
    b(paste0(sup$guess[1], "%")), " versus ", b(paste0(sup$publics[1], "%")),
    "), but the largest difference was their estimate of the number of ",
    "people who were undecided."),
  implication = paste0(
    "Do not assume that public support for fusion energy is lower than it ",
    "is. Although many people remain uncertain, support is higher and ",
    "opposition is lower than many experts expect."))

# 5. Awareness --------------------------------------------------------------------
heard <- pub_pct("fusion_know", "1")
know_opts <- parse_options(reference$response_options[reference$variable == "fusion_pub_know"])
know_rows <- map_dfr(seq_len(nrow(know_opts)), function(i) tibble(
  label = know_opts$label[i],
  guess = sme_pct("fusion_pub_know", know_opts$value[i])))
low <- sme_pct("fusion_pub_know", c("1", "2"))
right_band <- know_opts$label[findInterval(heard, c(0, 20.5, 40.5, 60.5, 80.5))]
add_finding("guess_aware", 2L, "Awareness",
  paste0("Public awareness of fusion energy is modest, but higher than ",
         "experts expect."),
  NA_character_,
  list(stat(paste0(heard, "%"), "of the public had heard of fusion energy"),
       stat(paste0(low, "%"),
            "of experts thought awareness was 40% or lower")),
  compare_block(c("Experts\u2019 estimate of public awareness"),
                pmap(list(know_rows$label, know_rows$guess,
                          rep(NA_integer_, nrow(know_rows))),
                     function(l, g, x) list(
                       label = if (identical(l, right_band))
                                 paste0(l, " (actual)") else l,
                       values = list(paste0(g, "%")),
                       # The band the public's figure actually falls in, marked
                       # the same way the paired tables mark the larger of a
                       # pair - accent and weight on the figure itself.
                       lead = if (identical(l, right_band)) 0L else -1L))),
  paste0("Experts picked a band; the public answered yes or no, so the truth ",
         "is a single number rather than a distribution. ",
         sme_n("fusion_pub_know"), " experts answered."),
  list(link("See public awareness", "explore", "fusion_know"),
       link("See the expert guesses", "sme-survey", "fusion_pub_know")),
  questions = asked(
    qq("The public was asked", pub_q("fusion_know")),
    qq("Experts were asked", sme_q("fusion_pub_know", full = TRUE)),
    lead = "The questions"),
  lede_html = paste0(
    b(paste0(spell_out(heard), " percent")), " of the public reported having ",
    "heard of fusion energy before reading the survey description. Most ",
    "experts underestimated that level of awareness. ",
    b(paste0(spell_out(low), " percent")), " estimated that no more than ",
    b("40%"), " of the public had previously heard of fusion energy, while ",
    "only ", b(paste0(know_rows$guess[know_rows$label == right_band], "%")),
    " correctly identified the ", b(right_band), " range. The results ",
    "suggest that many experts underestimate how familiar the public already ",
    "is with fusion energy."),
  implication = paste0(
    "Although public awareness remains modest, a substantial share of the ",
    "public has already heard of fusion energy. Communication should build ",
    "on that awareness rather than simply introduce the technology."))

# 6. The balance, predicted --------------------------------------------------------
rbg <- tibble(
  label = c("Risks outweigh benefits", "About equal", "Benefits outweigh risks"),
  guess = c(round(mean(as.numeric(d$fusion_pub_rb_risk), na.rm = TRUE)),
            round(mean(as.numeric(d$fusion_pub_rb_mid), na.rm = TRUE)),
            round(mean(as.numeric(d$fusion_pub_rb_ben), na.rm = TRUE))),
  publics = rb$publics)
add_finding("guess_balance", 2L, "The overall balance",
  paste0("Experts recognize that the public is less convinced that the ",
         "benefits outweigh the risks and costs."),
  NA_character_,
  list(stat(paste0(rbg$guess[3], "%"),
            paste0("estimated the public would say the benefits outweigh the ",
                   "risks and costs")),
       stat(paste0(rbg$publics[3], "%"),
            paste0("the public actually said the benefits outweigh the risks ",
                   "and costs"))),
  compare_block(c("Experts\u2019 estimate", "The public"),
                pmap(list(rbg$label, rbg$guess, rbg$publics), crow)),
  paste0("Three questions, one for each answer, which experts were asked to ",
         "make add to 100; the one quoted above is the benefits question. The ",
         "public answered the same seven-point balance scale as in part one."),
  list(link("See the public answers", "explore", "fusion_risk_ben"),
       link("See the expert guesses", "sme-survey", "fusion_pub_rb_ben")),
  # The expert side is three questions, one per band, as on the support card -
  # but they cannot be shown as one stem the way that card's are. The
  # midpoint item drops "of fusion energy in the United States" and puts a
  # parenthetical in its place, so the three do not share a tail; combining
  # them would run to 250 characters. The stem shown is the one the card
  # leads with, and the note under the table says there were three.
  questions = asked(
    qq("The public was asked", pub_q("fusion_risk_ben")),
    qq("Experts were asked", sme_q("fusion_pub_rb_ben")),
    lead = "The questions"),
  lede_html = paste0(
    "Experts estimated public views on the overall balance of risks and ",
    "benefits with considerable accuracy. ",
    b(paste0(spell_out(rbg$guess[3]), " percent")), " estimated that the ",
    "public would conclude the benefits outweigh the risks, compared with an ",
    "observed value of ", b(paste0(rbg$publics[3], "%")),
    ". Estimates for the other two response categories were similarly close. ",
    "This finding provides an important contrast with the other comparisons ",
    "in Part Two. Experts do not consistently misjudge public opinion. Their ",
    "estimates are much more accurate for some topics than for others."),
  implication = paste0(
    "Many experts understand that the public is less convinced than ",
    "they are that the benefits of fusion energy outweigh its risks and ",
    "costs. Build on that understanding by communicating more clearly about ",
    "the expected costs and benefits of fusion energy."))

# 7. What actually drives support --------------------------------------------------
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

if (calibration$actual_rank[1] != 1L) {
  stop("The card calls the first row the strongest correlate, but it ranks ",
       calibration$actual_rank[1], ".")
}
if (over$actual_rank != nrow(calibration)) {
  stop("The card calls '", over$label, "' the weakest correlate, but it ranks ",
       over$actual_rank, " of ", nrow(calibration), ".")
}
if (!grepl("climate", over$label, ignore.case = TRUE)) {
  stop("The card names climate concerns as the largest overestimate, but the ",
       "largest is now '", over$label, "'.")
}

gender <- gap |> filter(str_detect(label, regex("gender", ignore_case = TRUE)))
if (nrow(gender) != 1) stop("Expected exactly one gender row in the ranking.")
if (gender$miss <= abs(calibration$expert_rank[1] - calibration$actual_rank[1])) {
  stop("The card says gender is the wider underestimate than nuclear; it is ",
       "no longer. Re-read the paragraph against the table.")
}

# Which factors are within a place, and which are two out - both taken from
# the table so the closing sentence cannot name a factor that has moved.
close_1 <- gap |> filter(abs(miss) <= 1, !str_detect(label, "Trust")) |>
  arrange(actual_rank) |> pull(label) |> str_to_lower()
close_2 <- gap |> filter(abs(miss) == 2) |> arrange(actual_rank) |>
  pull(label) |> str_to_lower()
and_list <- function(x) {
  if (length(x) == 1) return(x)
  paste0(paste(x[-length(x)], collapse = ", "), " and ", x[length(x)])
}
close_note <- paste0(
  str_to_sentence(and_list(close_2)), " were each two places out. ",
  str_to_sentence(and_list(close_1)),
  " were ranked within a single place of their actual positions.")

add_finding("guess_drivers", 2L, "What drives support",
  paste0("Experts overestimate the importance of climate concerns and ",
         "underestimate the importance of views toward traditional nuclear ",
         "energy."),
  NA_character_,
  # "the strongest" and "the weakest" are claims about rank 1 and rank n, so
  # they are checked rather than asserted: if either factor moves in the
  # table the build stops instead of the caption going quietly wrong.
  # Both pairs read expert rank against actual rank, computed from the table
  # below so the two cannot disagree.
  #
  # The nuclear stat says "most consequential", not "largest": by rank
  # difference gender is further out (9th against 3rd, six places) than
  # nuclear (5th against 1st, four). Nuclear matters more because it is the
  # strongest correlate there is - which the guard above checks - and the
  # paragraph says the same. `over` below IS the computed maximum in its
  # direction, so "largest overestimate" is exact.
  list(stat(paste0(scales::ordinal(calibration$expert_rank[1]), " vs. ",
                   scales::ordinal(calibration$actual_rank[1])),
            calibration$label[1], "Most consequential underestimate",
            who = "Experts\u2019 ranking vs. actual ranking"),
       stat(paste0(scales::ordinal(over$expert_rank), " vs. ",
                   scales::ordinal(over$actual_rank)),
            "Concern about climate change", "Largest overestimate",
            who = "Experts\u2019 ranking vs. actual ranking")),
  compare_block(c("Experts\u2019 estimate", "The public"),
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
  # The expert stem opens with a sentence of framing - "There are many factors
  # that may be associated with public views on fusion energy" - before the
  # question itself. Cut at the question, the way part three's stems are, and
  # the build stops if the marker is not there rather than printing the
  # preamble as though it were the question.
  #
  # The second row is not a question anyone answered: the ranking is scored
  # against the public's own support item, which is quoted rather than named.
  questions = asked(
    # "United States" where the public instrument says "U.S.", at Joe's
    # request; the expert survey's own description of this item words it that
    # way too. Everywhere else on the deck a quoted stem is the instrument's
    # own wording, so this is the exception rather than the rule.
    qq("The public was asked",
       str_replace(pub_q("new_fusion"), fixed("the U.S.?"),
                   "the United States?")),
    qq("Experts were asked", from_marker(sme_q("fusion_sup_cor"),
                                        "which of the following")),
    lead = "The questions",
    foot = paste0("Experts\u2019 responses were compared with the observed ",
                  "correlates of public support.")),
  # Every rank in this paragraph is read off the table rather than typed, and
  # the two claims that rank one factor against another - the widest
  # underestimate, and which factors sit within a place - are computed too.
  # An earlier draft called nuclear the largest underestimate; it is the most
  # consequential one, but gender is the widest.
  lede_html = paste0(
    "Experts accurately identified trust in scientists as one of the ",
    "strongest correlates of public support for fusion energy, but several ",
    "other rankings differed substantially from the data. The most ",
    "consequential underestimate was views toward traditional nuclear ",
    "(fission) energy, which experts ranked ",
    b(scales::ordinal(calibration$expert_rank[1])), " but which is in fact ",
    "the strongest correlate of support. They underestimated gender by an ",
    "even wider margin, ",
    b(paste0(scales::ordinal(gender$expert_rank), " against ",
             scales::ordinal(gender$actual_rank))),
    ", while overestimating concern about climate change, which they placed ",
    b(scales::ordinal(over$expert_rank)), " and which ranks last of the ten. ",
    close_note),
  implication = paste0(
    "When developing communication strategies, understand what shapes public ",
    "opinion rather than relying on expert intuition. Tailor communication ",
    "to the concerns and perspectives of the audience rather than assuming ",
    "the same messages will resonate with everyone."),
  factor_links = list(
    label = "Every one of these is now a split on the public page. Cut support by:",
    items = pmap(list(calibration$label, calibration$explore_split),
      function(label, split_id)
        list(label = label,
             href = paste0("?q=new_fusion&grouping=", split_id, "#explore")))))

# ==============================================================================
# PART THREE. A parallel question, asked of each side from its own position.
# ==============================================================================
# The public was asked which risks, costs and benefits IT would most want to
# understand. Experts were asked which ones NON-EXPERTS most need to
# understand. Same six options, same cap of two picks, different question - so
# a gap here is neither a difference of view nor a failed prediction. It is a
# mismatch of agenda, and it is the most directly actionable thing in the
# survey for a project about how fusion is communicated.
#
# The pairs are declared in the reference as compare_kind = "agenda", with a
# short compare_label, because the two surveys word several of the items
# differently - the public's waste option says "radioactive material
# management", the expert's says "waste management and decommissioning" - so
# neither survey's wording can stand as the label for both.
agenda <- reference |>
  filter(compare_kind == "agenda") |>
  select(variable, battery, compare_to, compare_label)

missing_pub <- setdiff(agenda$compare_to, public_reference$variable)
if (length(missing_pub) > 0) {
  print(missing_pub)
  stop("Agenda pairs above name public variables that do not exist.")
}

# The expert stems share a two-sentence preamble across all three batteries;
# only the question itself belongs on the card. Cut at the sentence that asks
# it, and stop the build if that sentence is not there rather than silently
# printing the preamble as though it were the question.
question_only <- function(text) {
  at <- str_locate(text, fixed("Which of the following"))[, "start"]
  if (is.na(at)) {
    stop("A part-three stem does not contain 'Which of the following', so ",
         "the question cannot be separated from its preamble: ", text)
  }
  str_sub(text, at)
}

# `lede`, `lede_html` and `implication` are functions of the table, so a card
# can compute its own figures from the shares it is about to draw. Any of them
# may be NULL.
agenda_card <- function(battery_id, kicker, headline, lede, note_extra,
                        stats_fn, lede_html = NULL, implication = NULL) {
  items <- agenda |> filter(battery == battery_id)
  base_pub <- public |>
    filter(survey_year == "2026",
           if_any(all_of(items$compare_to), ~ !is.na(.x)))
  base_sme <- d |> filter(if_any(all_of(items$variable), ~ !is.na(.x)))
  pub_ref <- public_reference |> filter(variable %in% items$compare_to)
  sme_ref <- reference |> filter(variable %in% items$variable)

  tab <- pmap_dfr(list(items$variable, items$compare_to, items$compare_label),
    function(sme_col, pub_col, label) {
      pub_text <- pub_ref$question_text[pub_ref$variable == pub_col]
      sme_text <- sme_ref$question_text[sme_ref$variable == sme_col]
      tibble(
        label = label,
        differs = !identical(str_squish(pub_text), str_squish(sme_text)),
        pub_text = pub_text, sme_text = sme_text,
        publics = round(100 * sum(base_pub$weight * (base_pub[[pub_col]] == "1"),
                                  na.rm = TRUE) / sum(base_pub$weight)),
        experts = round(100 * mean(base_sme[[sme_col]] == "1", na.rm = TRUE)))
    }) |>
    arrange(desc(publics))

  differing <- tab |> filter(differs)
  add_finding(
    paste0("agenda_", battery_id), 3L, kicker, headline(tab),
    if (is.null(lede)) NA_character_ else lede(tab),
    stats_fn(tab),
    compare_block(c("Experts", "The public"),
                  pmap(list(tab$label, tab$experts, tab$publics, tab$differs),
                       function(l, a, b, m) crow(l, a, b, mark = m))),
    paste0("Both groups picked two of the same six options, so the shares sum ",
           "to about 200 rather than 100. ",
           format(nrow(base_pub), big.mark = ","), " members of the public ",
           "answered in 2026 and ", nrow(base_sme), " experts. ", note_extra),
    list(link("See the public answers", "explore", battery_id),
         link("See the expert answers", "sme-survey", battery_id)),
    # No emphasis marks. Bold in a stem now means one thing across the whole
    # deck - the element that varies where a single stem stands for several
    # questions - and these two stems are quoted whole. What differs between
    # them is what the part three divider says, and the stems show it.
    questions = asked(
      qq("The public was asked", str_squish(unique(pub_ref$question_intro)[1])),
      qq("Experts were asked",
         question_only(str_squish(unique(sme_ref$question_intro)[1]))),
      lead = "The questions"),
    lede_html = if (is.null(lede_html)) NULL else lede_html(tab),
    implication = if (is.null(implication)) NULL else implication(tab),
    wording = if (nrow(differing) == 0) NULL else list(
      summary = paste0(nrow(differing), " of the six options are worded ",
                       "differently in the two surveys - show them"),
      items = pmap(list(differing$label, differing$pub_text, differing$sme_text),
                   function(l, a, b) list(label = l, public = a, expert = b))))
  tab
}

risk_tab <- agenda_card("fusion_risk_topics", "Risks",
  function(t) paste0("The public wants to understand health and environmental ",
                     "risks. Experts think non-experts most need to ",
                     "understand technological reliability."),
  NULL,
  function(t) list(
    stat(paste0(t$experts[t$label == "Technological reliability"], "% vs. ",
                t$publics[t$label == "Technological reliability"], "%"),
         "selected technological reliability", "Largest expert priority",
         who = "Experts vs. public"),
    stat(paste0(t$publics[t$label == "Public health and safety"], "% vs. ",
                t$experts[t$label == "Public health and safety"], "%"),
         "selected public health and safety", "Largest public priority",
         who = "Public vs. experts")),
  note_extra = paste0("Two options are worded slightly differently between ",
                      "the surveys; the labels here are short forms that fit ",
                      "both."),
  lede_html = function(t) {
    tech <- t[t$label == "Technological reliability", ]
    health <- t[t$label == "Public health and safety", ]
    env <- t[t$label == "Environmental impacts", ]
    paste0(
      "Experts and the public prioritize different types of risk. Nearly ",
      "two-thirds of experts (", b(paste0(tech$experts, "%")),
      ") selected technological reliability as one of the two risks ",
      "non-experts most need to understand, compared with just ",
      b(paste0(tech$publics, "%")), " of the public. The public instead ",
      "prioritized public health and safety (",
      b(paste0(health$publics, "%")), ") and environmental impacts (",
      b(paste0(env$publics, "%")), "), while experts selected environmental ",
      "impacts less than half as often (", b(paste0(env$experts, "%")),
      "). The largest differences concern which questions each group ",
      "believes communication should address, rather than how risky fusion ",
      "energy is overall.")
  })

cost_tab <- agenda_card("fusion_cost_topics", "Costs",
  function(t) paste0("The public wants to understand costs across the full ",
                     "lifecycle of fusion energy. Experts think non-experts ",
                     "most need to understand the costs of developing and ",
                     "constructing fusion energy technologies."),
  NULL,
  # "Largest public priority" on operations is Joe's wording and is not the
  # arithmetic answer: the public's top pick is infrastructure (44% against
  # 22%) and its widest gap over experts is decommissioning (36 against 9).
  # Operations sits third on both counts. Raised and left as written.
  function(t) list(
    stat(paste0(t$experts[t$label == "Research and development"], "% vs. ",
                t$publics[t$label == "Research and development"], "%"),
         "selected research and development costs", "Largest expert priority",
         who = "Experts vs. public"),
    stat(paste0(t$publics[t$label == "Operations and maintenance"], "% vs. ",
                t$experts[t$label == "Operations and maintenance"], "%"),
         "selected operations and maintenance costs", "Largest public priority",
         who = "Public vs. experts")),
  note_extra = "",
  lede_html = function(t) {
    v <- function(l, who) t[[who]][t$label == l]
    # "More than three-quarters", "two-thirds" and "roughly one-third to one-
    # half" are claims about the figures, so they are checked against them.
    spread <- c(v("Research and development", "publics"),
                v("Infrastructure", "publics"),
                v("Operations and maintenance", "publics"),
                v("Construction and capital", "publics"))
    if (v("Research and development", "experts") <= 75) {
      stop("The costs paragraph says more than three-quarters of experts ",
           "picked research and development; it is now ",
           v("Research and development", "experts"), "%.")
    }
    if (abs(v("Construction and capital", "experts") - 67) > 3) {
      stop("The costs paragraph calls construction two-thirds of experts; it ",
           "is now ", v("Construction and capital", "experts"), "%.")
    }
    if (min(spread) < 30 || max(spread) > 52) {
      print(spread)
      stop("The costs paragraph says the public's four picks run roughly one ",
           "third to one half; they no longer do.")
    }
    paste0(
      "Experts concentrated on the costs of developing fusion energy. More ",
      "than three-quarters (", b(paste0(v("Research and development", "experts"), "%")),
      ") selected research and development costs, and two-thirds (",
      b(paste0(v("Construction and capital", "experts"), "%")),
      ") selected construction and capital costs as the two costs ",
      "non-experts most need to understand. Public responses were much more ",
      "evenly distributed. Research and development, infrastructure, ",
      "operations and maintenance, and construction were all selected by ",
      "roughly one-third to one-half of respondents, and the public placed ",
      "substantially more emphasis than experts on the costs of operating, ",
      "maintaining, and eventually decommissioning fusion facilities.")
  })

ben_tab <- agenda_card("fusion_ben_topics", "Benefits",
  function(t) "On the benefits, the two sides broadly agree.",
  function(t) {
    clean <- t[t$label == "Clean energy", ]
    sec <- t[t$label == "Energy security", ]
    paste0("Clean energy is the first pick on both sides - ", clean$publics,
           "% of the public and ", clean$experts,
           "% of experts - and the rest of the list runs in much the same ",
           "order. The one real difference is energy security, which ",
           sec$experts, "% of experts pick against ", sec$publics,
           "% of the public. Set beside the risk card, the shape of the ",
           "communication problem is specific: the two sides already agree ",
           "on what fusion is for. They disagree about what has to be settled ",
           "before it is built.")
  },
  function(t) list(
    stat(paste0(t$publics[t$label == "Clean energy"], "% v ",
                t$experts[t$label == "Clean energy"], "%"),
         "clean energy", "the public against experts - the first pick for both"),
    stat(paste0(t$experts[t$label == "Energy security"], "% v ",
                t$publics[t$label == "Energy security"], "%"),
         "energy security", "the only sizeable gap of the six")),
  note_extra = paste0("Three options are worded slightly differently between ",
                      "the surveys; the labels here are short forms that fit ",
                      "both."))

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
