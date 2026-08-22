# Export one open-ended item's responses for reading and coding.
#
# Usage:
#   Rscript export_for_coding.R <item> <out.txt>
#
# <item> is a row id from verbatim_items in 03_create_open_response_data.R
# (oppose, support, uncertain, ask). Writes one response per line, tab
# separated: index, case_id, year, text.
#
# The index is for referring to a response while reading. The case_id is the
# key the coding file uses, because an index moves when the data does.

suppressMessages(library(tidyverse))
source(here::here("00_paths.R"))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) stop("Usage: export_for_coding.R <item> <out.txt>")
item <- args[1]
destination <- args[2]

# The column each wave holds the item in, read off the variable reference the
# same way 03 does - names differ between waves.
reference <- read_csv(variable_reference, guess_max = Inf, show_col_types = FALSE)
variables <- c(oppose = "fusion_oppose_why", support = "fusion_support_why",
               uncertain = "fusion_uncertain_why", ask = "fusion_question")
if (!item %in% names(variables)) {
  print(names(variables))
  stop("Unknown item. Use one of the above.")
}
row <- reference |> filter(variable == variables[[item]])

out <- pmap(list(waves$data, waves$year, waves$column),
            function(path, year, field) {
  col <- row[[field]]
  if (is.na(col)) return(NULL)
  d <- read_csv(path, col_types = cols(.default = col_character()),
                na = c("", "NA"))
  tibble(case_id = d$case_id, year = year, text = str_squish(d[[col]]))
}) |>
  bind_rows() |>
  filter(!is.na(text), text != "")

out |>
  mutate(i = row_number()) |>
  transmute(line = paste(i, case_id, year, text, sep = "\t")) |>
  pull(line) |>
  writeLines(destination)

message(nrow(out), " responses written to ", destination)
message("  median ", median(nchar(out$text)), " characters, longest ",
        max(nchar(out$text)))
