### 03_build_dna_extension.R
#
# Builds one Darwin Core DNA Derived Data extension table per assay,
# linked to script 02's Occurrence tables via occurrenceID.
#
# Sources:
#   - taxaFinal$dna_sequence        -> DNA_sequence (the single most
#                                       important field in this extension)
#   - experimentRunMetadata         -> per-sample read counts
#   - projectMetadata (long format: term_name x assay1..assay4)
#                                    -> per-assay PCR/primer/bioinformatics
#                                       metadata, constant across all rows
#                                       of that assay
#   - Event core (output/event_core/Event.csv) -> env_broad_scale /
#                                       env_local_scale / env_medium,
#                                       joined back in via eventID
#   - config.R's ASSOCIATED_SEQUENCES_URI -> associatedSequences (ENA
#     project accession PRJEB107937, confirmed public 2026-09-18) -
#     experimentRunMetadata's own associatedSequences column is empty
#     for every row in this project (0/580 populated).
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

read_faire_sheet <- function(path, sheet) {
  raw <- read_excel(path, sheet = sheet, col_names = FALSE)
  col_names <- as.character(raw[3, ])
  data <- raw[-(1:3), ]
  names(data) <- col_names
  data
}

# ----------------------------------------------------------------------
# Helper: pull a term_name's value for a given assay column, falling
# back to project_level when the assay-specific cell is blank (matches
# how projectMetadata itself stores project-wide vs assay-specific terms)
# ----------------------------------------------------------------------
get_project_term <- function(project_meta, term, assay_cols) {
  row <- project_meta %>% filter(term_name == term)
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
    # fall back to project_level (project-wide constant, e.g. platform, instrument)
    pl <- row[["project_level"]]
    return(if (is.na(pl) || pl == "") NA_character_ else as.character(pl))
  }

  # multiple assay columns (e.g. MiFishUE2 = assay1 + assay3): concatenate
  # distinct values with " | " so both primer sets are documented rather
  # than silently picking one
  paste(unique(values), collapse = " | ")
}

# ----------------------------------------------------------------------
# Load the Event core (for env_broad_scale/env_local_scale/env_medium)
# ----------------------------------------------------------------------
event_core <- read_csv(EVENT_CORE_OUTPUT, show_col_types = FALSE) %>%
  select(eventID, env_broad_scale, env_local_scale, env_medium)

dir.create(DNA_EXTENSION_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

for (assay in names(INPUT_FILES)) {

  cat("=========================================\n")
  cat("Processing assay:", assay, "\n")
  cat("=========================================\n")

  path <- INPUT_FILES[[assay]]
  assay_cols <- ASSAY_PROJECT_COLUMN[[assay]]

  if (length(assay_cols) > 1) {
    cat("  NOTE: this assay maps to multiple projectMetadata columns (",
        paste(assay_cols, collapse = ", "),
        ") - primer/target fields are concatenated with ' | ' since",
        "MiFish-U + MiFish-E2 are confirmed to be run as one combined",
        "assay in this project (see config.R for details).\n\n")
  }

  # -- project-level / assay-level PCR + bioinformatics metadata -------
  project_meta <- read_excel(path, sheet = "projectMetadata", col_names = TRUE)

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

  # -- taxonomy (for DNA_sequence) --------------------------------------
  taxa <- read_faire_sheet(path, "taxaFinal") %>%
    select(seq_id, dna_sequence)

  # -- experiment run metadata (per-sample sequencing stats) -----------
  # experimentRunMetadata's own associatedSequences column is empty for
  # every row in this project (checked - 0/580 populated) - the real
  # value comes from ASSOCIATED_SEQUENCES_URI (config.R) instead.
  exp_run <- read_faire_sheet(path, "experimentRunMetadata") %>%
    rename(eventID = samp_name) %>%
    select(eventID, input_read_count, output_read_count)
  stopifnot(
    "experimentRunMetadata has more than one row for some sample(s) - joining as-is would duplicate DNA extension rows for those samples" =
      !any(duplicated(exp_run$eventID))
  )

  # -- detections: read script 02's Occurrence extension for this assay
  #    instead of re-deriving from otuFinal, so this extension can never
  #    disagree with the Occurrence extension it's linked to -----------
  occ_path <- file.path(OCCURRENCE_OUTPUT_DIR, paste0("Occurrence_", assay, ".csv"))
  if (!file.exists(occ_path)) {
    stop(sprintf("Occurrence extension not found at %s - run 02_build_occurrence.R first.", occ_path))
  }
  detections <- read_csv(occ_path, show_col_types = FALSE) %>%
    transmute(
      occurrenceID,
      eventID,
      seq_id = substr(occurrenceID, nchar(eventID) + 2, nchar(occurrenceID))
    )

  # -- assemble the DNA Derived Data extension --------------------------
  dna_ext <- detections %>%
    left_join(taxa, by = "seq_id") %>%
    left_join(exp_run, by = "eventID") %>%
    left_join(event_core, by = "eventID") %>%
    transmute(
      occurrenceID,
      DNA_sequence = dna_sequence,
      env_broad_scale,
      env_local_scale,
      env_medium,
      target_gene                  = assay_meta$target_gene,
      target_subfragment           = assay_meta$target_subfragment,
      ampliconSize                 = assay_meta$ampliconSize,
      pcr_primer_forward           = assay_meta$pcr_primer_forward,
      pcr_primer_reverse           = assay_meta$pcr_primer_reverse,
      pcr_primer_name_forward      = assay_meta$pcr_primer_name_forward,
      pcr_primer_name_reverse      = assay_meta$pcr_primer_name_reverse,
      pcr_primer_reference         = paste(
        na.omit(c(assay_meta$pcr_primer_reference_forward, assay_meta$pcr_primer_reference_reverse)),
        collapse = " | "
      ),
      pcr_cond                     = assay_meta$pcr_cond,
      annealingTemp                = assay_meta$annealingTemp,
      annealingTempUnit            = "Celsius",
      amplificationReactionVolume  = assay_meta$amplificationReactionVolume,
      amplificationReactionVolumeUnit = "microliter",
      lib_layout                   = assay_meta$lib_layout,
      seq_meth                     = seq_meth,
      otu_clust_tool                = assay_meta$otu_clust_tool,
      otu_clust_cutoff              = assay_meta$otu_clust_cutoff,
      otu_db                        = assay_meta$otu_db,
      otu_seq_comp_appr             = assay_meta$otu_seq_comp_appr,
      sop                           = assay_meta$sop_bioinformatics,
      associatedSequences           = ASSOCIATED_SEQUENCES_URI,
      input_read_count,
      output_read_count
    )

  n_missing_seq <- sum(is.na(dna_ext$DNA_sequence))
  if (n_missing_seq > 0) {
    cat("  WARNING:", n_missing_seq, "rows have no DNA_sequence - check taxaFinal join.\n")
  }

  out_path <- file.path(DNA_EXTENSION_OUTPUT_DIR, paste0("DNADerivedData_", assay, ".csv"))
  write_csv(dna_ext, out_path, na = "")
  cat("  Written:", out_path, "(", nrow(dna_ext), "rows )\n\n")
}
