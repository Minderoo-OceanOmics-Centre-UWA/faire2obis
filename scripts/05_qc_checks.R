### 05_qc_checks.R
#
# CLI wrapper around run_qc_checks() (R/qc_checks.R). Runs obistools
# checks against the built archive before IPT upload. This is the last
# step - if anything here fails, fix it and re-run the relevant earlier
# script rather than hand-editing the CSVs.
#
# See R/qc_checks.R for the full rationale behind each check, including
# two confirmed obistools quirks/bugs worked around there:
#   - check_fields()'s `level` argument does not select an Event-vs-
#     Occurrence required-field set (no such concept exists in that
#     function) - worked around via flatten_occurrence().
#   - check_depth() crashes on a clean pass due to a row=NA logical/
#     integer type mismatch in its own result-building - wrapped in
#     tryCatch and reported as "SKIPPED - not verified" rather than
#     silently treated as a pass.

library(readr)
library(dplyr)
library(obistools)

source("R/qc_checks.R")

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

# ----------------------------------------------------------------------
# Run checks
# ----------------------------------------------------------------------
qc <- run_qc_checks(event, occurrence_tables, dna_tables)

for (m in qc$messages) cat(m, "\n")

for (n in names(occurrence_tables)) {
  cat("\n== check_fields (Occurrence + Event core, via flatten_occurrence):", n, "==\n")
  print(qc$results[[paste0("check_fields_", n)]])
}

cat("\n== check_eventids: Event core ==\n")
print(qc$results$check_eventids)

cat("\n== check_eventdate: Event core ==\n")
print(qc$results$check_eventdate)

cat("\n== check_depth: Event core ==\n")
if (!is.null(qc$results$check_depth)) print(qc$results$check_depth) else cat("  (skipped - see message above)\n")

cat("\n== check_onland: Event core ==\n")
print(qc$results$check_onland)
if (nrow(qc$results$check_onland) > 0) {
  cat("REVIEW: these events have coordinates that fall on land - check for lat/lon swaps or sign errors.\n")
}

if (nrow(qc$results$coord_out_of_range) > 0) {
  cat("\nREVIEW:", nrow(qc$results$coord_out_of_range),
      "events have missing/out-of-range/zero coordinates - these WILL be dropped by OBIS.\n")
  print(qc$results$coord_out_of_range %>% select(eventID, decimalLatitude, decimalLongitude))
}

for (n in names(occurrence_tables)) {
  cat("\n== check_extension_eventids (Occurrence):", n, "==\n")
  print(qc$results[[paste0("check_extension_eventids_occurrence_", n)]])
}

for (n in names(dna_tables)) {
  cat("\n== check_extension_eventids (DNA Derived Data):", n, "==\n")
  print(qc$results[[paste0("check_extension_eventids_dna_", n)]])
}

for (assay in names(qc$results$occ_dna_crosscheck)) {
  x <- qc$results$occ_dna_crosscheck[[assay]]
  cat("\n== occurrenceID cross-check:", assay, "==\n")
  cat("  Occurrence rows:", x$occurrence_rows, " | DNA extension rows:", x$dna_rows, "\n")
  cat("  In Occurrence but missing from DNA extension:", length(x$missing_in_dna), "\n")
  cat("  In DNA extension but missing from Occurrence:", length(x$missing_in_occ), "\n")
}

for (n in names(qc$results$scientificname_coverage)) {
  x <- qc$results$scientificname_coverage[[n]]
  cat("\n== scientificNameID coverage:", n, "==\n")
  cat("  ", x$total - x$missing, "/", x$total,
      "rows have scientificNameID. ", x$missing, "rows missing - ",
      "these will get 'no_match' flagged and DROPPED unless resolved",
      "(see output/worms_match/ambiguous_names.csv and unmatched_names.csv).\n")
}

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
cat("\n=========================================\n")
if (qc$any_failures) {
  cat("QC CHECKS FOUND ISSUES - review the output above before publishing.\n")
} else {
  cat("All RUNNABLE checks passed. Still: manually spot-check a sample of rows",
      "before uploading to the IPT - a clean automated check is not a",
      "substitute for eyeballing real data.\n")
}
if (length(qc$any_skipped) > 0) {
  cat("\nSKIPPED (not run, not verified either way):\n")
  for (s in qc$any_skipped) cat("  -", s, "\n")
}
cat("=========================================\n")
