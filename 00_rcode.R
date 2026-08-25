# Generated R -------------------------------------------------------------------
# Every chart on this site carries a script that rebuilds it from the released
# CSVs and nothing else. Two scripts generate them - 02 for the public survey,
# 04 for the expert survey - and this file holds what they must do identically:
# the formatting of literals, and the check that a generated script actually
# reproduces the numbers being published beside it.
#
# The generators themselves are not shared. The two surveys are estimated
# differently enough - waves, arms and weights against one unweighted fielding
# - that one function covering both would be harder to read than two.
#
# Sourced after 00_paths.R.

r_quote <- function(x) paste0('"', gsub('([\\\\"])', '\\\\\\1', x), '"')

# c("a", "b", ...) wrapped to fit. Breaks between elements only: strwrap()
# breaks at any whitespace, which puts a newline inside a response label and
# quietly changes the string. The verification below caught that, and it is the
# reason this lives in one place rather than in each generator.
r_vec <- function(x, indent) {
  pad <- strrep(" ", indent)
  parts <- paste0(r_quote(x), c(rep(",", length(x) - 1), ""))
  lines <- character(0)
  cur <- ""
  for (piece in parts) {
    if (!nzchar(cur)) {
      cur <- piece
    } else if (indent + nchar(cur) + 1 + nchar(piece) > 78) {
      lines <- c(lines, cur)
      cur <- piece
    } else {
      cur <- paste(cur, piece)
    }
  }
  paste0("c(", paste(c(lines, cur), collapse = paste0("\n", pad)), ")")
}

# A question stem runs to 539 characters in this survey. One string literal
# that long is a line nobody can read, so it is broken into fragments.
r_title <- function(title) {
  if (nchar(title) <= 60) return(r_quote(title))
  parts <- strwrap(title, 60)
  paste0("paste(\n      ",
         paste(r_quote(parts), collapse = ",\n      "), "\n    )")
}

# Does the generated script actually rebuild the chart? Checked, not asserted.
# Each script is run against the same CSVs a reader would download and its
# estimates compared with the ones written to the question file. Publishing
# code that does not reproduce the plot would be worse than publishing none,
# and a generator is exactly the kind of thing that goes subtly wrong.
#
# read_csv is shimmed to a cache in the evaluation environment, so a build does
# not read the same file a thousand times. Same arguments, same result.
r_code_cache <- new.env(parent = emptyenv())
cached_read_csv <- function(file, ...) {
  key <- file.path(data_dir, file)
  if (is.null(r_code_cache[[key]])) {
    r_code_cache[[key]] <- readr::read_csv(key, ...)
  }
  r_code_cache[[key]]
}

# Counters, in an environment rather than as globals so the two generators can
# each keep their own tally without either reaching into the other's.
new_rcode_tally <- function() {
  e <- new.env(parent = emptyenv())
  e$checks <- 0L
  e$scripts <- 0L
  e
}

# `expect` is the rows being written to the question file: group, resp (the
# response *code*), p. `options` maps value -> label.
verify_r_code <- function(script, expect, options, label, tally) {
  e <- new.env(parent = globalenv())
  assign("read_csv", cached_read_csv, envir = e)
  ok <- try(suppressWarnings(suppressMessages(
    eval(parse(text = script), envir = e))), silent = TRUE)
  if (inherits(ok, "try-error")) {
    cat(script)
    stop("The generated R for ", label, " does not run: ",
         conditionMessage(attr(ok, "condition")))
  }

  # The script labels its responses, so the published codes are labelled to
  # match rather than the other way round: comparing on the codes would not
  # notice a levels/labels pairing that had drifted.
  got <- get("est", envir = e) |> dplyr::as_tibble()
  gcol <- setdiff(names(got), c("resp", "p", "p_low", "p_upp", "p_se"))
  got <- got |>
    dplyr::transmute(
      group = if (length(gcol) == 1) as.character(.data[[gcol]]) else "All",
      resp = as.character(resp), gen = round(p, 2))
  want <- expect |>
    dplyr::left_join(options, by = c("resp" = "value")) |>
    dplyr::transmute(group = as.character(group), resp = label,
                     pub = round(p, 2))

  cmp <- dplyr::full_join(want, got, by = c("group", "resp"))
  if (any(is.na(cmp$pub)) || any(is.na(cmp$gen)) ||
      max(abs(cmp$pub - cmp$gen)) > 0.011) {
    print(cmp |> dplyr::filter(is.na(pub) | is.na(gen) |
                               abs(pub - gen) > 0.011))
    stop("The generated R for ", label, " does not reproduce its chart.")
  }
  tally$checks <- tally$checks + 1L
}
