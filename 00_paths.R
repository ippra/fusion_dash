# Paths ------------------------------------------------------------------------
# Every script sources this so data locations are defined once. Unlike the
# wxdash pipeline, this project is self-contained: the two weighted survey
# files and their instruments are small enough to live in the repo, so paths
# resolve against the project root rather than a machine-specific root in
# ~/.Renviron. Nothing here needs configuring on a new machine.

project_root <- here::here()

data_dir <- file.path(project_root, "data")
reference_dir <- file.path(project_root, "01_variable_reference")
site_src <- file.path(project_root, "site")
outputs <- file.path(project_root, "outputs")

variable_reference <- file.path(reference_dir, "variable_reference.csv")
arms_reference <- file.path(reference_dir, "arms.csv")
word_stoplist <- file.path(reference_dir, "word_stoplist.csv")

# The waves the dashboard covers. Adding one is a row here plus a column_fu27
# in the variable reference; every script iterates this table rather than
# naming files. `column` is the reference column holding that wave's data
# column names, which is what absorbs FU25 having been released under names its
# own instrument no longer uses.
waves <- tibble::tribble(
  ~year, ~wave,  ~data,               ~column,
  2025L, "FU25", "FU25_data_wtd.csv", "column_fu25",
  2026L, "FU26", "FU26_data_wtd.csv", "column_fu26"
) |>
  dplyr::mutate(data = file.path(data_dir, data))

# The weight variable is the same name in both waves. Named once here because
# an unweighted percentage looks entirely reasonable and is wrong.
weight_var <- "weight"

absent <- c(variable_reference, arms_reference, word_stoplist, waves$data)
absent <- absent[!file.exists(absent)]

if (length(absent) > 0) {
  print(absent)
  stop("Input files above are missing.")
}

dir.create(outputs, showWarnings = FALSE)
