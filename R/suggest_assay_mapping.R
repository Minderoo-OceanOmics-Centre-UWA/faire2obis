### R/suggest_assay_mapping.R
#
# Suggests which projectMetadata assayN column(s) match a given assay
# name, for the Shiny app's Step 3 mapping UI. A SUGGESTION only - the
# app pre-selects these but always shows the underlying evidence
# (target_gene/primer names) and lets the user override, rather than
# silently applying a guess. Works because eDNA projects almost always
# name assays after their primer set (e.g. assay "MarVer1" <-> primers
# "MarVer1F"/"MarVer1R"), so string similarity against the primer names
# is a strong, explainable signal here - not a generic ML guess.

#' Normalized similarity between two strings (0 = nothing alike, 1 = identical),
#' based on Levenshtein edit distance over the alphanumeric characters only.
string_similarity <- function(a, b) {
  a <- toupper(gsub("[^A-Za-z0-9]", "", a))
  b <- toupper(gsub("[^A-Za-z0-9]", "", b))
  if (nchar(a) == 0 || nchar(b) == 0) return(0)
  d <- utils::adist(a, b)[1, 1]
  1 - d / max(nchar(a), nchar(b))
}

#' Suggest which assayN column(s) in projectMetadata correspond to a given
#' assay name, by comparing it against each column's target_gene and
#' primer names.
#'
#' @param assay_name The uploaded assay's name (e.g. "MarVer1")
#' @param project_meta The projectMetadata tibble (term_name, project_level, assay1..assayN)
#' @param threshold Minimum similarity to count as a suggested match (0-1)
#' @return character vector of suggested assayN column names (possibly length 0)
suggest_assay_columns <- function(assay_name, project_meta, threshold = 0.45) {
  assay_cols <- grep("^assay[0-9]+$", names(project_meta), value = TRUE)
  fields <- c("target_gene", "pcr_primer_name_forward", "pcr_primer_name_reverse")

  scores <- sapply(assay_cols, function(col) {
    vals <- sapply(fields, function(f) {
      row <- project_meta[project_meta$term_name == f, ]
      if (nrow(row) == 0) return(NA_character_)
      v <- row[[col]][1]
      if (is.na(v) || v == "") NA_character_ else as.character(v)
    })
    vals <- vals[!is.na(vals)]
    if (length(vals) == 0) return(0)
    max(vapply(vals, function(v) string_similarity(assay_name, v), numeric(1)))
  })

  names(scores)[scores >= threshold]
}
