### R/detect_assay_name.R
#
# Detects the assay name for a single uploaded FAIRe file, for the
# Shiny app's Step 1 - a suggestion the user can still edit or replace
# entirely, never a silently-applied guess.
#
# Reads experimentRunMetadata$assay_name, NOT sampleMetadata$assay_name
# - checked both against real project data before picking one:
# sampleMetadata$assay_name lists ALL assays in the project, identically,
# in every one of that project's files (not useful for identifying
# "this" file). experimentRunMetadata$assay_name is reliably a single,
# consistent value per file and matches the assay's real name exactly
# (verified: 16SFishD / MarVer1 / MiFishUE2 for the three real project
# files this pipeline was built against).

#' @param path Path to a single FAIRe .xlsx file
#' @return The detected assay name (length-1 character), or NA_character_
#'   if it can't be determined confidently (sheet/column missing, or
#'   more than one distinct value present - don't guess which one is right)
detect_assay_name <- function(path) {
  erm <- tryCatch(read_faire_sheet(path, "experimentRunMetadata"), error = function(e) NULL)
  if (is.null(erm) || !"assay_name" %in% names(erm)) return(NA_character_)

  vals <- unique(erm$assay_name)
  vals <- vals[!is.na(vals) & vals != ""]
  if (length(vals) != 1) return(NA_character_)

  vals[1]
}

# -----------------------------------------------------------------------
# Filename-based detection.
#
# OceanOmics assay names across different projects (not just this one's
# 16SFishD/MarVer1/MiFishUE2) are drawn from a known, fixed vocabulary,
# and every FAIRe filename observed so far embeds its assay name as-is
# (e.g. "OcOm_2408_16SFishD_asv_curateddb_final_faire_metadata.xlsx").
# Matching against that vocabulary is instant (no need to open/parse the
# workbook) and works even for projects whose sheet layout might differ,
# so this runs FIRST; detect_assay_name() (reading
# experimentRunMetadata$assay_name from inside the file) is the fallback
# for a filename that doesn't confidently match anything known.
#
# Matching is done on a normalized form (letters/digits only, lowercased)
# so case and separator differences ("MarVer1" vs "Marver1", "COILeray"
# vs "COI Leray") don't matter - except where the assay is written with
# its two halves in different ORDER ("Anth28S" vs "28S-Anth"), which
# normalization alone can't unify, so that pair is listed explicitly.
.ASSAY_NAME_VARIANTS <- list(
  "16SFishD"  = c("16SFishD"),
  "MarVer1"   = c("MarVer1"),
  "MiFishUE2" = c("MiFishUE2"),
  "MiFishE2"  = c("MiFishE2"),
  "MiFish-U"  = c("MiFish-U", "MiFishU"),
  "COILeray"  = c("COILeray"),
  "12SV5"     = c("12SV5"),
  "16SMammal" = c("16SMammal"),
  "Anth28S"   = c("Anth28S", "28S-Anth")
)

.normalize_assay_token <- function(x) tolower(gsub("[^A-Za-z0-9]", "", x))

# canonical name -> character vector of normalized variant strings, longest first
# (so a more specific token, e.g. "mifishue2", is tried before a shorter one
# it happens to contain, e.g. "mifishe2" is NOT contained in "mifishue2" here,
# but this ordering guards against that class of issue in general)
.ASSAY_NAME_LOOKUP <- (function() {
  entries <- list()
  for (canonical in names(.ASSAY_NAME_VARIANTS)) {
    for (variant in .ASSAY_NAME_VARIANTS[[canonical]]) {
      entries[[.normalize_assay_token(variant)]] <- canonical
    }
  }
  entries[order(-nchar(names(entries)))]
})()

#' Detect the assay name by matching known assay-name tokens against an
#' uploaded file's ORIGINAL filename (not its randomized upload temp path).
#'
#' @param filename The original filename, e.g. from Shiny's `input$file$name`
#' @return The canonical assay name (length-1 character), or NA_character_
#'   if no known assay name is unambiguously present. Never guesses between
#'   two different candidate names found in the same filename.
detect_assay_name_from_filename <- function(filename) {
  if (is.null(filename) || is.na(filename) || !nzchar(filename)) return(NA_character_)

  base <- .normalize_assay_token(sub("\\.[A-Za-z0-9]+$", "", filename))

  # A shorter token can be a substring of a longer one that also matches
  # (e.g. "mifishu" inside "mifishue2") without the two assays being the
  # same - so track match length and only keep the most specific (longest)
  # match(es); a tie between two DIFFERENT canonical names is genuinely
  # ambiguous and stays NA.
  hit_lengths <- integer()
  hit_names <- character()
  for (normalized_variant in names(.ASSAY_NAME_LOOKUP)) {
    if (grepl(normalized_variant, base, fixed = TRUE)) {
      hit_lengths <- c(hit_lengths, nchar(normalized_variant))
      hit_names <- c(hit_names, .ASSAY_NAME_LOOKUP[[normalized_variant]])
    }
  }
  if (length(hit_names) == 0) return(NA_character_)

  best <- unique(hit_names[hit_lengths == max(hit_lengths)])
  if (length(best) != 1) return(NA_character_)
  best[1]
}

#' Best-effort assay name detection for one uploaded FAIRe file: tries the
#' filename first (fast, works even if the sheet layout differs from this
#' project's), then falls back to reading experimentRunMetadata$assay_name
#' from inside the file. Still just a suggestion the user can edit -
#' never applied silently.
#'
#' @param path Path to the uploaded file on disk (its temp datapath)
#' @param filename The file's original name (e.g. `input$file$name`)
#' @return The detected assay name (length-1 character), or NA_character_
detect_assay_name_combined <- function(path, filename) {
  from_filename <- detect_assay_name_from_filename(filename)
  if (!is.na(from_filename)) return(from_filename)
  detect_assay_name(path)
}
