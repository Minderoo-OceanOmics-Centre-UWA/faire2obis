### R/build_event_core.R
#
# Refactored from scripts/01_build_event_core.R (that script is now a
# thin CLI wrapper around build_event_core() below). Pure function: no
# cat(), no write.csv() - the caller (CLI script or Shiny app) handles
# printing/writing and decides what to do with `messages`.
#
# See scripts/01_build_event_core.R for the full design rationale
# (comments trimmed here to avoid duplicating them).

build_event_id <- function(samp_name) {
  as.character(samp_name)
}

#' Build the Event core from a project's FAIRe sampleMetadata sheets.
#'
#' @param input_files Named list: assay name -> path to that assay's FAIRe .xlsx
#' @param event_core_source_assay Which assay's sampleMetadata is the source of truth;
#'   every other assay's sampleMetadata is cross-checked against it and must match exactly.
#' @param sample_category_keep The samp_category value marking a real (non-control) sample.
#' @param georeference_sources Constant value for the Event core's georeferenceSources
#'   field (e.g. the GPS/positioning system used to record coordinates). Left NA if not
#'   supplied - callers (including the Shiny app) should prompt for the real value rather
#'   than guess or leave a made-up placeholder.
#' @return list(event_core, controls, messages)
build_event_core <- function(input_files,
                              event_core_source_assay,
                              sample_category_keep,
                              georeference_sources = NA_character_) {
  messages <- character()
  log_msg <- function(...) messages <<- c(messages, paste0(...))

  log_msg("Reading sampleMetadata from ", length(input_files), " assay files...")
  sample_tables <- lapply(names(input_files), function(assay) {
    log_msg("  - ", assay)
    read_faire_sheet(input_files[[assay]], "sampleMetadata")
  })
  names(sample_tables) <- names(input_files)

  source_assay <- event_core_source_assay
  base_table <- sample_tables[[source_assay]]
  comparison_exclude <- c("assay_name")
  other_assays <- setdiff(names(sample_tables), source_assay)

  for (other in other_assays) {
    other_table <- sample_tables[[other]]

    common_cols <- intersect(
      setdiff(names(base_table), comparison_exclude),
      setdiff(names(other_table), comparison_exclude)
    )

    base_sub  <- base_table  %>% dplyr::select(dplyr::all_of(common_cols)) %>% dplyr::arrange(samp_name)
    other_sub <- other_table %>% dplyr::select(dplyr::all_of(common_cols)) %>% dplyr::arrange(samp_name)

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

    log_msg("  OK: ", other, " matches ", source_assay, " (", nrow(other_sub), " samples, ", length(common_cols), " shared columns)")
  }

  log_msg("All assay files agree on shared sample metadata. Proceeding with ", source_assay, " as source.")

  all_samples <- base_table %>% dplyr::mutate(eventID = build_event_id(samp_name))

  real_samples <- all_samples %>% dplyr::filter(samp_category == sample_category_keep)
  control_samples <- all_samples %>% dplyr::filter(samp_category != sample_category_keep)

  log_msg("Real samples (-> Event core): ", nrow(real_samples))
  log_msg("Control samples (-> controls/ reference file only): ", nrow(control_samples))

  event_core <- real_samples %>%
    dplyr::transmute(
      eventID,
      parentEventID = NA_character_,
      eventDate,
      # verbatimEventTime isn't a Darwin Core term, so it's merged into
      # verbatimEventDate. The FAIRe date can arrive as an Excel serial
      # number (e.g. "45450"), which is unreadable - convert it first.
      verbatimEventDate = trimws(paste(
        dplyr::if_else(
          grepl("^[0-9]+(\\.[0-9]+)?$", verbatimEventDate),
          format(as.Date(suppressWarnings(as.numeric(verbatimEventDate)), origin = "1899-12-30"), "%Y-%m-%d"),
          as.character(verbatimEventDate)
        ),
        dplyr::coalesce(as.character(verbatimEventTime), "")
      )),
      decimalLatitude = as.numeric(decimalLatitude),
      decimalLongitude = as.numeric(decimalLongitude),
      verbatimLatitude,
      verbatimLongitude,
      verbatimCoordinateSystem,
      verbatimSRS,
      locationID = site_id,
      locality = geo_loc_name,
      minimumDepthInMeters = as.numeric(minimumDepthInMeters),
      maximumDepthInMeters = as.numeric(maximumDepthInMeters),
      # samp_collect_method is unpopulated in some projects (e.g. OcOm_2408) -
      # the actual collection info lives in samp_collect_device instead.
      # Use whichever is populated rather than only samp_collect_method,
      # so samplingProtocol isn't silently blank.
      samplingProtocol = dplyr::coalesce(samp_collect_method, samp_collect_device),
      # Numeric-cast every measurement field explicitly, same as
      # decimalLatitude/decimalLongitude/depth above - read_faire_sheet()
      # reads with col_names = FALSE, so header/code rows mixed with
      # numeric data force these columns to character on load. The CLI
      # scripts never noticed because every step round-trips through a
      # CSV file, and readr re-infers a clean numeric type from the
      # written text; the Shiny app passes this data in memory with no
      # such round-trip, so obistools::flatten_occurrence() hit the real
      # type mismatch directly (sampleSizeValue character here vs.
      # numeric in the Occurrence extension) and crashed script 05/Step 5.
      sampleSizeValue  = as.numeric(samp_size),
      sampleSizeUnit   = samp_size_unit,
      habitat = dplyr::case_when(
        as.character(habitat_natural_artificial_0_1) == "0" ~ "natural",
        as.character(habitat_natural_artificial_0_1) == "1" ~ "artificial",
        TRUE ~ as.character(habitat_natural_artificial_0_1)
      ),
      waterTemperature = as.numeric(temp),
      salinity         = as.numeric(salinity),
      ph               = as.numeric(ph),
      dissolvedOxygen  = as.numeric(diss_oxygen),
      dissolvedOxygenUnit = diss_oxygen_unit,
      turbidity        = as.numeric(turbidity),
      tidal_stage,
      water_current,
      samp_weather,
      georeferenceSources = georeference_sources,
      eventRemarks = site_comments
    )

  # These measurement fields have no Event-core Darwin Core term - they
  # belong in an eMoF extension. Drop the ones that are entirely empty
  # (nothing to publish); warn if any are populated so they aren't lost.
  measurement_cols <- c("waterTemperature", "salinity", "ph", "dissolvedOxygen",
                        "dissolvedOxygenUnit", "turbidity", "tidal_stage",
                        "water_current", "samp_weather")
  empty_cols <- measurement_cols[vapply(measurement_cols, function(col) all(is.na(event_core[[col]])), logical(1))]
  populated_cols <- setdiff(measurement_cols, empty_cols)
  event_core <- event_core %>% dplyr::select(-dplyr::all_of(empty_cols))
  if (length(empty_cols) > 0) {
    log_msg("Dropped empty measurement columns from Event core: ", paste(empty_cols, collapse = ", "))
  }
  if (length(populated_cols) > 0) {
    log_msg("WARNING: these measurement columns contain data but have no Event-core Darwin Core term - ",
            "they need an eMoF extension: ", paste(populated_cols, collapse = ", "))
  }

  log_msg("Event core built: ", nrow(event_core), " rows, ", ncol(event_core), " columns")

  list(event_core = event_core, controls = control_samples, messages = messages)
}
