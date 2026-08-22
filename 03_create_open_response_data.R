library(tidyverse)
library(jsonlite)

source(here::here("00_paths.R"))

# Open Responses ---------------------------------------------------------------
# The qualitative half of the public survey, in three parts:
#
#   words      the three word-or-phrase associations each respondent gave, with
#              the valence they attached to each. Already a structured measure -
#              nothing here is coded, only counted.
#   why        why people oppose, support, or have mixed feelings about fusion,
#              asked of whichever group their support score put them in.
#   ask        what people would ask a fusion expert. The FU26 instrument states
#              its own purpose for this item: the answers are meant to be shared
#              with people working on how fusion energy is communicated.
#
# Run after 02, before 04:
#   Rscript 03_create_open_response_data.R
#
# Writes outputs/03_open_responses/.
#
# NOTHING HERE IS THEMED OR SUMMARISED. Words are counted as typed and
# verbatims are carried whole. A theme is a coding decision, and there is no
# coding frame yet; inventing one in a build script would put words in
# respondents' mouths and no reader could tell.

out <- file.path(outputs, "03_open_responses")
unlink(out, recursive = TRUE)
dir.create(file.path(out, "verbatims"), recursive = TRUE)

reference <- read_csv(variable_reference, guess_max = Inf, show_col_types = FALSE)
stoplist <- read_csv(word_stoplist, show_col_types = FALSE)

wjson <- function(x, path, pretty = FALSE) {
  write_json(x, file.path(out, path), pretty = pretty, auto_unbox = TRUE,
             na = "null", digits = NA)
}

read_wave <- function(path) {
  read_csv(path, col_types = cols(.default = col_character()),
           na = c("", "NA"), guess_max = Inf)
}
waves_data <- waves |> mutate(raw = map(data, read_wave))

# Column names differ between waves, so every one is looked up in the reference
# rather than typed here - the same route the closed-ended questions take.
column_for <- function(variable, wave_field) {
  row <- reference |> filter(variable == !!variable)
  if (nrow(row) != 1) stop("No single reference row for ", variable)
  row[[wave_field]]
}

# Screening --------------------------------------------------------------------
# Respondents were promised their answers would be de-identified. Free text can
# carry an identifier whatever the respondent intended, so anything matching one
# of these shapes is held back rather than published, and counted in the report
# at the end.
#
# This is a net, not a review. It catches the mechanical shapes; it cannot catch
# "my brother works at the plant in <town>". A human still has to read these
# before the site goes anywhere public - see README.
IDENTIFIER_PATTERNS <- c(
  email = "[[:alnum:]._%+-]+@[[:alnum:].-]+\\.[[:alpha:]]{2,}",
  url = "(?i)(https?://|www\\.)[[:graph:]]+",
  phone = "(\\+?1[ .-]?)?\\(?[0-9]{3}\\)?[ .-][0-9]{3}[ .-][0-9]{4}",
  long_number = "[0-9]{7,}",
  handle = "(^|[[:space:]])@[[:alnum:]_]{3,}"
)

screen <- function(text) {
  hits <- map(IDENTIFIER_PATTERNS, ~str_detect(text, .x))
  reduce(hits, `|`)
}

# Words ------------------------------------------------------------------------
# Normalised only for case, surrounding whitespace and trailing punctuation.
# Deliberately not lemmatised or merged: "clean" and "clean energy" stay
# separate entries because deciding they are the same word is coding.
normalise_word <- function(x) {
  x |>
    str_squish() |>
    str_to_lower() |>
    str_remove_all("^[[:punct:]]+|[[:punct:]]+$")
}

word_rows <- map2(waves_data$raw, waves_data$year, function(d, year) {
  map(1:3, function(slot) {
    wcol <- column_for(paste0("word_", slot), "column_fu26")
    fcol <- column_for(paste0("word_", slot, "_feel"), "column_fu26")
    tibble(
      year = year,
      respondent = seq_len(nrow(d)),
      weight = as.numeric(d[[weight_var]]),
      raw = d[[wcol]],
      feel = suppressWarnings(as.integer(d[[fcol]]))
    )
  }) |> bind_rows()
}) |>
  bind_rows() |>
  filter(!is.na(raw)) |>
  mutate(word = normalise_word(raw)) |>
  filter(word != "")

entries_total <- nrow(word_rows)
word_rows <- word_rows |> anti_join(stoplist, by = "word")
excluded_nonanswer <- entries_total - nrow(word_rows)

# A word's share is of respondents, not of entries: everyone gave up to three,
# so counting entries would let one person's repetition read as agreement.
# Mentioning a word twice still counts once.
base <- word_rows |>
  distinct(year, respondent, weight) |>
  summarise(w = sum(weight)) |>
  pull(w)

words <- word_rows |>
  distinct(year, respondent, weight, word) |>
  summarise(respondents = n(), weight = sum(weight), .by = word) |>
  mutate(pct = round(100 * weight / base, 2)) |>
  select(-weight) |>
  left_join(
    word_rows |>
      filter(!is.na(feel)) |>
      summarise(valence = round(weighted.mean(feel, weight), 2),
                valence_n = n(), .by = word),
    by = "word"
  ) |>
  arrange(desc(respondents), word)

wjson(list(
  words = words,
  entries = entries_total,
  excluded_nonanswer = excluded_nonanswer,
  respondents = word_rows |> distinct(year, respondent) |> nrow(),
  scale = list(min = 1, max = 5, min_label = "Very negative",
               mid_label = "Neither positive nor negative",
               max_label = "Very positive")
), "words.json")

message("Words: ", nrow(words), " distinct across ", entries_total,
        " entries (", excluded_nonanswer, " non-answers excluded)")

# Verbatims --------------------------------------------------------------------
# The roster of open-ended items this page carries. `context` names a closed
# question whose answer is shown beside each response, where one makes the
# answer readable: knowing someone scored 2 out of 7 on supporting fusion
# plants is what makes their explanation an explanation.
#
# `caution` is shown with the responses. The three why-items are gated on two
# questions, and one of them - fusion_host - randomized the distance to 10 or
# 50 miles. That reaches the answers themselves: 52 responses across the two
# files mention the distance they were shown. A reader comparing them needs to
# know that some were picturing a facility five times further away.
SITING_CAUTION <- paste0(
  "Who was asked this depends partly on how they answered a question about ",
  "hosting a facility nearby - and that question randomly asked about 10 or ",
  "50 miles. Some answers below refer to the distance that respondent was ",
  "shown."
)
verbatim_items <- tribble(
  ~id,          ~variable,              ~label,                          ~context,      ~caution,
  "oppose",     "fusion_oppose_why",    "Why people oppose",             "new_fusion",  SITING_CAUTION,
  "support",    "fusion_support_why",   "Why people support",            "new_fusion",  SITING_CAUTION,
  "uncertain",  "fusion_uncertain_why", "Why people are unsure",         "new_fusion",  SITING_CAUTION,
  "ask",        "fusion_question",      "Questions for a fusion expert", NA_character_, NA_character_
)

held_back <- list()

verbatims_cfg <- pmap(verbatim_items, function(id, variable, label, context,
                                          caution) {
  ref <- reference |> filter(variable == !!variable)

  rows <- map2(waves_data$raw, waves_data$year, function(d, year) {
    col <- ref[[waves$column[waves$year == year]]]
    if (is.na(col)) return(NULL)
    ctx_col <- if (is.na(context)) NA_character_ else
      column_for(context, waves$column[waves$year == year])
    tibble(
      year = year,
      text = str_squish(d[[col]]),
      context = if (is.na(ctx_col)) NA_character_ else d[[ctx_col]]
    )
  }) |>
    bind_rows() |>
    filter(!is.na(text), text != "")

  flagged <- rows |> filter(screen(text))
  if (nrow(flagged) > 0) {
    held_back[[id]] <<- flagged |> mutate(item = id)
  }
  rows <- rows |> filter(!screen(text))

  wjson(list(
    id = id, label = label, variable = variable,
    question = ref$question_text,
    asked_if = ref$asked_if,
    # NA, not NULL: jsonlite writes NULL as {}, which is truthy in JavaScript,
    # so the column would appear on the one item that has no context and its
    # header would render as [object Object].
    context_label = if (is.na(context)) NA_character_ else
      "Support for plants (1-7)",
    caution = caution,
    n = nrow(rows),
    rows = rows
  ), file.path("verbatims", paste0(id, ".json")))

  list(id = id, label = label, n = nrow(rows),
       question = ref$question_text,
       waves = as.list(as.character(sort(unique(rows$year)))))
})

wjson(list(
  words = list(
    distinct = nrow(words),
    respondents = word_rows |> distinct(year, respondent) |> nrow()
  ),
  verbatims = verbatims_cfg,
  compiled = format(Sys.time(), "%Y-%m-%d %H:%M")
), "index.json", pretty = TRUE)

for (v in verbatims_cfg) message("  ", v$label, ": ", v$n, " responses")

# Reported, never silent: a response withheld from the page is a response the
# reader will never know existed unless the number is here.
if (length(held_back) > 0) {
  report <- bind_rows(held_back)
  message("Held back for review (matched an identifier pattern): ", nrow(report))
  report |> count(item, name = "held") |> print()
  write_csv(report |> select(item, year, text),
            file.path(out, "held_back_for_review.csv"))
  message("  written to ", file.path(out, "held_back_for_review.csv"))
} else {
  message("Held back for review: none")
}
