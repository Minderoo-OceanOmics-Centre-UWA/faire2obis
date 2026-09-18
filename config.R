### config.R
# Paths and settings for the FAIRe -> OBIS (Event core) conversion pipeline.

# --------------------------------------------------------------------
# Input files (one FAIRe workbook per assay, same project/samples)
# --------------------------------------------------------------------
INPUT_FILES <- list(
  "16SFishD"  = "data/OcOm_2408_16SFishD_asv_curateddb_final_faire_metadata.xlsx",
  "MarVer1"   = "data/OcOm_2408_MarVer1_asv_curateddb_final_faire_metadata.xlsx",
  "MiFishUE2" = "data/OcOm_2408_MiFishUE2_asv_curateddb_final_faire_metadata.xlsx"
)

# Which file's sampleMetadata to use as the source of truth for the
# Event core. (Script 01 will still cross-check the others against it
# and warn on any mismatch before writing output.)
EVENT_CORE_SOURCE_ASSAY <- "16SFishD"

PROJECT_ID <- "OcOm_2408"

# --------------------------------------------------------------------
# Output locations
# --------------------------------------------------------------------
OUTPUT_FOLDER            <- "output"
EVENT_CORE_OUTPUT        <- file.path(OUTPUT_FOLDER, "event_core", "Event.csv")
OCCURRENCE_OUTPUT_DIR    <- file.path(OUTPUT_FOLDER, "occurrence")
DNA_EXTENSION_OUTPUT_DIR <- file.path(OUTPUT_FOLDER, "dna_extension")
CONTROLS_OUTPUT_DIR      <- file.path(OUTPUT_FOLDER, "controls")

# --------------------------------------------------------------------
# Sample category handling
# --------------------------------------------------------------------
# Values of samp_category that count as real biological occurrences
# (everything else - negative control, positive control - is routed
# to CONTROLS_OUTPUT_DIR instead of the Occurrence extension).
SAMPLE_CATEGORY_KEEP <- "sample"
