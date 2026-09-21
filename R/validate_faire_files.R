### R/validate_faire_files.R
#
# Structural + content validation for uploaded FAIRe files, built for
# the Shiny app's "Validate & Fix" step. Unlike build_event_core()
# (which stop()s hard on a sampleMetadata mismatch - correct for a CLI
# pipeline meant to fail loudly), this returns a structured list of
# issues so a UI can render each one with the right fix: a blocking
# error to take back to the source file, a question to ask the user
# for a project-level config value that has no source in the data at
# all (e.g. what GPS system was used), or a table of specific rows
# missing a required field for the user to fill in directly.
#
# Each issue is a list:
#   id       - stable string id (for tracking fixes across re-validation)
#   severity - "error" (blocks proceeding) | "warning" (should fix, not blocking)
#   title    - short label
#   message  - explanation of what's wrong and why it matters
#   fix_type - "config_question" | "data_table" | "info_only"
#   field    - (config_question only) which config value this answers
#   data     - (data_table only) tibble of the affected rows
#   columns  - (data_table only) character vector of the editable column(s)

REQUIRED_SHEETS <- c("projectMetadata", "sampleMetadata", "experimentRunMetadata", "taxaFinal", "otuFinal")
REQUIRED_SAMPLE_COLUMNS <- c("samp_name", "samp_category", "eventDate", "decimalLatitude", "decimalLongitude")

#' @param input_files Named list: assay name -> path to that assay's FAIRe .xlsx
#' @param sample_category_keep The samp_category value marking a real (non-control) sample
#' @param georeference_sources Current value (NA if not yet supplied by the user)
#' @param associated_sequences_uri Current value (NA if not yet supplied by the user)
#' @return list(issues = list of issue objects, any_blocking = logical)
validate_faire_files <- function(input_files,
                                  sample_category_keep,
                                  georeference_sources = NA_character_,
                                  associated_sequences_uri = NA_character_) {
  issues <- list()
  add_issue <- function(issue) issues[[length(issues) + 1]] <<- issue

  # ---- 1. Required sheets present in every uploaded file ----------------
  sheet_lists <- list()
  for (assay in names(input_files)) {
    sheets <- tryCatch(readxl::excel_sheets(input_files[[assay]]), error = function(e) character())
    sheet_lists[[assay]] <- sheets
    missing_sheets <- setdiff(REQUIRED_SHEETS, sheets)
    if (length(missing_sheets) > 0) {
      add_issue(list(
        id = paste0("missing_sheets_", assay),
        severity = "error",
        title = paste0(assay, ": missing required sheet(s)"),
        message = paste0(
          "This file is missing: ", paste(missing_sheets, collapse = ", "),
          ". A FAIRe workbook needs all of: ", paste(REQUIRED_SHEETS, collapse = ", "),
          ". Re-upload a complete FAIRe file for this assay."
        ),
        fix_type = "blocking_error"
      ))
    }
  }
  if (any(vapply(issues, function(i) i$severity == "error", logical(1)))) {
    # Can't safely read further sheets if a required one is missing.
    return(list(issues = issues, any_blocking = TRUE))
  }

  # ---- 2. Required sampleMetadata columns present ------------------------
  sample_tables <- list()
  for (assay in names(input_files)) {
    sm <- tryCatch(read_faire_sheet(input_files[[assay]], "sampleMetadata"), error = function(e) NULL)
    sample_tables[[assay]] <- sm
    if (is.null(sm)) {
      add_issue(list(
        id = paste0("unreadable_sampleMetadata_", assay),
        severity = "error",
        title = paste0(assay, ": sampleMetadata could not be read"),
        message = "Check the file isn't corrupted and the 3-row header (requirement_level_code / section / column names) is intact.",
        fix_type = "blocking_error"
      ))
      next
    }
    missing_cols <- setdiff(REQUIRED_SAMPLE_COLUMNS, names(sm))
    if (length(missing_cols) > 0) {
      add_issue(list(
        id = paste0("missing_columns_", assay),
        severity = "error",
        title = paste0(assay, ": sampleMetadata missing required column(s)"),
        message = paste0("Missing: ", paste(missing_cols, collapse = ", "), ". These are required to build the Event core."),
        fix_type = "blocking_error"
      ))
    }
  }
  if (any(vapply(issues, function(i) i$severity == "error", logical(1)))) {
    return(list(issues = issues, any_blocking = TRUE))
  }

  # ---- 3. Cross-assay sampleMetadata consistency -------------------------
  # (soft version of build_event_core()'s stop() - surfaced as an issue,
  # not a hard halt, so the user sees it in context with everything else)
  assay_names <- names(input_files)
  if (length(assay_names) > 1) {
    base_assay <- assay_names[1]
    base_table <- sample_tables[[base_assay]]
    comparison_exclude <- "assay_name"

    for (other in assay_names[-1]) {
      other_table <- sample_tables[[other]]
      common_cols <- intersect(setdiff(names(base_table), comparison_exclude), setdiff(names(other_table), comparison_exclude))
      base_sub  <- base_table  %>% dplyr::select(dplyr::all_of(common_cols)) %>% dplyr::arrange(samp_name)
      other_sub <- other_table %>% dplyr::select(dplyr::all_of(common_cols)) %>% dplyr::arrange(samp_name)

      if (!identical(nrow(base_sub), nrow(other_sub))) {
        add_issue(list(
          id = paste0("row_count_mismatch_", base_assay, "_", other),
          severity = "error",
          title = paste0("Sample count mismatch: ", base_assay, " vs ", other),
          message = paste0(
            base_assay, " has ", nrow(base_sub), " samples, ", other, " has ", nrow(other_sub),
            ". All assays are expected to share the same physical samples - this must match before a shared Event core can be built."
          ),
          fix_type = "blocking_error"
        ))
        next
      }

      mismatches <- !mapply(identical, base_sub, other_sub)
      if (any(mismatches)) {
        add_issue(list(
          id = paste0("column_mismatch_", base_assay, "_", other),
          severity = "error",
          title = paste0("sampleMetadata disagrees: ", base_assay, " vs ", other),
          message = paste0(
            "Column(s) differ between these two assays' sampleMetadata: ",
            paste(names(mismatches)[mismatches], collapse = ", "),
            ". Since both assays sequence the same physical samples, this metadata should be identical - resolve the discrepancy in the source files."
          ),
          fix_type = "blocking_error"
        ))
      }
    }
  }

  # ---- 4. Row-level completeness for REAL samples -------------------------
  base_table <- sample_tables[[assay_names[1]]]
  real_samples <- base_table %>% dplyr::filter(samp_category == sample_category_keep)

  incomplete <- real_samples %>%
    dplyr::filter(is.na(eventDate) | is.na(decimalLatitude) | is.na(decimalLongitude) | as.character(decimalLatitude) == "" | as.character(decimalLongitude) == "")

  if (nrow(incomplete) > 0) {
    add_issue(list(
      id = "incomplete_required_fields",
      severity = "error",
      title = paste0(nrow(incomplete), " sample(s) missing eventDate or coordinates"),
      message = "These required fields have no value. Fill them in below before continuing - OBIS QC will drop any record with a missing or zero coordinate.",
      fix_type = "data_table",
      data = incomplete %>% dplyr::select(samp_name, eventDate, decimalLatitude, decimalLongitude),
      columns = c("eventDate", "decimalLatitude", "decimalLongitude")
    ))
  }

  # ---- 5. Config-level values with no source in the data at all ----------
  if (is.na(georeference_sources) || georeference_sources == "") {
    add_issue(list(
      id = "georeference_sources_missing",
      severity = "warning",
      title = "GPS/positioning system not specified",
      message = "What GPS or positioning system was used to record latitude/longitude for this project (e.g. a specific onboard unit, a handheld GPS)? This is required by OBIS to document how coordinates were determined (georeferenceSources).",
      fix_type = "config_question",
      field = "georeference_sources"
    ))
  }

  if (is.na(associated_sequences_uri) || associated_sequences_uri == "") {
    add_issue(list(
      id = "associated_sequences_missing",
      severity = "warning",
      title = "Raw sequence archive link not specified",
      message = "Where are the raw sequence reads for this project archived (e.g. an ENA or SRA project accession/link)? Leave blank if they haven't been deposited yet - a link to something not yet public shouldn't go in the published archive.",
      fix_type = "config_question",
      field = "associated_sequences_uri"
    ))
  }

  any_blocking <- any(vapply(issues, function(i) i$severity == "error", logical(1)))
  list(issues = issues, any_blocking = any_blocking)
}
