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
# The expert survey is a different survey, not another wave, so it gets its own
# sheet rather than a third wave column. Its questions are different, its
# sample is purposive and unweighted, and 26 of its columns share a name with a
# public variable while only five ask the same question - one sheet would put
# those in the same row and invite exactly the comparison that is wrong.
sme_reference <- file.path(reference_dir, "sme_variable_reference.csv")
sme_data <- file.path(data_dir, "FU26_SME_data.csv")
# Which public measure stands for each factor the experts were asked to rank.
# Declared rather than matched, because half of them are the vendor's derived
# columns rather than reference variables and two carry caveats a name lookup
# could not.
sme_correlates <- file.path(reference_dir, "sme_correlates.csv")
arms_reference <- file.path(reference_dir, "arms.csv")
word_stoplist <- file.path(reference_dir, "word_stoplist.csv")
themes_reference <- file.path(reference_dir, "themes.csv")
theme_labels <- file.path(reference_dir, "theme_labels.csv")
verbatim_review <- file.path(reference_dir, "verbatim_review.csv")
verbatim_withheld <- file.path(reference_dir, "verbatim_withheld.csv")
# The expert survey's qualitative items keep their own coding and review files
# for the same reason the survey keeps its own sheet: it is a different survey,
# read and coded separately, and one file holding both would let a public item
# id and an expert one collide without either script noticing.
sme_themes <- file.path(reference_dir, "sme_themes.csv")
sme_theme_labels <- file.path(reference_dir, "sme_theme_labels.csv")
sme_verbatim_review <- file.path(reference_dir, "sme_verbatim_review.csv")
sme_verbatim_withheld <- file.path(reference_dir, "sme_verbatim_withheld.csv")

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

# Why-item routing --------------------------------------------------------------
# The three why-items are alternatives, and the two waves routed them by
# different rules. Both are deterministic and each reproduces its own wave
# exactly, but FU25 tests the oppose gate with `or` and FU26 with `and`:
#
#            FU25                              FU26
#   oppose   new_fusion <= 2 OR host <= 2      new_fusion <= 2 AND host <= 2
#   support  neither gate 3-5, one >= 6        new_fusion >= 6 AND host >= 6
#   unsure   everything else                   everything else
#
# So FU25 asked "why do you oppose" of anyone negative on *either* question,
# including people who back fusion plants and object only to the siting. That
# is 220 of its 297 oppose responses, and it is why the oppose corpus fell
# from 297 to 106 between waves - the gate changed, not the opinion.
#
# Decided 2026-08-22: publish the corpus FU26's rule defines, in both waves,
# so the two are one population and a theme count means the same thing in
# each. why_item_kept() is that rule. It is declared here because
# 03_create_open_response_data.R and the theme skill's export_for_coding.R
# both apply it, and a routing rule written twice will drift - the coding
# would then be checked against a corpus that is not the published one.
#
# Returns TRUE for a respondent who belongs in `item` under FU26's rule.
# Rows whose gate answers are missing are kept: they were routed somehow and
# this rule cannot say otherwise.
why_item_kept <- function(item, new_fusion, fusion_host) {
  nf <- suppressWarnings(as.integer(new_fusion))
  fh <- suppressWarnings(as.integer(fusion_host))
  routed <- dplyr::case_when(
    is.na(nf) | is.na(fh) ~ NA_character_,
    nf <= 2 & fh <= 2     ~ "oppose",
    nf >= 6 & fh >= 6     ~ "support",
    TRUE                  ~ "uncertain"
  )
  is.na(routed) | routed == item
}

absent <- c(variable_reference, sme_reference, sme_data, sme_correlates,
            arms_reference, word_stoplist, themes_reference, theme_labels,
            verbatim_review, verbatim_withheld, sme_themes, sme_theme_labels,
            sme_verbatim_review, sme_verbatim_withheld, waves$data)
absent <- absent[!file.exists(absent)]

if (length(absent) > 0) {
  print(absent)
  stop("Input files above are missing.")
}

dir.create(outputs, showWarnings = FALSE)
