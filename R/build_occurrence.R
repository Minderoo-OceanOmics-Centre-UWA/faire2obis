### R/build_occurrence.R
#
# Refactored from scripts/02_build_occurrence.R (now a thin CLI wrapper
# around build_occurrence() below). Pure function - see that script for
# the full design rationale (the "dropped" placeholder handling, etc.).

resolve_scientific_name <- function(taxa) {
  rank_col <- list(
    species = "scientificName",
    genus   = "genus",
    family  = "family",
    order   = "order",
    class   = "class",
    phylum  = "phylum",
    domain  = "domain"
  )

  taxa %>%
    dplyr::rowwise() %>%
    dplyr::mutate(
      resolvedScientificName = if (taxonRank == "not applicable") {
        # WoRMS AphiaID 12's actual scientificName is "Biota incertae
        # sedis" (verified directly against the live record) - not
        # "Incertae sedis" alone. OBIS's own DNA-derived-data guidance
        # (manual.obis.org/dna_data) requires this exact string for
        # wholly unknown sequences, paired with this LSID.
        "Biota incertae sedis"
      } else if (taxonRank %in% names(rank_col)) {
        val <- get(rank_col[[taxonRank]])
        if (is.na(val) || val %in% c("dropped", "not applicable")) NA_character_ else val
      } else {
        NA_character_
      },
      resolvedScientificNameID = if (taxonRank == "not applicable") {
        "urn:lsid:marinespecies.org:taxname:12"
      } else {
        NA_character_
      }
    ) %>%
    dplyr::ungroup()
}

get_real_event_ids <- function(source_assay_path, sample_category_keep) {
  samples <- read_faire_sheet(source_assay_path, "sampleMetadata")
  samples %>%
    dplyr::filter(samp_category == sample_category_keep) %>%
    dplyr::pull(samp_name)
}

#' Build one Darwin Core Occurrence extension per assay.
#'
#' @param input_files Named list: assay name -> path to that assay's FAIRe .xlsx
#' @param real_event_ids Character vector of real (non-control) eventIDs (see
#'   get_real_event_ids(), or reuse build_event_core()'s output eventIDs)
#' @param associated_sequences_uri Constant value for associatedSequences (e.g. an
#'   ENA/SRA project accession link)
#' @return list(occurrence = named list of per-assay tibbles, messages = character())
build_occurrence <- function(input_files, real_event_ids, associated_sequences_uri) {
  messages <- character()
  log_msg <- function(...) messages <<- c(messages, paste0(...))
  occurrence_tables <- list()

  for (assay in names(input_files)) {
    log_msg("Processing assay: ", assay)
    path <- input_files[[assay]]

    taxa <- read_faire_sheet(path, "taxaFinal")
    taxa <- resolve_scientific_name(taxa)
    n_unresolved <- sum(is.na(taxa$resolvedScientificName))
    log_msg("  Taxa rows: ", nrow(taxa), " | unresolved after fallback: ", n_unresolved)

    otu <- readxl::read_excel(path, sheet = "otuFinal", col_names = TRUE)
    names(otu)[1] <- "seq_id"
    keep_cols <- c("seq_id", intersect(names(otu), real_event_ids))
    otu <- otu[, keep_cols]

    sample_totals <- otu %>%
      dplyr::select(-seq_id) %>%
      dplyr::summarise(dplyr::across(dplyr::everything(), ~ sum(.x, na.rm = TRUE))) %>%
      tidyr::pivot_longer(dplyr::everything(), names_to = "eventID", values_to = "sampleSizeValue")

    otu_long <- otu %>%
      tidyr::pivot_longer(-seq_id, names_to = "eventID", values_to = "organismQuantity") %>%
      dplyr::filter(organismQuantity > 0)

    log_msg("  Non-zero ASV-by-sample detections: ", nrow(otu_long))

    occurrence <- otu_long %>%
      dplyr::left_join(taxa, by = "seq_id") %>%
      dplyr::left_join(sample_totals, by = "eventID") %>%
      dplyr::transmute(
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
        identificationReferences = ifelse(
          !is.na(accession_id) & accession_id != "not applicable" &
            !is.na(accession_id_ref_db) & accession_id_ref_db != "not applicable",
          paste(accession_id_ref_db, accession_id, sep = ":"),
          NA_character_
        ),
        identificationRemarks = dplyr::case_when(
          is.na(percent_match) | percent_match == "not applicable" ~ identificationRemarks,
          TRUE ~ paste0(
            identificationRemarks,
            ". Reference-database match: ", percent_match, "% identity, ",
            percent_query_cover, "% query coverage, confidence score ", confidence_score,
            dplyr::if_else(unusual_size == "TRUE", " (flagged: unusual sequence length).", ".")
          )
        ),
        organismQuantity,
        organismQuantityType = "DNA sequence reads",
        sampleSizeValue,
        sampleSizeUnit = "DNA sequence reads",
        associatedSequences = associated_sequences_uri
      )

    n_missing_name <- sum(is.na(occurrence$scientificName))
    if (n_missing_name > 0) {
      log_msg("  WARNING: ", n_missing_name, " rows have no resolvable scientificName - review before publishing.")
    }

    occurrence_tables[[assay]] <- occurrence
    log_msg("  Built ", nrow(occurrence), " rows for ", assay)
  }

  list(occurrence = occurrence_tables, messages = messages)
}
