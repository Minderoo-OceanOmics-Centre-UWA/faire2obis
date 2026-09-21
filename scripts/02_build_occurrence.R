### 02_build_occurrence.R
#
# CLI wrapper around build_occurrence() (R/build_occurrence.R). Builds
# one Darwin Core Occurrence extension table per assay from that
# assay's taxaFinal + otuFinal sheets, linked to the Event core built by
# 01_build_event_core.R via eventID.
#
# Key data-quality issue handled in build_occurrence() (found while
# inspecting taxaFinal):
#   The LCA (Lowest Common Ancestor) pipeline that produced taxaFinal
#   writes the literal string "dropped" into scientificName/genus/
#   specificEpithet columns below the rank it could confidently resolve
#   to. E.g. a sequence resolved only to family level has
#   scientificName == "dropped" but family == "Scomberesocidae" (a real
#   value). Naively using the scientificName column as-is would publish
#   the literal word "dropped" as a species name.
#
#   Fix: derive scientificName from the column matching taxonRank
#   (species -> scientificName as given; genus -> genus col; family ->
#   family col; etc.), following the course's low-confidence
#   identification rule (use lowest rank with a real, high-confidence
#   value). Rows with taxonRank == "not applicable" (completely
#   unresolved sequences) get scientificName = "Biota incertae sedis"
#   (the exact scientificName of WoRMS AphiaID 12, verified directly
#   against the live record - not "Incertae sedis" alone) and
#   scientificNameID = urn:lsid:marinespecies.org:taxname:12, per OBIS's
#   own DNA-derived-data guidance (manual.obis.org/dna_data) for
#   unknown sequences.
#
# taxonID/taxonID_db in taxaFinal come from NCBI/GenBank, NOT WoRMS -
# these map to taxonConceptID, not scientificNameID. Real scientificNameID
# (WoRMS LSID) is populated later by 04_worms_match.R, run separately so
# ambiguous/unmatched names can be reviewed before publishing.
#
# Also carries scientificNameAuthorship, identificationReferences (the
# GenBank/BOLD/etc. accession backing each ID), and match-quality
# metrics (percent_match/percent_query_cover/confidence_score/
# unusual_size) appended into identificationRemarks - found during an
# audit of taxaFinal's unused columns: ~80% populated, genuinely useful
# for a public user judging how trustworthy an identification is, and
# previously computed by the pipeline but silently discarded.

library(readxl)
library(dplyr)
library(tidyr)
library(tibble)

source("R/faire_io.R")
source("R/build_occurrence.R")

real_event_ids <- get_real_event_ids(INPUT_FILES[[EVENT_CORE_SOURCE_ASSAY]], SAMPLE_CATEGORY_KEEP)
cat("Real (non-control) samples:", length(real_event_ids), "\n\n")

result <- build_occurrence(
  input_files              = INPUT_FILES,
  real_event_ids           = real_event_ids,
  associated_sequences_uri = ASSOCIATED_SEQUENCES_URI
)

cat(paste(result$messages, collapse = "\n"), "\n")

dir.create(OCCURRENCE_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

for (assay in names(result$occurrence)) {
  out_path <- file.path(OCCURRENCE_OUTPUT_DIR, paste0("Occurrence_", assay, ".csv"))
  write.csv(result$occurrence[[assay]], out_path, row.names = FALSE, na = "")
  cat("Written:", out_path, "(", nrow(result$occurrence[[assay]]), "rows )\n")
}
