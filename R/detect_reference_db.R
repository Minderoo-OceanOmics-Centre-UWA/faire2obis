### R/detect_reference_db.R
#
# A publication is built from either "curated database" FAIRe files or
# "NCBI nt" FAIRe files - never a mix of the two, since the taxonomic
# assignments in the two kinds of file come from different reference
# databases. OceanOmics FAIRe filenames embed the type
# (e.g. "OcOm_2408_16SFishD_asv_curateddb_final_faire_metadata.xlsx" vs
# "OcOm_2408_16SFishD_asv_nt_final_faire_metadata.xlsx").

REFERENCE_DB_CHOICES <- c("Curated database" = "curated", "NCBI nt database" = "nt")

#' @param filename The uploaded file's ORIGINAL name (not its temp path)
#' @return "curated", "nt", or NA_character_ if the name doesn't clearly
#'   say (or says both) - never guessed.
detect_reference_db_from_filename <- function(filename) {
  if (is.null(filename) || is.na(filename) || !nzchar(filename)) return(NA_character_)

  tokens <- strsplit(tolower(sub("\\.[A-Za-z0-9]+$", "", filename)), "[^a-z0-9]+")[[1]]
  is_curated <- any(tokens %in% c("curateddb", "curated"))
  is_nt <- "nt" %in% tokens

  if (is_curated == is_nt) return(NA_character_)
  if (is_curated) "curated" else "nt"
}
