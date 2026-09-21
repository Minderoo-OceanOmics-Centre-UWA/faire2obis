### R/build_dna_extension.R
#
# Refactored from scripts/03_build_dna_extension.R (now a thin CLI
# wrapper around build_dna_extension() below). Pure function - see that
# script for the full design rationale (why eventID AND occurrenceID
# both have to be present, the MiFishUE2 multi-column mapping, etc.).

get_project_term <- function(project_meta, term, assay_cols) {
  row <- project_meta %>% dplyr::filter(term_name == term)
  if (nrow(row) == 0) return(NA_character_)
  stopifnot(
    "projectMetadata has duplicate term_name rows - resolve before proceeding" =
      nrow(row) == 1
  )

  values <- sapply(assay_cols, function(col) {
    v <- row[[col]]
    if (length(v) == 0 || is.na(v) || v == "") NA_character_ else as.character(v)
  })
  values <- values[!is.na(values)]

  if (length(values) == 0) {
    pl <- row[["project_level"]]
    return(if (is.na(pl) || pl == "") NA_character_ else as.character(pl))
  }

  paste(unique(values), collapse = " | ")
}

#' Build one Darwin Core DNA Derived Data extension per assay.
#'
#' @param input_files Named list: assay name -> path to that assay's FAIRe .xlsx
#' @param occurrence_tables Named list of per-assay Occurrence tibbles (from
#'   build_occurrence(), AFTER WoRMS matching if you want the final scientificName -
#'   this extension doesn't use scientificName, only occurrenceID/eventID, so order
#'   relative to match_worms() doesn't matter for this function specifically)
#' @param event_core The built Event core tibble (from build_event_core())
#' @param assay_project_column Named list: assay -> projectMetadata assay column(s)
#'   (e.g. list(MiFishUE2 = c("assay1", "assay3")) for a combined assay)
#' @param associated_sequences_uri Constant value for associatedSequences
#' @return list(dna_extension = named list of per-assay tibbles, messages = character())
build_dna_extension <- function(input_files, occurrence_tables, event_core,
                                 assay_project_column, associated_sequences_uri) {
  messages <- character()
  log_msg <- function(...) messages <<- c(messages, paste0(...))

  event_slim <- event_core %>% dplyr::select(eventID, env_broad_scale, env_local_scale, env_medium)
  dna_tables <- list()

  for (assay in names(input_files)) {
    log_msg("Processing assay: ", assay)
    path <- input_files[[assay]]
    assay_cols <- assay_project_column[[assay]]

    if (length(assay_cols) > 1) {
      log_msg("  NOTE: this assay maps to multiple projectMetadata columns (",
               paste(assay_cols, collapse = ", "), ")")
    }

    project_meta <- readxl::read_excel(path, sheet = "projectMetadata", col_names = TRUE)

    pcr_fields <- c(
      "target_gene", "target_subfragment", "ampliconSize",
      "pcr_primer_forward", "pcr_primer_reverse",
      "pcr_primer_name_forward", "pcr_primer_name_reverse",
      "pcr_primer_reference_forward", "pcr_primer_reference_reverse",
      "pcr_cond", "annealingTemp", "amplificationReactionVolume",
      "lib_layout", "platform", "instrument", "seq_method_additional",
      "otu_clust_tool", "otu_clust_cutoff", "otu_db", "otu_seq_comp_appr",
      "sop_bioinformatics"
    )

    assay_meta <- setNames(
      lapply(pcr_fields, function(f) get_project_term(project_meta, f, assay_cols)),
      pcr_fields
    )

    seq_meth <- paste(na.omit(c(assay_meta$platform, assay_meta$instrument)), collapse = " ")
    if (!is.na(assay_meta$seq_method_additional) && assay_meta$seq_method_additional != "") {
      seq_meth <- paste0(seq_meth, " (", assay_meta$seq_method_additional, ")")
    }

    taxa <- read_faire_sheet(path, "taxaFinal") %>% dplyr::select(seq_id, dna_sequence)

    exp_run <- read_faire_sheet(path, "experimentRunMetadata") %>%
      dplyr::rename(eventID = samp_name) %>%
      dplyr::select(eventID, input_read_count, output_read_count)
    stopifnot(
      "experimentRunMetadata has more than one row for some sample(s) - joining as-is would duplicate DNA extension rows for those samples" =
        !any(duplicated(exp_run$eventID))
    )

    occ <- occurrence_tables[[assay]]
    if (is.null(occ)) stop("No Occurrence table found for assay '", assay, "' - run build_occurrence() first.")

    detections <- occ %>%
      dplyr::transmute(
        occurrenceID,
        eventID,
        seq_id = substr(occurrenceID, nchar(eventID) + 2, nchar(occurrenceID))
      )

    dna_ext <- detections %>%
      dplyr::left_join(taxa, by = "seq_id") %>%
      dplyr::left_join(exp_run, by = "eventID") %>%
      dplyr::left_join(event_slim, by = "eventID") %>%
      dplyr::transmute(
        # eventID is the archive's structural join key - a DwC-A
        # extension always links back to the CORE's own id, never to
        # another extension's id. occurrenceID stays as a plain data
        # field for cross-referencing to the Occurrence row it belongs to.
        eventID,
        occurrenceID,
        DNA_sequence = dna_sequence,
        env_broad_scale,
        env_local_scale,
        env_medium,
        target_gene                     = assay_meta$target_gene,
        target_subfragment              = assay_meta$target_subfragment,
        ampliconSize                    = assay_meta$ampliconSize,
        pcr_primer_forward              = assay_meta$pcr_primer_forward,
        pcr_primer_reverse              = assay_meta$pcr_primer_reverse,
        pcr_primer_name_forward         = assay_meta$pcr_primer_name_forward,
        pcr_primer_name_reverse         = assay_meta$pcr_primer_name_reverse,
        pcr_primer_reference            = paste(
          na.omit(c(assay_meta$pcr_primer_reference_forward, assay_meta$pcr_primer_reference_reverse)),
          collapse = " | "
        ),
        pcr_cond                        = assay_meta$pcr_cond,
        annealingTemp                   = assay_meta$annealingTemp,
        annealingTempUnit               = "Celsius",
        amplificationReactionVolume     = assay_meta$amplificationReactionVolume,
        amplificationReactionVolumeUnit = "microliter",
        lib_layout                      = assay_meta$lib_layout,
        seq_meth                        = seq_meth,
        # otu_class_appr is the actual DwC DNA Derived Data extension
        # term ("Approach/algorithm and clustering level ... when
        # defining OTUs or ASVs", e.g. MDT's own example
        # "dada2; 1.14.0; ASV") - found this project was outputting
        # only otu_clust_tool/otu_clust_cutoff (this pipeline's
        # source-side FAIRe field names) under their own names instead
        # of mapping them to the standard term, the same way sop is
        # correctly renamed from sop_bioinformatics below. Kept the
        # granular source fields too, for anyone reading the CSV
        # directly - IPT will just map otu_class_appr automatically.
        otu_class_appr                  = paste(
          na.omit(c(assay_meta$otu_clust_tool, assay_meta$otu_clust_cutoff)),
          collapse = "; "
        ),
        otu_clust_tool                  = assay_meta$otu_clust_tool,
        otu_clust_cutoff                = assay_meta$otu_clust_cutoff,
        otu_db                          = assay_meta$otu_db,
        otu_seq_comp_appr               = assay_meta$otu_seq_comp_appr,
        sop                             = assay_meta$sop_bioinformatics,
        associatedSequences             = associated_sequences_uri,
        input_read_count,
        output_read_count
      )

    n_missing_seq <- sum(is.na(dna_ext$DNA_sequence))
    if (n_missing_seq > 0) {
      log_msg("  WARNING: ", n_missing_seq, " rows have no DNA_sequence - check taxaFinal join.")
    }

    dna_tables[[assay]] <- dna_ext
    log_msg("  Built ", nrow(dna_ext), " rows for ", assay)
  }

  list(dna_extension = dna_tables, messages = messages)
}
