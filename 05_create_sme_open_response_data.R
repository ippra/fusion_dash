# SME Open Responses -----------------------------------------------------------
# The qualitative half of the expert survey, in three parts:
#
#   words          the three words or phrases each expert predicted the public
#                  would give, counted as typed and set beside what the public
#                  actually said. A prediction that can be scored, which is what
#                  makes it worth publishing rather than listing.
#   misunderstood  what experts think non-experts most commonly get wrong.
#   change         the one thing they would change about how fusion is
#                  discussed outside the expert community.
#
# Run after 03, before 06:
#   Rscript 05_create_sme_open_response_data.R
#
# Writes outputs/05_sme_open_responses/.
#
# This is a different survey, not a third wave, and two things follow. There are
# no weights - 153 people identified as having relevant expertise is a purposive
# sample, so every share here is a plain count of the experts who answered. And
# it keeps its own coding and review files rather than adding rows to the
# public ones, for the same reason it keeps its own variable reference.
#
# NOTHING HERE IS SUMMARISED, AND NOTHING IS THEMED BY THIS SCRIPT. The themes
# arrive from sme_themes.csv, assigned by reading. The content review is a
# decision someone made by reading, applied here; an item nobody has read does
# not build.

library(tidyverse)
library(jsonlite)

source(here::here("00_paths.R"))
source(here::here("00_open_responses.R"))

out <- file.path(outputs, "05_sme_open_responses")
dir.create(out, showWarnings = FALSE)
dir.create(file.path(out, "verbatims"), showWarnings = FALSE)

wjson <- function(x, path, pretty = FALSE) {
  write_json(x, file.path(out, path), pretty = pretty, auto_unbox = TRUE,
             na = "null", digits = NA)
}

raw <- read_csv(sme_data, col_types = cols(.default = col_character()),
                guess_max = Inf)
reference <- read_csv(sme_reference, col_types = cols(.default = col_character()),
                      guess_max = Inf)
stoplist <- read_csv(word_stoplist, col_types = cols(.default = col_character()))
theme_rows <- read_csv(sme_themes, col_types = cols(.default = col_character()))
theme_roster <- read_csv(sme_theme_labels,
                         col_types = cols(theme_order = col_integer(),
                                          .default = col_character())) |>
  check_published_column(sme_theme_labels)
review <- read_csv(sme_verbatim_review,
                   col_types = cols(reviewed = col_integer(),
                                    reviewed_on = col_date(),
                                    .default = col_character()))
withheld_content <- read_csv(sme_verbatim_withheld,
                             col_types = cols(.default = col_character()))

ref_of <- function(variable) {
  row <- reference |> filter(variable == !!variable)
  if (nrow(row) != 1) stop("No single SME reference row for ", variable)
  row
}

# The identifier screen holds a response back and records it; the count is
# printed at the end whether or not it is zero.
held_back <- list()

# The experience bands, collapsed from six to three the same way 04 collapses
# them and for the same reason: 153 respondents do not support six. Written out
# here rather than imported because 04 builds a survey design around them and
# this script does not.
EXP_GROUPS <- c("Under 10 years", "10 to 19 years", "20 years or more")

d <- raw |>
  mutate(
    all = "Everyone",
    exp = case_when(
      exp_years %in% c("1", "2") ~ EXP_GROUPS[1],
      exp_years %in% c("3", "4") ~ EXP_GROUPS[2],
      exp_years %in% c("5", "6") ~ EXP_GROUPS[3],
      TRUE                       ~ NA_character_
    )
  )

blank <- function(x) is.na(x) | str_squish(x) == "" | str_squish(x) == "NA"

# Words ------------------------------------------------------------------------
# Three slots, one predicted phrase each. Counted like the public's own words:
# as typed, nothing merged, a phrase used twice by one person counted once. The
# share is of the experts who answered, unweighted, and the caption says so.
word_rows <- map(1:3, function(slot) {
  col <- paste0("fusion_pub_word_", slot)
  tibble(respondent = seq_len(nrow(d)), raw = d[[col]])
}) |>
  bind_rows() |>
  filter(!blank(raw)) |>
  mutate(word = normalise_word(raw)) |>
  filter(word != "")

entries_total <- nrow(word_rows)
word_rows <- word_rows |> anti_join(stoplist, by = "word")
excluded_nonanswer <- entries_total - nrow(word_rows)

sme_respondents <- word_rows |> distinct(respondent) |> nrow()

# What the public actually said, read from 03's output rather than recounted
# here. Two counts of the same corpus would drift, and the whole point of the
# column is that it is the same list the public page draws.
public_words_file <- file.path(outputs, "03_open_responses", "words.json")
if (!file.exists(public_words_file)) {
  stop("Run 03_create_open_response_data.R first: this page sets each ",
       "predicted word against what the public actually said, and reads that ",
       "from ", public_words_file)
}
public_words <- fromJSON(public_words_file)
public_ranked <- as_tibble(public_words$words) |>
  transmute(word, public_pct = pct,
            public_rank = row_number())

# Matched on the shared normalisation and on nothing else. An exact match or
# none: crediting "clean" as a prediction of "clean energy" would be coding,
# and it is the same judgement 03 refuses to make when it keeps the two apart
# in the public list.
words <- word_rows |>
  distinct(respondent, word) |>
  summarise(respondents = n(), .by = word) |>
  mutate(pct = round(100 * respondents / sme_respondents, 2)) |>
  left_join(public_ranked, by = "word") |>
  arrange(desc(respondents), word)

matched <- sum(!is.na(words$public_pct))

words_seen <- review |> filter(item == "words")
if (nrow(words_seen) != 1) {
  stop("No content review recorded for the predicted words. Every open ",
       "response is read before it is published; add a row to ",
       "sme_verbatim_review.csv.")
}
if (words_seen$reviewed != entries_total) {
  stop("The predicted words hold ", entries_total, " entries but ",
       words_seen$reviewed, " were read on ", words_seen$reviewed_on,
       ". Re-read them and update sme_verbatim_review.csv.")
}

wjson(list(
  words = words,
  entries = entries_total,
  excluded_nonanswer = excluded_nonanswer,
  respondents = sme_respondents,
  title = "The words experts expected the public to give",
  # Two numeric columns and no legend to tell them apart, so they are labelled.
  # The public list carries a colour ramp with its own legend and needs none.
  col_labels = list("Experts", "The public"),
  caption = paste0(
    "Experts were asked to predict the first three words or phrases the ",
    "public would give when they hear \"fusion energy\". ",
    format(entries_total, big.mark = ","), " predictions from ",
    sme_respondents, " experts, ", format(nrow(words), big.mark = ","),
    " of them distinct. Bars are the share of those experts who predicted the ",
    "word - a plain count, not weighted, because a purposive sample of ",
    "experts is not a sample of any population. The second column is what the ",
    "public actually said: the weighted share of ",
    format(public_words$respondents, big.mark = ","),
    " respondents across both waves who used that exact word, and its rank ",
    "among the ", format(public_words$words |> nrow(), big.mark = ","),
    " words they gave. Words are matched exactly and nothing is merged, here ",
    "or on the public page, so \"clean\" and \"clean energy\" are separate ",
    "predictions and only one of them can match. ", matched, " of the ",
    nrow(words), " predicted words appear in the public list at all."
  )
), "words.json")

message("Predicted words: ", nrow(words), " distinct across ", entries_total,
        " predictions (", excluded_nonanswer, " non-answers excluded); ",
        matched, " match a word the public gave")

# Verbatims --------------------------------------------------------------------
verbatim_items <- tribble(
  ~id,             ~variable,           ~label,                       ~theme_noun,
  "misunderstood", "fusion_mis",        "What non-experts misunderstand", "misunderstanding",
  "change",        "fusion_change_dis", "What they would change",         "change"
)
# What reads in "did not include a substantive ___". "misunderstanding" and
# "change" do not, so the note uses the plainer word for these two.
EXCLUDED_NOUN <- "answer"

verbatims_cfg <- pmap(verbatim_items, function(id, variable, label, theme_noun) {
  ref <- ref_of(variable)

  seen <- review |> filter(item == id)
  if (nrow(seen) != 1)
    stop("No content review recorded for '", id, "'. Every verbatim is read ",
         "before it is published; add a row to sme_verbatim_review.csv.")

  rows <- d |>
    filter(!blank(.data[[variable]])) |>
    transmute(case_id = response_id, exp, all,
              text = str_squish(.data[[variable]]))

  # Before the withhold, not after: the count recorded is the count of what was
  # read, and a corpus that has grown since is a corpus nobody has read.
  if (nrow(rows) != seen$reviewed)
    stop("'", id, "' holds ", nrow(rows), " responses but ", seen$reviewed,
         " were read on ", seen$reviewed_on, ". Re-read the item and update ",
         "sme_verbatim_review.csv; do not just change the number.")

  held_content <- withheld_content |> filter(item == id)
  missing <- setdiff(held_content$case_id, rows$case_id)
  if (length(missing) > 0)
    stop("sme_verbatim_withheld.csv names ", length(missing), " response(s) ",
         "'", id, "' does not contain: ", paste(missing, collapse = ", "),
         ". A stale withhold hides nothing and masks a real one.")
  rows <- rows |> filter(!case_id %in% held_content$case_id)

  flagged <- screen(rows$text)
  if (any(flagged)) {
    held_back[[id]] <<- rows |> filter(flagged) |> mutate(item = id)
    rows <- rows |> filter(!flagged)
  }

  item_themes <- theme_rows |> filter(item == id)
  has_themes <- nrow(item_themes) > 0
  unpublished <- tibble(theme = character(), n = integer(), total = integer())
  if (has_themes) {
    rows <- rows |> left_join(item_themes |> select(case_id, theme),
                              by = "case_id")
    if (any(is.na(rows$theme)))
      stop("'", id, "' has ", sum(is.na(rows$theme)), " response(s) with no ",
           "theme. A partly-coded item would let the filter hide whatever was ",
           "missed.")
    roster <- theme_roster |> filter(item == id) |> arrange(theme_order)
    unknown <- setdiff(unique(rows$theme), roster$theme)
    if (length(unknown) > 0)
      stop("'", id, "' uses themes missing from sme_theme_labels.csv: ",
           paste(unknown, collapse = ", "))
    rows <- rows |>
      left_join(roster |> select(theme, label, published), by = "theme") |>
      mutate(theme = label) |>
      select(-label)
    # After the review check and the content withhold, so `reviewed` still
    # means the whole corpus was read - these were read and coded, they are
    # simply not drawn.
    unpublished <- rows |> filter(published == "no") |> count(theme, name = "n")
    rows <- rows |> filter(published == "yes") |> select(-published)
    unpublished <- unpublished |> mutate(total = nrow(rows))
    # See 03: ranked by frequency across everyone, with the sheet's own
    # theme_order as the tie-break rather than as the order.
    theme_order <- rows |>
      count(theme, name = "n") |>
      right_join(roster |> filter(published == "yes") |>
                   select(theme = label, theme_order),
                 by = "theme") |>
      mutate(n = coalesce(n, 0L)) |>
      arrange(desc(n), theme_order) |>
      pull(theme)
  }
  answered <- nrow(rows) + sum(unpublished$n)

  candidate_splits <- list(
    list(id = "all", label = "Everyone", key = "all", groups = "Everyone"),
    list(id = "exp", label = "Years in fusion work", key = "exp",
         groups = EXP_GROUPS)
  )
  small <- list()
  splits <- candidate_splits |>
    map(function(sp) {
      sizes <- rows |> count(g = .data[[sp$key]]) |> filter(!is.na(g))
      too_small <- sizes |> filter(n < MIN_GROUP, g %in% sp$groups)
      if (nrow(too_small) > 0 && sp$id != "all")
        small[[sp$id]] <<- too_small |> mutate(split = sp$label)
      sp$groups <- sp$groups[sp$groups %in% sizes$g[sizes$n >= MIN_GROUP]]
      sp
    }) |>
    keep(function(sp) length(sp$groups) > 1 || sp$id == "all")
  dropped_groups <- bind_rows(small)

  theme_dist <- if (!has_themes) NA else
    theme_distribution(rows, theme_order, splits)

  wjson(list(
    id = id, label = label, variable = variable,
    question = ref$question_text,
    asked_if = ref$asked_if_plain,
    contexts = list(),
    context_order = list(),
    themes = if (!has_themes) NA else as.list(theme_order),
    theme_noun = theme_noun,
    theme_dist = theme_dist,
    # The label over the quoted question. The question itself is already
    # in the file as `question`, so it is not repeated here.
    asked_by = "Experts were asked",
    theme_caption = if (!has_themes) NA else paste0(
      "The chart below groups responses into common themes. Click any theme ",
      "to view the original responses, shown exactly as they were submitted."
    ),
    # See 03: the read-and-withheld cautions are off the page, the build
    # checks behind them are not.
    theme_note = if (!has_themes) NA else
      theme_note(answered, nrow(rows), theme_noun, EXCLUDED_NOUN, "expert"),
    cautions = as.list(c(small_group_caution(dropped_groups))) |>
      discard(is.na),
    n = nrow(rows),
    answered = answered,
    # case_id identifies a person and has no business in a published file.
    rows = rows |> select(-case_id, -all, -exp)
  ), file.path("verbatims", paste0(id, ".json")))

  list(id = id, label = label, n = nrow(rows),
       not_shown = sum(unpublished$n),
       question = ref$question_text,
       reviewed = seen$reviewed,
       held_content = nrow(held_content))
})

wjson(list(
  words = list(distinct = nrow(words), respondents = sme_respondents),
  verbatims = verbatims_cfg,
  compiled = format(Sys.time(), "%Y-%m-%d %H:%M")
), "index.json", pretty = TRUE)

for (v in verbatims_cfg) {
  message("  ", v$label, ": ", v$n, " responses")
  message("      read for content: ", v$reviewed, "; withheld by that ",
          "reading: ", v$held_content,
          "; coded but not drawn: ", v$not_shown)
}

if (length(held_back) > 0) {
  report <- bind_rows(held_back)
  message("Held back for review (matched an identifier pattern): ", nrow(report))
  report |> count(item, name = "held") |> print()
  write_csv(report |> select(item, text),
            file.path(out, "held_back_for_review.csv"))
  message("  written to ", file.path(out, "held_back_for_review.csv"))
} else {
  message("Held back for review: none")
}

message("Wrote ", out)
