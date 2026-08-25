# Open-response machinery -------------------------------------------------------
# The rules the qualitative pages share, declared once because two surveys now
# have one. `03_create_open_response_data.R` builds the public page and
# `05_create_sme_open_response_data.R` the expert page; a screen, a word
# normalisation or a bar computed one way on one page and another way on the
# other would make the two pages disagree without either being wrong.
#
# Sourced after 00_paths.R. Nothing here reads a file or knows a path.

# Screening --------------------------------------------------------------------
# Respondents were promised their answers would be de-identified. Free text can
# carry an identifier whatever the respondent intended, so anything matching one
# of these shapes is held back rather than published, and counted in the report
# at the end.
#
# This is a net, not a review. It catches the mechanical shapes; it cannot catch
# "my brother works at the plant in <town>", and on the expert survey it cannot
# catch a respondent naming the event they run. The reading that catches meaning
# is the content review; this runs alongside it, not instead of it.
IDENTIFIER_PATTERNS <- c(
  email = "[[:alnum:]._%+-]+@[[:alnum:].-]+\\.[[:alpha:]]{2,}",
  url = "(?i)(https?://|www\\.)[[:graph:]]+",
  phone = "(\\+?1[ .-]?)?\\(?[0-9]{3}\\)?[ .-][0-9]{3}[ .-][0-9]{4}",
  long_number = "[0-9]{7,}",
  handle = "(^|[[:space:]])@[[:alnum:]_]{3,}"
)

screen <- function(text) {
  hits <- purrr::map(IDENTIFIER_PATTERNS, ~stringr::str_detect(text, .x))
  purrr::reduce(hits, `|`)
}

# Words ------------------------------------------------------------------------
# Normalised only for case, surrounding whitespace and trailing punctuation.
# Deliberately not lemmatised or merged: "clean" and "clean energy" stay
# separate entries because deciding they are the same word is coding.
#
# The expert survey asks its own respondents to predict the public's words, and
# the two lists are matched on this same normalisation and on nothing else - an
# exact match or none, so "clean" predicting "clean energy" counts as a miss
# rather than being quietly credited.
normalise_word <- function(x) {
  x |>
    stringr::str_squish() |>
    stringr::str_to_lower() |>
    stringr::str_remove_all("^[[:punct:]]+|[[:punct:]]+$")
}

# Theme distribution -----------------------------------------------------------
# The share of each item's responses carrying each theme, for the page to draw
# above the verbatims. Computed on the rows that are actually published - after
# any routing restriction, the content withhold and the identifier screen - so
# the bars and the table beneath them cannot disagree. Computing them in the
# front end from the rows would give the same answer today and quietly stop
# doing so the first time a row is held back.
#
# Unweighted: these are counts of texts that were read and coded, and the
# percentage is that count over its group. On the public page that makes this
# the one bar list that is not a population estimate, and the caption says so.
# On the expert page nothing is weighted, so the distinction does not arise -
# which is why the sentence is written by each script rather than here.
#
# The count rides on every bar regardless, because a theme with two members
# must not read as a rate.
#
# Percentages are within a group and across themes, so each group sums to 100.
# One theme per response is what makes that true; a multi-response item could
# not be drawn this way.
theme_distribution <- function(rows, theme_order, splits) {
  values <- purrr::map(splits, function(sp) {
    key <- sp$key
    d <- rows |>
      # Only the groups this split actually draws. A group dropped for size
      # would otherwise survive summarise() and land in the file with a null
      # name, which the front end ignores and a reader of the JSON would not.
      dplyr::filter(.data[[key]] %in% sp$groups) |>
      dplyr::summarise(n = dplyr::n(), .by = tidyselect::all_of(c("theme", key))) |>
      dplyr::rename(group = tidyselect::all_of(key)) |>
      # Complete the grid so a theme absent from a group draws an empty bar
      # rather than closing the gap and misaligning the row.
      tidyr::complete(theme = theme_order, group = sp$groups,
                      fill = list(n = 0L)) |>
      dplyr::mutate(pct = round(100 * n / sum(n), 1), .by = group) |>
      dplyr::mutate(theme = factor(theme, levels = theme_order),
                    group = factor(group, levels = sp$groups)) |>
      dplyr::arrange(theme, group)
    purrr::pmap(list(as.character(d$theme), as.character(d$group), d$pct, d$n),
                function(theme, group, pct, n)
                  list(theme = theme, group = group, pct = pct, n = n))
  })
  names(values) <- purrr::map_chr(splits, "id")
  list(
    splits = purrr::map(splits, function(sp)
      list(id = sp$id, label = sp$label, groups = as.list(sp$groups))),
    values = values
  )
}

# A group too small to carry a percentage does not get drawn as one. Eight
# people who oppose fusion plants outright and still landed in the unsure item
# are a real eight people, but "12.5%" beside a group of 1,300 invites a
# comparison of rates that the smaller number cannot support. Dropped groups
# are named with their size in the caption rather than vanishing.
MIN_GROUP <- 30L

small_group_caution <- function(dropped) {
  if (nrow(dropped) == 0) return(NULL)
  paste0(
    "One split leaves a group out: ",
    paste0(dropped$split, " - ", dropped$g, ", ", dropped$n, " responses",
           collapse = "; "),
    ". Too few to draw as a share without inviting a comparison the number ",
    "cannot support. Those responses are still in the table below."
  )
}

# Reported, never silent - the same rule the identifier screen and the content
# withhold follow. A response held back from the page is one the reader will
# never know existed unless the number is here, and the wording says which kind
# it was rather than lumping a non-answer together with a real one.
unpublished_caution <- function(unpublished, has_themes) {
  if (!has_themes || nrow(unpublished) == 0) return(NULL)
  # The theme's own label, quoted rather than reworded into a clause: the
  # non-answers and `ask`'s statements are held back for different reasons,
  # and one sentence covering both would have to overstate one of them.
  parts <- paste0(format(unpublished$n, big.mark = ","), " coded “",
                  unpublished$theme, "”")
  paste0(
    "Read and coded, but not shown below: ",
    paste(parts, collapse = ", and "),
    ". The chart and the table cover the remaining ",
    format(unpublished$total[1], big.mark = ","), "."
  )
}

# The count of what was withheld is stated beside every item, the same rule the
# identifier screen follows: a response the reader will never know existed
# unless the number is there. `why` names what the withholding was for, in two
# forms - `one` and `many` - because the clause has to agree with the count and
# "a group of people" is not "groups of people". It belongs to the caller
# because the two surveys withheld for different reasons: content aimed at
# groups of people on the public side, an identifying detail on the expert
# side.
review_caution <- function(reviewed, n_held, reviewed_on, why) {
  stopifnot(all(c("one", "many") %in% names(why)))
  paste0(
    "Every one of these ", format(reviewed, big.mark = ","), " responses was ",
    "read before publication, on ", format(reviewed_on, "%d %B %Y"), ". ",
    if (n_held == 0) {
      "None was withheld."
    } else if (n_held == 1) {
      paste0("One was withheld, ", why[["one"]], ".")
    } else {
      paste0(n_held, " were withheld, ", why[["many"]], ".")
    }
  )
}

# `published` marks a coded theme that the page does not draw. Declared in the
# label sheet rather than filtered in code, because whether a response answered
# the question is a judgement someone may want to overturn and they can only
# overturn what they can see. Checked on load: a sheet without the column would
# silently draw everything.
check_published_column <- function(roster, path) {
  if (!"published" %in% names(roster)) {
    stop(basename(path), " has no `published` column. Every theme must say ",
         "whether the page draws it.")
  }
  bad <- roster |> dplyr::filter(!published %in% c("yes", "no"))
  if (nrow(bad) > 0) {
    print(bad)
    stop("`published` must be yes or no for every theme in ", basename(path))
  }
  invisible(roster)
}
