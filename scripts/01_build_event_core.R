### 01_build_event_core.R
#
# Builds a single Darwin Core Event core table from the sampleMetadata
# sheet shared across this project's FAIRe assay files.
#
# Because all three assays sequence the *same physical samples*, the
# sampleMetadata sheet should be identical across files. This script:
#   1. Reads sampleMetadata from every file in INPUT_FILES
#   2. Cross-checks that they agree (stops with a clear error if not -
#      silently trusting mismatched metadata would be worse than failing)
#   3. Builds eventID from samp_name
#   4. Splits into: real-sample events (-> Event core) vs control-sample
#      events (-> controls/ reference file, NOT part of the mapped archive)
#   5. Maps FAIRe/MIxS field names to Darwin Core Event/Location terms
#   6. Writes output/event_core/Event.csv
#
# NOTE on eventID: this script uses samp_name as eventID as-is (e.g.
# "OcOm_2408_1_1"), since project_id is already embedded in samp_name
# and it was already confirmed globally unique across all 628 samples
# in all 3 assay files. If you'd rather prefix it differently, change
# build_event_id() below.

library(readxl)
library(dplyr)
library(tibble)

# ----------------------------------------------------------------------
# Helper: read a FAIRe sheet that has the 3-row header structure
# (row1 = requirement_level_code, row2 = section, row3 = actual col names)
# ----------------------------------------------------------------------
read_faire_sheet <- function(path, sheet) {
  raw <- read_excel(path, sheet = sheet, col_names = FALSE)
  col_names <- as.character(raw[3, ])
  data <- raw[-(1:3), ]
  names(data) <- col_names
  data
}

build_event_id <- function(samp_name) {
  # samp_name already looks like "<project_id>_<site>_<replicate>",
  # e.g. OcOm_2408_1_1 - already unique within and across projects.
  as.character(samp_name)
}

# ----------------------------------------------------------------------
# 1. Read sampleMetadata from every assay file
# ----------------------------------------------------------------------
cat("Reading sampleMetadata from", length(INPUT_FILES), "assay files...\n")

sample_tables <- lapply(names(INPUT_FILES), function(assay) {
  cat("  -", assay, "\n")
  read_faire_sheet(INPUT_FILES[[assay]], "sampleMetadata")
})
names(sample_tables) <- names(INPUT_FILES)

# ----------------------------------------------------------------------
# 2. Cross-check: all assay files must agree on shared sample metadata
# ----------------------------------------------------------------------
source_assay <- EVENT_CORE_SOURCE_ASSAY
base_table <- sample_tables[[source_assay]]

# assay_name is expected to differ (it's assay-specific) - drop it before
# comparing, along with any other known per-assay column.
comparison_exclude <- c("assay_name")

other_assays <- setdiff(names(sample_tables), source_assay)

for (other in other_assays) {
  other_table <- sample_tables[[other]]

  common_cols <- intersect(
    setdiff(names(base_table), comparison_exclude),
    setdiff(names(other_table), comparison_exclude)
  )

  base_sub  <- base_table  %>% select(all_of(common_cols)) %>% arrange(samp_name)
  other_sub <- other_table %>% select(all_of(common_cols)) %>% arrange(samp_name)

  if (!identical(nrow(base_sub), nrow(other_sub))) {
    stop(sprintf(
      "Row count mismatch between %s (%d rows) and %s (%d rows) - cannot safely build a shared Event core.",
      source_assay, nrow(base_sub), other, nrow(other_sub)
    ))
  }

  mismatches <- !mapply(identical, base_sub, other_sub)
  if (any(mismatches)) {
    stop(sprintf(
      "sampleMetadata mismatch between %s and %s in column(s): %s\nResolve this before building a shared Event core - do not proceed with mismatched sample metadata.",
      source_assay, other, paste(names(mismatches)[mismatches], collapse = ", ")
    ))
  }

  cat("  OK:", other, "matches", source_assay, "(", nrow(other_sub), "samples,", length(common_cols), "shared columns)\n")
}

cat("\nAll assay files agree on shared sample metadata. Proceeding with", source_assay, "as source.\n\n")

# ----------------------------------------------------------------------
# 3. Split into real samples vs controls
# ----------------------------------------------------------------------
all_samples <- base_table %>%
  mutate(eventID = build_event_id(samp_name))

real_samples <- all_samples %>%
  filter(samp_category == SAMPLE_CATEGORY_KEEP)

control_samples <- all_samples %>%
  filter(samp_category != SAMPLE_CATEGORY_KEEP)

cat("Real samples (-> Event core):", nrow(real_samples), "\n")
cat("Control samples (-> controls/ reference file only):", nrow(control_samples), "\n\n")

# ----------------------------------------------------------------------
# 4. Map FAIRe / MIxS fields to Darwin Core Event + Location terms
# ----------------------------------------------------------------------
# This follows the MIxS -> DwC crosswalk and OBIS Event core guidance
# covered in Module 2/3 of the OBIS course:
#   samp_name          -> (source for) eventID
#   eventDate          -> eventDate            (already DwC-named in FAIRe)
#   decimalLatitude/Longitude -> decimalLatitude/decimalLongitude (already DwC-named)
#   env_broad_scale / env_local_scale / env_medium -> kept as-is (ENVO terms)
#   minimumDepthInMeters / maximumDepthInMeters -> kept as-is
#   samp_collect_method / samp_collect_device -> samplingProtocol
#   samp_size / samp_size_unit -> sampleSizeValue / sampleSizeUnit
#   site_id -> locationID
#   verbatimLatitude/Longitude, verbatimCoordinateSystem, verbatimSRS -> kept as verbatim* fields
#
# Anything not mapped here is left out of the Event core for now; if you
# want to keep it, add it to `event_core` below or route it to eMoF if
# it's a measurement.

event_core <- real_samples %>%
  transmute(
    eventID,
    parentEventID = NA_character_,        # no hierarchy identified yet - add if applicable
    eventDate,
    verbatimEventDate,
    verbatimEventTime,
    decimalLatitude  = as.numeric(decimalLatitude),
    decimalLongitude = as.numeric(decimalLongitude),
    verbatimLatitude,
    verbatimLongitude,
    verbatimCoordinateSystem,
    verbatimSRS,
    locationID = site_id,
    minimumDepthInMeters = as.numeric(minimumDepthInMeters),
    maximumDepthInMeters = as.numeric(maximumDepthInMeters),
    env_broad_scale,
    env_local_scale,
    env_medium,
    samplingProtocol = samp_collect_method,
    sampleSizeValue  = samp_size,
    sampleSizeUnit   = samp_size_unit,
    habitat_natural_artificial_0_1,
    waterTemperature = temp,
    salinity,
    ph,
    dissolvedOxygen  = diss_oxygen,
    dissolvedOxygenUnit = diss_oxygen_unit,
    turbidity,
    tidal_stage,
    water_current,
    samp_weather,
    georeferenceSources = "OceanOmics field GPS",  # placeholder - adjust if a different source applies
    eventRemarks = site_comments
  )

cat("Event core built:", nrow(event_core), "rows,", ncol(event_core), "columns\n")

# ----------------------------------------------------------------------
# 5. Write outputs
# ----------------------------------------------------------------------
dir.create(dirname(EVENT_CORE_OUTPUT), recursive = TRUE, showWarnings = FALSE)
dir.create(CONTROLS_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

write.csv(event_core, EVENT_CORE_OUTPUT, row.names = FALSE, na = "")
cat("Written:", EVENT_CORE_OUTPUT, "\n")

controls_out <- file.path(CONTROLS_OUTPUT_DIR, "sample_controls_reference.csv")
write.csv(control_samples, controls_out, row.names = FALSE, na = "")
cat("Written:", controls_out, "(reference only - not part of the mapped Darwin Core archive)\n")
