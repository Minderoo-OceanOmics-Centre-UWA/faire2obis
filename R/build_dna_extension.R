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

#' Write ampliconSize the way NOAA Omics' metabarcoding-assay guidance does:
#' a single integer, or a range as "min | max" (e.g. "140 | 160").
#' github.com/NOAA-Omics/noaa-omics-metabarcoding-assays#assay-preps
#' FAIRe sheets usually give ranges as "178-228"; a combined assay arrives
#' here as "163-185 | 163-212" (one range per projectMetadata column), which
#' becomes the overall span "163 | 212". Anything without a number is
#' returned unchanged.
format_amplicon_size <- function(x) {
  if (is.na(x) || !nzchar(x)) return(x)
  nums <- as.integer(regmatches(x, gregexpr("[0-9]+", x))[[1]])
  if (length(nums) == 0) return(x)
  if (min(nums) == max(nums)) as.character(nums[1]) else paste0(min(nums), " | ", max(nums))
}

#' annealingTemp is a GBIF decimal. A value that isn't one number (e.g.
#' "54-56" for a touchdown PCR, or "60 | 54" for a combined assay) is left
#' blank rather than averaged or guessed - the lab confirmed an average would
#' be inaccurate - and the value as recorded is appended to pcr_cond so it
#' isn't lost. Returns list(annealingTemp, pcr_cond).
split_annealing_temp <- function(annealing_temp, pcr_cond) {
  if (is.na(annealing_temp) || !nzchar(annealing_temp) ||
      !is.na(suppressWarnings(as.numeric(annealing_temp)))) {
    return(list(annealingTemp = annealing_temp, pcr_cond = pcr_cond))
  }
  note <- paste0("annealingTemp recorded as ", annealing_temp, " Celsius (not a single value)")
  list(annealingTemp = NA_character_,
       pcr_cond = if (is.na(pcr_cond) || !nzchar(pcr_cond)) note else paste0(pcr_cond, "; ", note))
}

#' Build one Darwin Core DNA Derived Data extension per assay.
#'
#' @param input_files Named list: assay name -> path to that assay's FAIRe .xlsx
#' @param occurrence_tables Named list of per-assay Occurrence tibbles (from
#'   build_occurrence(), AFTER WoRMS matching if you want the final scientificName -
#'   this extension doesn't use scientificName, only occurrenceID/eventID, so order
#'   relative to match_worms() doesn't matter for this function specifically)
#' @param assay_project_column Named list: assay -> projectMetadata assay column(s)
#'   (e.g. list(MiFishUE2 = c("assay1", "assay3")) for a combined assay)
#' @return list(dna_extension = named list of per-assay tibbles, messages = character())
build_dna_extension <- function(input_files, occurrence_tables, assay_project_column) {
  messages <- character()
  log_msg <- function(...) messages <<- c(messages, paste0(...))

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

    annealing <- split_annealing_temp(assay_meta$annealingTemp, assay_meta$pcr_cond)
    if (is.na(annealing$annealingTemp) && !is.na(assay_meta$annealingTemp)) {
      log_msg("  annealingTemp '", assay_meta$annealingTemp, "' is not a single value - left blank, recorded in pcr_cond instead")
    }

    seq_meth <- paste(na.omit(c(assay_meta$platform, assay_meta$instrument)), collapse = " ")
    if (!is.na(assay_meta$seq_method_additional) && assay_meta$seq_method_additional != "") {
      seq_meth <- paste0(seq_meth, " (", assay_meta$seq_method_additional, ")")
    }

    taxa <- read_faire_sheet(path, "taxaFinal") %>% dplyr::select(seq_id, dna_sequence)

    # env_* fields live here (not in the Event core) - sampleMetadata is
    # verified identical across assays by build_event_core().
    event_slim <- read_faire_sheet(path, "sampleMetadata") %>%
      dplyr::rename(eventID = samp_name) %>%
      dplyr::select(eventID, env_broad_scale, env_local_scale, env_medium)

    occ <- occurrence_tables[[assay]]
    if (is.null(occ)) stop("No Occurrence table found for assay '", assay, "' - run build_occurrence() first.")

    # seq_id now comes straight from build_occurrence()'s own output
    # column (added alongside the eventID+assay+seq_id occurrenceID
    # fix), not re-derived from occurrenceID by substring position -
    # that reconstruction was fragile even before the collision bug
    # (assumed a fixed "eventID_seqid" shape) and would have broken
    # outright once occurrenceID's format changed to include the
    # assay name.
    detections <- occ %>%
      dplyr::transmute(occurrenceID, eventID, seq_id)

    dna_ext <- detections %>%
      dplyr::left_join(taxa, by = "seq_id") %>%
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
        ampliconSize                    = format_amplicon_size(assay_meta$ampliconSize),
        pcr_primer_forward              = assay_meta$pcr_primer_forward,
        pcr_primer_reverse              = assay_meta$pcr_primer_reverse,
        pcr_primer_name_forward         = assay_meta$pcr_primer_name_forward,
        pcr_primer_name_reverse         = assay_meta$pcr_primer_name_reverse,
        pcr_primer_reference            = paste(
          na.omit(c(assay_meta$pcr_primer_reference_forward, assay_meta$pcr_primer_reference_reverse)),
          collapse = " | "
        ),
        pcr_cond                        = annealing$pcr_cond,
        annealingTemp                   = annealing$annealingTemp,
        annealingTempUnit               = if (is.na(annealing$annealingTemp)) NA_character_ else "Celsius",
        amplificationReactionVolume     = assay_meta$amplificationReactionVolume,
        amplificationReactionVolumeUnit = "microliter",
        lib_layout                      = assay_meta$lib_layout,
        seq_meth                        = seq_meth,
        # otu_class_appr is the DwC DNA Derived Data term; it replaces the
        # FAIRe otu_clust_tool/otu_clust_cutoff fields, which have no DwC
        # term of their own and are combined into it here.
        otu_class_appr                 = paste(
          na.omit(c(assay_meta$otu_clust_tool, assay_meta$otu_clust_cutoff)),
          collapse = "; "
        ),
        otu_db                          = assay_meta$otu_db,
        otu_seq_comp_appr               = assay_meta$otu_seq_comp_appr,
        sop                             = assay_meta$sop_bioinformatics
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
