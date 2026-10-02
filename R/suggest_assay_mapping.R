### R/suggest_assay_mapping.R
#
# Suggests which projectMetadata assayN column(s) match a given assay
# name, for the Shiny app's Step 3 mapping UI. A SUGGESTION only - the
# app pre-selects these but always shows the underlying evidence
# (assay_name/target_gene/primer names) and lets the user override,
# rather than silently applying a guess.
#
# Matching, strongest signal first:
#   1. projectMetadata's own `assay_name` row equals the uploaded assay
#      name (ignoring case/punctuation, e.g. "MiFish-U" == "MiFishU")
#      -> that column only.
#   2. Combined assay: the uploaded name is built from several columns'
#      assay_names (e.g. "MiFishUE2" from "MiFish-U" + "MiFishE2") -
#      every column whose assay_name is a subsequence of the uploaded
#      name, when at least 2 columns qualify and no exact match exists.
#      Overlaps with other files are allowed - a project can genuinely
#      have separate MiFishU and MiFishE2 files as well as MiFishUE2.
#   3. Fallback: string similarity against assay_name/target_gene/primer
#      names, keeping only the best-scoring column(s) above a threshold
#      (not every column that clears it - MiFishU vs MiFish-E2-F would
#      otherwise also "match").

#' Uppercase alphanumerics only, so "MiFish-U" and "MIFISHU" compare equal.
normalize_assay_string <- function(x) toupper(gsub("[^A-Za-z0-9]", "", x))

#' Normalized similarity between two strings (0 = nothing alike, 1 = identical),
#' based on Levenshtein edit distance over the alphanumeric characters only.
string_similarity <- function(a, b) {
  a <- normalize_assay_string(a)
  b <- normalize_assay_string(b)
  if (nchar(a) == 0 || nchar(b) == 0) return(0)
  d <- utils::adist(a, b)[1, 1]
  1 - d / max(nchar(a), nchar(b))
}

#' TRUE if every character of `needle` appears in `haystack` in order.
is_subsequence <- function(needle, haystack) {
  n <- strsplit(needle, "")[[1]]
  h <- strsplit(haystack, "")[[1]]
  i <- 1
  for (ch in h) {
    if (i <= length(n) && ch == n[i]) i <- i + 1
  }
  i > length(n)
}

#' One projectMetadata term's value for one assayN column (NA if blank/missing).
project_meta_value <- function(project_meta, term, col) {
  row <- project_meta[project_meta$term_name == term, ]
  if (nrow(row) == 0) return(NA_character_)
  v <- row[[col]][1]
  if (is.na(v) || v == "") NA_character_ else as.character(v)
}

#' Suggest which assayN column(s) in projectMetadata correspond to a given
#' assay name.
#'
#' @param assay_name The uploaded assay's name (e.g. "MarVer1")
#' @param project_meta The projectMetadata tibble (term_name, project_level, assay1..assayN)
#' @param threshold Minimum similarity for the fallback match (0-1)
#' @return character vector of suggested assayN column names (possibly length 0)
suggest_assay_columns <- function(assay_name, project_meta, threshold = 0.6) {
  assay_cols <- grep("^assay[0-9]+$", names(project_meta), value = TRUE)
  if (length(assay_cols) == 0) return(character())
  target <- normalize_assay_string(assay_name)

  # 1 + 2: projectMetadata's own assay_name row
  pm_names <- vapply(assay_cols, function(col) {
    v <- project_meta_value(project_meta, "assay_name", col)
    if (is.na(v)) "" else normalize_assay_string(v)
  }, character(1))

  exact <- assay_cols[pm_names != "" & pm_names == target]
  if (length(exact) > 0) return(exact)

  combined <- assay_cols[pm_names != "" & nchar(pm_names) >= 3 &
                           vapply(pm_names, is_subsequence, logical(1), haystack = target)]
  if (length(combined) >= 2) return(combined)

  # 3: similarity fallback - best column(s) only
  fields <- c("assay_name", "target_gene", "pcr_primer_name_forward", "pcr_primer_name_reverse")
  scores <- vapply(assay_cols, function(col) {
    vals <- vapply(fields, function(f) project_meta_value(project_meta, f, col), character(1))
    vals <- vals[!is.na(vals)]
    if (length(vals) == 0) return(0)
    max(vapply(vals, function(v) string_similarity(assay_name, v), numeric(1)))
  }, numeric(1))

  best <- max(scores)
  if (best < threshold) return(character())
  assay_cols[scores >= best - 1e-9]
}
