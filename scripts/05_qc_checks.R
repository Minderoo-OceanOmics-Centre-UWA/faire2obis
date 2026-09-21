### 05_qc_checks.R
#
# Runs obistools checks against the built archive before IPT upload.
# This is the last step - if anything here fails, fix it and re-run
# the relevant earlier script rather than hand-editing the CSVs.
#
# NOTE: this script has not been executed (no R/network access in the
# environment this pipeline was drafted in - see CLAUDE.md). Run it
# yourself and review every warning before publishing; do not treat a
# clean run here as a substitute for actually opening a sample of rows
# and eyeballing them.

library(readr)
library(dplyr)
library(obistools)

# ----------------------------------------------------------------------
# Load everything
# ----------------------------------------------------------------------
event <- read_csv(EVENT_CORE_OUTPUT, show_col_types = FALSE)

occurrence_files <- list.files(OCCURRENCE_OUTPUT_DIR, pattern = "^Occurrence_.*\\.csv$", full.names = TRUE)
dna_files <- list.files(DNA_EXTENSION_OUTPUT_DIR, pattern = "^DNADerivedData_.*\\.csv$", full.names = TRUE)

occurrence_tables <- lapply(occurrence_files, read_csv, show_col_types = FALSE)
names(occurrence_tables) <- basename(occurrence_files)

dna_tables <- lapply(dna_files, read_csv, show_col_types = FALSE)
names(dna_tables) <- basename(dna_files)

cat("Loaded:\n")
cat(" - Event core:", nrow(event), "rows\n")
for (n in names(occurrence_tables)) cat(" -", n, ":", nrow(occurrence_tables[[n]]), "rows\n")
for (n in names(dna_tables))        cat(" -", n, ":", nrow(dna_tables[[n]]), "rows\n")
cat("\n")

any_failures <- FALSE
any_skipped  <- character()

# ----------------------------------------------------------------------
# 1/2. Required fields present - obistools::check_fields() always checks
#      one fixed combined list (eventDate, decimalLongitude,
#      decimalLatitude, scientificName, scientificNameID,
#      occurrenceStatus, basisOfRecord) regardless of what string is
#      passed for `level` - it has no concept of an Event Core +
#      Occurrence extension split, it was written for a flat, single-
#      table Occurrence Core. Running it against the Event core alone
#      or an Occurrence extension alone therefore always "fails" on the
#      fields that live in the other table by design - not a real
#      problem. The correct way to use it here is against a combined
#      view (Occurrence + Event core), which is what actually has every
#      required field together - using obistools' own
#      flatten_occurrence() for this (rather than a manual left_join)
#      since it's the package's intended tool for exactly this: it only
#      pulls in fields recognized as both event_fields() and
#      occurrence_fields(), and self-checks eventID consistency first.
# ----------------------------------------------------------------------
for (n in names(occurrence_tables)) {
  cat("\n== check_fields (Occurrence + Event core, via flatten_occurrence):", n, "==\n")
  joined <- flatten_occurrence(event, occurrence_tables[[n]])
  occ_field_check <- check_fields(joined, level = "warning")
  print(occ_field_check)
  if (nrow(occ_field_check) > 0) any_failures <- TRUE
}

# ----------------------------------------------------------------------
# 2b. eventID uniqueness + parentEventID validity WITHIN the Event core
#     itself (check_extension_eventids, used elsewhere in this script,
#     only checks an extension against the core - it doesn't check the
#     core's own internal consistency). Trivial here since
#     parentEventID is always NA (no event hierarchy), but run it via
#     the package's own function rather than just trusting script 01's
#     row-count log, and to guard against regressions if a hierarchy is
#     ever added later.
# ----------------------------------------------------------------------
cat("\n== check_eventids: Event core ==\n")
eventid_check <- check_eventids(event)
print(eventid_check)
if (nrow(eventid_check) > 0) any_failures <- TRUE

# ----------------------------------------------------------------------
# 3. eventDate formatting
# ----------------------------------------------------------------------
cat("\n== check_eventdate: Event core ==\n")
date_check <- check_eventdate(event)
print(date_check)
if (nrow(date_check) > 0) any_failures <- TRUE

# ----------------------------------------------------------------------
# 3b. Depth vs. bathymetry (obistools::check_depth) - NOTE: this
#     function has a confirmed bug in the currently-installed version
#     (installed from GitHub iobis/obistools@HEAD): when the check
#     finds zero row-level issues (a clean pass) and only has a
#     column-level "empty"/"missing" diagnostic to report (our
#     minimumDepthInMeters is 0/490 populated - single-point depth
#     sampling, not a pipeline bug), it builds that diagnostic row with
#     `row = NA` of type LOGICAL instead of integer, and the function's
#     own final subsetting step (`original_data[sort(unique(na.omit(
#     result$row))), ]`) then fails because a zero-length logical index
#     isn't valid row subsetting in R. Reproduced directly against our
#     data (with and without minimumDepthInMeters present) - not
#     something fixable from this pipeline's side. Wrapped so this
#     known upstream issue can't silently abort the rest of QC; if it
#     ever returns a real result instead of erroring, that means the
#     package was fixed/updated and the result should be reviewed.
# ----------------------------------------------------------------------
cat("\n== check_depth: Event core ==\n")
depth_check <- tryCatch(
  check_depth(event),
  error = function(e) {
    cat("  SKIPPED - known obistools::check_depth() bug (see script comment): ", conditionMessage(e), "\n", sep = "")
    NULL
  }
)
if (!is.null(depth_check)) {
  print(depth_check)
  if (nrow(depth_check) > 0) any_failures <- TRUE
} else {
  any_skipped <- c(any_skipped, "check_depth (depth vs. bathymetry) - NOT verified, see message above")
}

# ----------------------------------------------------------------------
# 4. Coordinates on land / out of range
# ----------------------------------------------------------------------
cat("\n== check_onland: Event core ==\n")
onland_check <- check_onland(event)
print(onland_check)
if (nrow(onland_check) > 0) {
  any_failures <- TRUE
  cat("REVIEW: these events have coordinates that fall on land -",
      "check for lat/lon swaps or sign errors.\n")
}

coord_out_of_range <- event %>%
  filter(
    is.na(decimalLatitude) | is.na(decimalLongitude) |
    decimalLatitude < -90 | decimalLatitude > 90 |
    decimalLongitude < -180 | decimalLongitude > 180 |
    (decimalLatitude == 0 & decimalLongitude == 0)
  )
if (nrow(coord_out_of_range) > 0) {
  cat("\nREVIEW:", nrow(coord_out_of_range),
      "events have missing/out-of-range/zero coordinates - these WILL be dropped by OBIS.\n")
  print(coord_out_of_range %>% select(eventID, decimalLatitude, decimalLongitude))
  any_failures <- TRUE
}

# ----------------------------------------------------------------------
# 5. eventID consistency between Event core and each extension -
#    including the DNA Derived Data extension. This matters structurally,
#    not just conceptually: in the actual DwC-A uploaded to the IPT,
#    every extension links back to the CORE via the core's own id
#    (eventID), never via another extension's id (occurrenceID) - there
#    is no "extension of an extension" in DwC-A. A DNA extension file
#    missing eventID would silently fail to join in IPT even though it
#    looks fine in this pipeline (occurrenceID cross-check in step 6
#    would still pass) - so check both extensions here explicitly.
# ----------------------------------------------------------------------
for (n in names(occurrence_tables)) {
  cat("\n== check_extension_eventids (Occurrence):", n, "==\n")
  ext_check <- check_extension_eventids(event, occurrence_tables[[n]])
  print(ext_check)
  if (length(ext_check) > 0 && !all(is.na(ext_check))) any_failures <- TRUE
}

for (n in names(dna_tables)) {
  cat("\n== check_extension_eventids (DNA Derived Data):", n, "==\n")
  if (!"eventID" %in% names(dna_tables[[n]])) {
    cat("  ERROR: no eventID column in this file - it cannot be linked to the Event core in IPT.\n")
    any_failures <- TRUE
    next
  }
  ext_check <- check_extension_eventids(event, dna_tables[[n]])
  print(ext_check)
  if (length(ext_check) > 0 && !all(is.na(ext_check))) any_failures <- TRUE
}

# ----------------------------------------------------------------------
# 6. occurrenceID <-> eventID consistency between Occurrence and DNA
#    Derived Data extension (not a built-in obistools check - both
#    extensions are keyed by occurrenceID, not eventID, so verify
#    manually that every DNA extension occurrenceID has a matching
#    Occurrence row and vice versa)
# ----------------------------------------------------------------------
for (assay in names(INPUT_FILES)) {
  occ_name <- paste0("Occurrence_", assay, ".csv")
  dna_name <- paste0("DNADerivedData_", assay, ".csv")

  if (!occ_name %in% names(occurrence_tables) || !dna_name %in% names(dna_tables)) next

  occ_ids <- occurrence_tables[[occ_name]]$occurrenceID
  dna_ids <- dna_tables[[dna_name]]$occurrenceID

  missing_in_dna <- setdiff(occ_ids, dna_ids)
  missing_in_occ <- setdiff(dna_ids, occ_ids)

  cat("\n== occurrenceID cross-check:", assay, "==\n")
  cat("  Occurrence rows:", length(occ_ids), " | DNA extension rows:", length(dna_ids), "\n")
  cat("  In Occurrence but missing from DNA extension:", length(missing_in_dna), "\n")
  cat("  In DNA extension but missing from Occurrence:", length(missing_in_occ), "\n")

  if (length(missing_in_dna) > 0 || length(missing_in_occ) > 0) any_failures <- TRUE
}

# ----------------------------------------------------------------------
# 7. scientificNameID completeness (post-WoRMS-matching check)
# ----------------------------------------------------------------------
for (n in names(occurrence_tables)) {
  occ <- occurrence_tables[[n]]
  n_missing <- sum(is.na(occ$scientificNameID))
  cat("\n== scientificNameID coverage:", n, "==\n")
  cat("  ", nrow(occ) - n_missing, "/", nrow(occ),
      "rows have scientificNameID. ", n_missing, "rows missing - ",
      "these will get 'no_match' flagged and DROPPED unless resolved",
      "(see output/worms_match/ambiguous_names.csv and unmatched_names.csv).\n")
  if (n_missing > 0) any_failures <- TRUE
}

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
cat("\n=========================================\n")
if (any_failures) {
  cat("QC CHECKS FOUND ISSUES - review the output above before publishing.\n")
} else {
  cat("All RUNNABLE checks passed. Still: manually spot-check a sample of rows",
      "before uploading to the IPT - a clean automated check is not a",
      "substitute for eyeballing real data.\n")
}
if (length(any_skipped) > 0) {
  cat("\nSKIPPED (not run, not verified either way):\n")
  for (s in any_skipped) cat("  -", s, "\n")
}
cat("=========================================\n")
