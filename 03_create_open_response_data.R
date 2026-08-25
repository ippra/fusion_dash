library(tidyverse)
library(jsonlite)

source(here::here("00_paths.R"))
source(here::here("00_open_responses.R"))

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
# NOTHING HERE IS SUMMARISED, AND NOTHING IS THEMED BY THIS SCRIPT. Words are
# counted as typed and verbatims are carried whole. Themes exist, but they were
# assigned by reading and arrive from themes.csv; a coding frame invented in a
# build script would put words in respondents' mouths and no reader could tell.
# The same goes for the content review: this script applies a decision someone
# made by reading, and refuses to build an item nobody has read.

out <- file.path(outputs, "03_open_responses")
unlink(out, recursive = TRUE)
dir.create(file.path(out, "verbatims"), recursive = TRUE)

reference <- read_csv(variable_reference, guess_max = Inf, show_col_types = FALSE)
stoplist <- read_csv(word_stoplist, show_col_types = FALSE)

# Themes ------------------------------------------------------------------------
# Hand-coded, one primary theme per response, keyed on the respondent id so the
# coding survives any reordering of the data. Read the whole set to draft the
# themes, read every response to assign one, then read each theme's members
# together to catch the ones that landed in the wrong place - the same three
# passes the codebook takes, and for the same reason: a keyword rule would put
# "I don't know what fusion is, it sounds dangerous" under whichever word it
# matched first.
#
# An item with no coding simply gets no theme column; nothing is guessed.
themes <- read_csv(themes_reference, col_types = cols(
  item = col_character(), case_id = col_character(), year = col_integer(),
  theme = col_character()))
# `published` marks a coded theme that the page does not draw. Two kinds sit
# behind it, and both are declared in the sheet rather than filtered in code,
# because whether a response answered the question is a judgement someone may
# want to overturn and they can only overturn what they can see:
#
#   the non-answers - "I don't know", "na", "Nothing", "No thanks". They are
#   the verbatim equivalent of the entries word_stoplist.csv keeps out of the
#   word counts, and counting them as a theme would let "gave no reason" read
#   as a reason.
#
#   `ask`'s "Not a question", which is not a non-answer: those 16 responses
#   are substantive, and most of them are criticism of the survey itself.
#   They are held back from the chart because they are not questions for a
#   fusion expert, which is what that item is; the count is printed beside it
#   so nobody has to take that on trust.
#
# Either way the responses are read, coded and counted. What changes is
# whether they reach the page.
theme_roster <- read_csv(theme_labels, col_types = cols(
  item = col_character(), theme = col_character(), label = col_character(),
  theme_order = col_integer(), published = col_character())) |>
  check_published_column(theme_labels)

unlabelled <- themes |> anti_join(theme_roster, by = c("item", "theme"))
if (nrow(unlabelled) > 0) {
  print(unlabelled |> count(item, theme))
  stop("Themes above are assigned but have no label in theme_labels.csv.")
}

# Content review ---------------------------------------------------------------
# The identifier screen below sees shapes, not meaning. It cannot tell that a
# response objects to a facility because of who it would bring to the
# neighbourhood. Only reading can, so someone reads every verbatim before it is
# published and records two things: that the item was read, and which responses
# should not be shown.
#
# `verbatim_review.csv` carries the count of responses in the corpus at the
# moment it was read. `03` checks that count against what it is about to
# publish and halts if they differ, because a corpus that grew - a new wave, a
# widened routing rule - is a corpus nobody has read. That check is the whole
# point: without it "reviewed" is a claim in a commit message rather than a
# property of the build.
#
# `verbatim_withheld.csv` names the responses held back and says why, one row
# each. Declared in a file rather than a rule in code because whether a
# response crosses the line is a judgement someone may want to overturn, and
# they can only overturn what they can see.
review <- read_csv(verbatim_review, col_types = cols(
  item = col_character(), reviewed = col_integer(),
  reviewed_on = col_date(), note = col_character()))
withheld_content <- read_csv(verbatim_withheld, col_types = cols(
  item = col_character(), case_id = col_character(), reason = col_character()))

orphan <- withheld_content |> anti_join(review, by = "item")
if (nrow(orphan) > 0) {
  print(orphan)
  stop("Responses above are withheld from an item with no review row.")
}

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

# The three why-items are alternatives: the routing sends each respondent to
# exactly one, so nobody should appear in two. Checked here rather than
# assumed, because two of them landing in the same row would mean the same
# person's words were counted twice and themed twice, and nothing downstream
# would notice. Holds in both waves as released.
why_items <- c("fusion_oppose_why", "fusion_support_why", "fusion_uncertain_why")
doubled <- map2_int(waves_data$raw, waves_data$column, function(d, field) {
  cols <- map_chr(why_items, column_for, wave_field = field)
  sum(rowSums(!is.na(d[, cols[!is.na(cols)], drop = FALSE])) > 1)
})
if (any(doubled > 0)) {
  stop("Respondents answering more than one why-item, by wave: ",
       paste(waves$year, doubled, sep = ": ", collapse = ", "),
       ". They are alternatives - one person cannot have been asked two.")
}

# Words ------------------------------------------------------------------------
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

# The caption is written here rather than in the front end because the expert
# survey has a words question too and it is not this question - experts
# predicted what the public would say and rated nothing. A sentence assembled
# in the engine would have to know which survey it was describing.
wjson(list(
  words = words,
  entries = entries_total,
  excluded_nonanswer = excluded_nonanswer,
  respondents = word_rows |> distinct(year, respondent) |> nrow(),
  scale = list(min = 1, max = 5, min_label = "Very negative",
               mid_label = "Neither positive nor negative",
               max_label = "Very positive"),
  caption = paste0(
    "Everyone was asked for the first three words or phrases they think of ",
    "when they hear \"fusion energy\", and how they feel about each one. ",
    format(entries_total, big.mark = ","), " words from ",
    format(word_rows |> distinct(year, respondent) |> nrow(), big.mark = ","),
    " people, ", format(nrow(words), big.mark = ","), " of them distinct. ",
    "Bars are the weighted share of people who used the word; colour is how ",
    "they felt about it, from very negative to very positive. Words are ",
    "counted as typed and nothing is merged, so \"clean\" and \"clean ",
    "energy\" are separate. ", format(excluded_nonanswer, big.mark = ","),
    " answers that only said so much as \"none\" or \"not sure\" are left out."
  )
), "words.json")

message("Words: ", nrow(words), " distinct across ", entries_total,
        " entries (", excluded_nonanswer, " non-answers excluded)")

# Verbatims --------------------------------------------------------------------
# The roster of open-ended items this page carries. `context` names a closed
# question whose answer is shown beside each response, where one makes the
# answer readable: knowing someone scored 2 out of 7 on supporting fusion
# plants is what makes their explanation an explanation.
#
# Both gate variables sit on the same 1-7 scale, and the instrument labels only
# its ends: 1 is "Strongly oppose", 7 is "Strongly support", and 2 through 6
# carry no wording at all. Band on the survey's own cut points and nothing
# else - 1-2 is what routed a respondent towards the oppose item, 6-7 towards
# support, 3-5 towards neither - because those are the only boundaries the
# instrument itself asserts.
#
# An earlier five-band scheme cut at 1 / 2-3 / 4 / 5-6 / 7, invented here
# rather than read off the routing, and it crossed the gate boundaries in both
# directions. It labelled a 5 "Supports" and a 3 "Opposes" when the survey had
# treated both as middle ground, so 395 responses in the unsure item read as
# support on both gate columns and 118 read as opposition - a contradiction
# the coding did not contain, every one of them caused by a 5 or a 3. Bands
# that disagree with the routing make the routing look broken.
SUPPORT_BANDS <- c("Opposes", "Neither for nor against", "Supports")

support_band <- function(x) {
  v <- suppressWarnings(as.integer(x))
  case_when(
    v %in% 1:2  ~ SUPPORT_BANDS[1],
    v %in% 3:5  ~ SUPPORT_BANDS[2],
    v %in% 6:7  ~ SUPPORT_BANDS[3],
    TRUE        ~ NA_character_
  )
}

# Both sides of the gate, not just one: a person reached these questions
# because of how they answered about power plants OR about a facility near
# them, and the two can disagree.
GATE_CONTEXTS <- tribble(
  ~variable,     ~label,
  "new_fusion",  "Fusion power plants",
  "fusion_host", "A facility nearby"
)

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
#
# The second half of the caution is filled in per item with that item's own
# withheld count, because "some responses are not shown" without a number is
# the kind of caveat a reader cannot act on.
# Reported, never silent, and the same rule as the identifier screen: a
# response withheld from the page is one the reader will never know existed
# unless the number is here.
routing_caution <- function(withheld) {
  n <- sum(withheld)
  if (n == 0) return(NULL)
  paste0(
    "The condition above is 2026's. In 2025 it was looser - either question ",
    "was enough, rather than both - so 2025 asked this of people 2026 would ",
    "not have. Holding both years to the same condition makes them ",
    "comparable and withholds ", n, " responses from 2025."
  )
}
#
# The order here is the order the Show menu lists them in, after the word
# associations the front end puts first. Support before uncertainty before
# opposition rather than the routing's own order: the menu is read top to
# bottom and the three why-items are one scale, so they run down it.
verbatim_items <- tribble(
  ~id,          ~variable,              ~label,                        ~gated, ~theme_noun, ~excluded_noun, ~caution,
  "ask",        "fusion_question",      "Questions for fusion experts", FALSE, "question",  "question",     NA_character_,
  "support",    "fusion_support_why",   "Reasons for support",         TRUE,   "reason",    "reason",       SITING_CAUTION,
  "uncertain",  "fusion_uncertain_why", "Reasons for uncertainty",     TRUE,   "reason",    "reason",       SITING_CAUTION,
  "oppose",     "fusion_oppose_why",    "Reasons for opposition",      TRUE,   "concern",   "concern",      SITING_CAUTION
)

held_back <- list()

verbatims_cfg <- pmap(verbatim_items, function(id, variable, label, gated,
                                          theme_noun, excluded_noun, caution) {
  ref <- reference |> filter(variable == !!variable)
  contexts <- if (gated) GATE_CONTEXTS else GATE_CONTEXTS[0, ]

  rows <- map2(waves_data$raw, waves_data$year, function(d, year) {
    field <- waves$column[waves$year == year]
    col <- ref[[field]]
    if (is.na(col)) return(NULL)
    out <- tibble(year = year, case_id = d$case_id,
                  text = str_squish(d[[col]]))
    for (k in seq_len(nrow(contexts))) {
      src <- column_for(contexts$variable[k], field)
      out[[paste0("ctx_", contexts$variable[k])]] <-
        if (is.na(src)) NA_character_ else support_band(d[[src]])
    }
    # One routing rule across both waves - see why_item_kept() in 00_paths.R.
    # Applied before the text filter so the withheld count is of responses,
    # not of everyone the gate reached.
    if (gated) {
      out <- out |>
        filter(why_item_kept(id, d[[column_for("new_fusion", field)]],
                             d[[column_for("fusion_host", field)]]))
    }
    out
  }) |>
    bind_rows() |>
    filter(!is.na(text), text != "")

  # What the rule withheld, by wave, so the number is on the page and in this
  # log rather than inferred from a total that quietly shrank.
  withheld <- if (!gated) integer(0) else
    map2_int(waves_data$raw, waves_data$year, function(d, year) {
      field <- waves$column[waves$year == year]
      col <- ref[[field]]
      if (is.na(col)) return(0L)
      answered <- !is.na(d[[col]]) & str_squish(d[[col]]) != ""
      sum(answered & !why_item_kept(id, d[[column_for("new_fusion", field)]],
                                    d[[column_for("fusion_host", field)]]))
    })

  # Nothing is published that nobody has read. The count in the review file is
  # the size of the corpus at the moment it was read; if what we are about to
  # publish is a different size, the difference is unread and the build stops.
  seen <- review |> filter(item == id)
  if (nrow(seen) != 1) {
    stop("No content-review row for '", id, "' in verbatim_review.csv. Read ",
         "the item, then record it - see the open-response-themes skill.")
  }
  if (nrow(rows) != seen$reviewed) {
    stop("'", id, "' holds ", nrow(rows), " responses but ", seen$reviewed,
         " were read for content on ", seen$reviewed_on, ". The difference ",
         "has not been read. Re-review the item and update ",
         "verbatim_review.csv.")
  }

  # Held back by that reading, with the reason recorded beside each one.
  held_content <- withheld_content |> filter(item == id)
  missing_id <- setdiff(held_content$case_id, rows$case_id)
  if (length(missing_id) > 0) {
    stop("verbatim_withheld.csv names ", length(missing_id), " response(s) in ",
         "'", id, "' that the corpus does not contain. A stale withhold hides ",
         "nothing and masks a real one.")
  }
  rows <- rows |> filter(!case_id %in% held_content$case_id)

  # Themes joined on the respondent id, then the id dropped: it identifies a
  # person and has no business in a published file.
  coded <- themes |> filter(item == id)
  has_themes <- nrow(coded) > 0
  unpublished <- tibble(theme = character(), n = integer(), total = integer())
  if (has_themes) {
    rows <- rows |>
      left_join(coded |> select(case_id, theme), by = "case_id")
    uncoded <- sum(is.na(rows$theme))
    if (uncoded > 0) {
      stop(uncoded, " responses to ", id, " have no theme. Every response ",
           "must be coded or none of them, or the filter would silently ",
           "hide whatever was missed.")
    }
    rows <- rows |>
      left_join(theme_roster |> filter(item == id) |>
                  select(theme, label, published),
                by = "theme") |>
      mutate(theme = label) |>
      select(-label)
    # After the review check and the content withhold, so `reviewed` still
    # means the whole corpus was read - these were read and coded, they are
    # simply not drawn.
    unpublished <- rows |> filter(published == "no") |> count(theme, name = "n")
    rows <- rows |> filter(published == "yes") |> select(-published)
    unpublished <- unpublished |> mutate(total = nrow(rows))
  }
  # How many answered, against how many the page draws. They differ once a
  # theme is held back, and a caption saying "1,083 people answered" when
  # 1,170 did would be wrong in the one direction that flatters the item.
  answered <- nrow(rows) + sum(unpublished$n)
  rows <- rows |> select(-case_id)

  flagged <- rows |> filter(screen(text))
  if (nrow(flagged) > 0) {
    held_back[[id]] <<- flagged |> mutate(item = id)
  }
  rows <- rows |> filter(!screen(text))

  # The splits the reader can look at the distribution through. Everyone always;
  # survey year and each gate context only where the data actually holds more
  # than one group, so `ask` - fielded in 2026 only - does not offer a year
  # menu with one entry in it.
  theme_labels_ordered <- theme_roster |> filter(item == id,
                                                published == "yes") |>
    arrange(theme_order) |> pull(label)
  candidate_splits <- c(
    list(list(id = "all", label = "Everyone", key = "all",
              groups = "Everyone")),
    list(list(id = "year", label = "Survey year", key = "year",
              groups = as.character(sort(unique(rows$year))))),
    pmap(contexts, function(variable, label)
      list(id = paste0("ctx_", variable), label = label,
           key = paste0("ctx_", variable), groups = SUPPORT_BANDS))
  )
  dist_rows <- rows |> mutate(all = "Everyone", year = as.character(year))
  # A group too small to carry a percentage does not get drawn as one. Eight
  # people who oppose fusion plants outright and still landed in the unsure
  # item are a real eight people, but "12.5%" beside a group of 1,300 invites
  # a comparison of rates that the smaller number cannot support. Dropped
  # groups are named with their size in the caption rather than vanishing.
  small <- list()
  splits <- candidate_splits |>
    map(function(sp) {
      sizes <- dist_rows |> count(g = .data[[sp$key]]) |> filter(!is.na(g))
      too_small <- sizes |> filter(n < MIN_GROUP, g %in% sp$groups)
      if (nrow(too_small) > 0 && sp$id != "all") {
        small[[sp$id]] <<- too_small |> mutate(split = sp$label)
      }
      # SUPPORT_BANDS is the order, not a promise that all three occur.
      sp$groups <- sp$groups[sp$groups %in% sizes$g[sizes$n >= MIN_GROUP]]
      sp
    }) |>
    keep(function(sp) length(sp$groups) > 1 || sp$id == "all")
  dropped_groups <- bind_rows(small)

  theme_dist <- if (!has_themes) NA else
    theme_distribution(dist_rows, theme_labels_ordered, splits)


  wjson(list(
    id = id, label = label, variable = variable,
    question = ref$question_text,
    asked_if = ref$asked_if_plain,
    # A list, empty for an ungated item. auto_unbox leaves an empty list as [],
    # which the front end reads as no context columns.
    contexts = pmap(contexts, function(variable, label)
      list(key = paste0("ctx_", variable), label = label)),
    context_order = as.list(SUPPORT_BANDS),
    themes = if (!has_themes) NA else as.list(theme_labels_ordered),
    theme_noun = theme_noun,
    # The last sentence is why this is written here: it names the one bar list
    # on the public site that is not a population estimate. On the expert page
    # nothing is weighted, so the same sentence would be false.
    # The question as it was put, in quotes, so a reader is looking at the
    # wording rather than at a paraphrase of it.
    asked_line = paste0("Respondents were asked: \u201c",
                        str_squish(ref$question_text), "\u201d"),
    # What the page below shows, and what a click does. Written here rather
    # than composed in the engine, which cannot know whether the item has a
    # chart under it.
    theme_caption = if (!has_themes) NA else paste0(
      "The chart below groups responses into common themes. Click any theme ",
      "to view the original responses, shown exactly as they were submitted."
    ),
    theme_dist = theme_dist,
    # A list so an item can carry more than one caveat, each its own
    # paragraph. auto_unbox would collapse a single one to a bare string.
    #
    # The item-level ones - what the theme counts are counts of, what was held
    # back from the chart, and that every response was read - were taken off
    # the page on 2026-08-25. The checks behind the last two are untouched and
    # still stop the build: an item nobody has read does not publish, a corpus
    # that has grown since it was read does not publish, and a withhold naming
    # a response the corpus does not contain does not publish.
    # Its own key rather than a caution: the page shows it behind a
    # disclosure, so a reader who wants the counting rule can have it and one
    # who does not is not made to read past it.
    theme_note = if (!has_themes) NA else
      theme_note(answered, nrow(rows), theme_noun, excluded_noun,
                 "respondent"),
    cautions = as.list(c(caution, routing_caution(withheld),
                         small_group_caution(dropped_groups))) |>
      discard(is.na),
    n = nrow(rows),
    answered = answered,
    rows = rows
  ), file.path("verbatims", paste0(id, ".json")))

  list(id = id, label = label, n = nrow(rows),
       not_shown = sum(unpublished$n),
       question = ref$question_text,
       withheld = sum(withheld),
       reviewed = seen$reviewed,
       held_content = nrow(held_content),
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

for (v in verbatims_cfg) {
  message("  ", v$label, ": ", v$n, " responses",
          if (v$withheld > 0)
            paste0(" (", v$withheld, " withheld: 2025 routed them here on a ",
                   "rule 2026 does not use)") else "")
  message("      read for content: ", v$reviewed, "; withheld by that ",
          "reading: ", v$held_content,
          "; coded but not drawn: ", v$not_shown)
}

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
