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

# ----------------------------------------------------------------------
# 1. Required fields present (Event core)
# ----------------------------------------------------------------------
cat("== check_fields: Event core ==\n")
event_field_check <- check_fields(event, level = "event")
print(event_field_check)
if (nrow(event_field_check) > 0) any_failures <- TRUE

# ----------------------------------------------------------------------
# 2. Required fields present (each Occurrence table)
# ----------------------------------------------------------------------
for (n in names(occurrence_tables)) {
  cat("\n== check_fields:", n, "==\n")
  occ_field_check <- check_fields(occurrence_tables[[n]], level = "occurrence")
  print(occ_field_check)
  if (nrow(occ_field_check) > 0) any_failures <- TRUE
}

# ----------------------------------------------------------------------
# 3. eventDate formatting
# ----------------------------------------------------------------------
cat("\n== check_eventdate: Event core ==\n")
date_check <- check_eventdate(event)
print(date_check)
if (nrow(date_check) > 0) any_failures <- TRUE

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
# 5. eventID consistency between Event core and each extension
# ----------------------------------------------------------------------
for (n in names(occurrence_tables)) {
  cat("\n== check_extension_eventids:", n, "==\n")
  ext_check <- check_extension_eventids(event, occurrence_tables[[n]])
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
  cat("All checks passed. Still: manually spot-check a sample of rows",
      "before uploading to the IPT - a clean automated check is not a",
      "substitute for eyeballing real data.\n")
}
cat("=========================================\n")
