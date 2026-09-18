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
# Mapping: which projectMetadata assay column(s) apply to each of our
# FAIRe files' assay_name.
#
# projectMetadata has 4 assay columns (assay1-assay4), one per primer
# set used in this project:
#   assay1 = MiFish-U   (target_gene 12S rRNA, primers MiFish-U-F/R)
#   assay2 = 16S/D       (target_gene 16S rRNA, primers 16SF/D)     -> matches "16SFishD" file
#   assay3 = MiFish-E2  (target_gene 12S rRNA, primers MiFish-E2-F/R)
#   assay4 = MarVer1    (primers MarVer1F/R)                        -> matches "MarVer1" file
#
# CONFIRMED (project-specific decision, not inferred): in this
# project, MiFish-U and MiFish-E2 are run and treated as ONE combined
# assay, "MiFishUE2" - that's why this project has only 3 data files
# instead of 4. Other OceanOmics projects may treat MiFish-U and
# MiFish-E2 as two separate assays instead - if you reuse this
# pipeline for a different project_id, check this mapping again rather
# than assuming it still applies.
ASSAY_PROJECT_COLUMN <- list(
  "16SFishD"  = "assay2",
  "MarVer1"   = "assay4",
  "MiFishUE2" = c("assay1", "assay3")   # confirmed: MiFish-U + MiFish-E2 combined in this project
)

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
