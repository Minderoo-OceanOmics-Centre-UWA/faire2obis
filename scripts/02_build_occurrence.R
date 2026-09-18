### 02_build_occurrence.R
#
# Builds one Darwin Core Occurrence extension table per assay from that
# assay's taxaFinal + otuFinal sheets, linked to the Event core built by
# 01_build_event_core.R via eventID.
#
# Key data-quality issue handled here (found while inspecting taxaFinal):
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
#   unresolved sequences) get scientificName = "Incertae sedis" and
#   scientificNameID = urn:lsid:marinespecies.org:taxname:12, per OBIS
#   guidance for unknown sequences.
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

read_faire_sheet <- function(path, sheet) {
  raw <- read_excel(path, sheet = sheet, col_names = FALSE)
  col_names <- as.character(raw[3, ])
  data <- raw[-(1:3), ]
  names(data) <- col_names
  data
}

# ----------------------------------------------------------------------
# Resolve the correct scientificName from taxonRank + rank-specific columns
# ----------------------------------------------------------------------
resolve_scientific_name <- function(taxa) {
  rank_col <- list(
    species = "scientificName",  # already a full binomial when rank == species
    genus   = "genus",
    family  = "family",
    order   = "order",
    class   = "class",
    phylum  = "phylum",
    domain  = "domain"
  )

  taxa %>%
    rowwise() %>%
    mutate(
      resolvedScientificName = if (taxonRank == "not applicable") {
        "Incertae sedis"
      } else if (taxonRank %in% names(rank_col)) {
        val <- get(rank_col[[taxonRank]])
        if (is.na(val) || val %in% c("dropped", "not applicable")) NA_character_ else val
      } else {
        NA_character_
      },
      resolvedScientificNameID = if (taxonRank == "not applicable") {
        "urn:lsid:marinespecies.org:taxname:12"
      } else {
        NA_character_   # filled in later by 04_worms_match.R
      }
    ) %>%
    ungroup()
}

# ----------------------------------------------------------------------
# Get the set of real (non-control) eventIDs - must match 01's output
# ----------------------------------------------------------------------
get_real_event_ids <- function(source_assay_path) {
  samples <- read_faire_sheet(source_assay_path, "sampleMetadata")
  samples %>%
    filter(samp_category == SAMPLE_CATEGORY_KEEP) %>%
    pull(samp_name)
}

real_event_ids <- get_real_event_ids(INPUT_FILES[[EVENT_CORE_SOURCE_ASSAY]])
cat("Real (non-control) samples:", length(real_event_ids), "\n\n")

# ----------------------------------------------------------------------
# Process each assay
# ----------------------------------------------------------------------
dir.create(OCCURRENCE_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

for (assay in names(INPUT_FILES)) {

  cat("=========================================\n")
  cat("Processing assay:", assay, "\n")
  cat("=========================================\n")

  path <- INPUT_FILES[[assay]]

  # -- taxonomy --------------------------------------------------------
  taxa <- read_faire_sheet(path, "taxaFinal")
  taxa <- resolve_scientific_name(taxa)

  n_unresolved <- sum(is.na(taxa$resolvedScientificName))
  cat("  Taxa rows:", nrow(taxa), " | unresolved after fallback:", n_unresolved, "\n")

  # -- OTU table (ASV x sample matrix) ---------------------------------
  otu <- read_excel(path, sheet = "otuFinal", col_names = TRUE)
  names(otu)[1] <- "seq_id"

  # keep only real (non-control) sample columns
  keep_cols <- c("seq_id", intersect(names(otu), real_event_ids))
  otu <- otu[, keep_cols]

  # total reads per sample (for sampleSizeValue) - computed from this
  # assay's otuFinal column sums. NOTE: if a separate, authoritative
  # total-read-count-per-library field exists elsewhere (e.g. from the
  # sequencer/demux stats), prefer that instead - this is the best
  # available figure from the provided files.
  sample_totals <- otu %>%
    select(-seq_id) %>%
    summarise(across(everything(), ~ sum(.x, na.rm = TRUE))) %>%
    pivot_longer(everything(), names_to = "eventID", values_to = "sampleSizeValue")

  # -- reshape OTU matrix to long format (one row per ASV-per-sample
  #    detection), dropping zero-read combinations --------------------
  otu_long <- otu %>%
    pivot_longer(-seq_id, names_to = "eventID", values_to = "organismQuantity") %>%
    filter(organismQuantity > 0)

  cat("  Non-zero ASV-by-sample detections:", nrow(otu_long), "\n")

  # -- join taxonomy + sample totals, build DwC fields -----------------
  occurrence <- otu_long %>%
    left_join(taxa, by = "seq_id") %>%
    left_join(sample_totals, by = "eventID") %>%
    transmute(
      occurrenceID = paste(eventID, seq_id, sep = "_"),
      eventID,
      basisOfRecord = "MaterialSample",
      occurrenceStatus = "present",
      scientificName = resolvedScientificName,
      scientificNameID = resolvedScientificNameID,
      taxonRank,
      taxonConceptID = ifelse(
        !is.na(taxonID) & !is.na(taxonID_db),
        paste(taxonID_db, taxonID, sep = ":"),
        NA_character_
      ),
      verbatimIdentification,
      scientificNameAuthorship = ifelse(
        is.na(scientificNameAuthorship) | grepl("^not applicable", scientificNameAuthorship),
        NA_character_, scientificNameAuthorship
      ),
      # identificationReferences: the specific reference-database accession
      # that produced this ID (e.g. "GenBank:OP057059.2") - real evidence
      # a public user can go check, not just a textual description.
      identificationReferences = ifelse(
        !is.na(accession_id) & accession_id != "not applicable" &
          !is.na(accession_id_ref_db) & accession_id_ref_db != "not applicable",
        paste(accession_id_ref_db, accession_id, sep = ":"),
        NA_character_
      ),
      # identificationRemarks: keep the existing LCA-pipeline note, and
      # append the match-quality metrics (all populated together, ~80%
      # of rows) plus the unusual-sequence-length QC flag when present -
      # both were previously computed by the pipeline but discarded.
      identificationRemarks = case_when(
        is.na(percent_match) | percent_match == "not applicable" ~ identificationRemarks,
        TRUE ~ paste0(
          identificationRemarks,
          ". Reference-database match: ", percent_match, "% identity, ",
          percent_query_cover, "% query coverage, confidence score ", confidence_score,
          if_else(unusual_size == "TRUE", " (flagged: unusual sequence length).", ".")
        )
      ),
      organismQuantity,
      organismQuantityType = "DNA sequence reads",
      sampleSizeValue,
      sampleSizeUnit = "DNA sequence reads",
      associatedSequences = ASSOCIATED_SEQUENCES_URI
    )

  n_missing_name <- sum(is.na(occurrence$scientificName))
  if (n_missing_name > 0) {
    cat("  WARNING:", n_missing_name, "rows have no resolvable scientificName",
        "(taxonRank present but rank-specific column also missing/dropped) - review before publishing.\n")
  }

  out_path <- file.path(OCCURRENCE_OUTPUT_DIR, paste0("Occurrence_", assay, ".csv"))
  write.csv(occurrence, out_path, row.names = FALSE, na = "")
  cat("  Written:", out_path, "(", nrow(occurrence), "rows )\n\n")
}
