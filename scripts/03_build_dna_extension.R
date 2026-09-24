### 03_build_dna_extension.R
#
# CLI wrapper around build_dna_extension() (R/build_dna_extension.R).
# Builds one Darwin Core DNA Derived Data extension table per assay,
# CONCEPTUALLY linked to script 02's Occurrence tables via occurrenceID
# (a real column carried through for cross-referencing) - but
# STRUCTURALLY, in the actual Darwin Core Archive uploaded to the IPT,
# this extension must be attached to and joined against the Event
# core, via eventID, same as the Occurrence extension. DwC-A has no
# concept of "extension of an extension" - every extension's IPT "core
# id" mapping has to be the core's own id (eventID here), never another
# extension's id (occurrenceID would never match anything and the
# whole extension would silently fail to join). Hence both eventID
# AND occurrenceID are kept as columns in the output.
#
# Sources (see build_dna_extension() for the actual code):
#   - taxaFinal$dna_sequence        -> DNA_sequence (the single most
#                                       important field in this extension)
#   - projectMetadata (long format: term_name x assay1..assay4)
#                                    -> per-assay PCR/primer/bioinformatics
#                                       metadata, constant across all rows
#                                       of that assay
#   - sampleMetadata -> env_broad_scale / env_local_scale / env_medium,
#                   joined back in via eventID
#   associatedSequences and the read count (sampleSizeValue) are NOT in this
#   extension - neither is a DNA Derived Data term. They live in the
#   Occurrence extension, where they are proper Darwin Core terms.
#
# NOTE: see config.R's ASSAY_PROJECT_COLUMN for the MiFishUE2
# multi-assay-column mapping (confirmed project-specific decision -
# MiFish-U + MiFish-E2 combined into one assay for this project_id).
#
# Reads script 02's Occurrence_<assay>.csv output (rather than
# re-deriving the ASV-by-sample long format from otuFinal itself) so
# the DNA Derived Data extension can never drift out of sync with the
# Occurrence extension it's linked to - both always describe exactly
# the same set of detections.

library(readxl)
library(dplyr)
library(readr)

source("R/faire_io.R")
source("R/build_dna_extension.R")

occurrence_files <- list.files(OCCURRENCE_OUTPUT_DIR, pattern = "^Occurrence_.*\\.csv$", full.names = TRUE)
if (length(occurrence_files) == 0) {
  stop("No Occurrence_*.csv files found in ", OCCURRENCE_OUTPUT_DIR, " - run 02_build_occurrence.R first.")
}
occurrence_tables <- lapply(occurrence_files, read_csv, show_col_types = FALSE)
names(occurrence_tables) <- sub("^Occurrence_(.*)\\.csv$", "\\1", basename(occurrence_files))

result <- build_dna_extension(
  input_files              = INPUT_FILES,
  occurrence_tables        = occurrence_tables,
  assay_project_column     = ASSAY_PROJECT_COLUMN
)

cat(paste(result$messages, collapse = "\n"), "\n")

dir.create(DNA_EXTENSION_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

for (assay in names(result$dna_extension)) {
  out_path <- file.path(DNA_EXTENSION_OUTPUT_DIR, paste0("DNADerivedData_", assay, ".csv"))
  write_csv(result$dna_extension[[assay]], out_path, na = "")
  cat("Written:", out_path, "(", nrow(result$dna_extension[[assay]]), "rows )\n")
}
