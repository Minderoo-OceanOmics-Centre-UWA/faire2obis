### R/eml_excel.R
#
# Excel round-trip for Step 6's metadata form: a template anyone can
# fill in offline (no need to use the web form directly), and a
# reader that feeds an uploaded, filled-in copy back into the app to
# auto-fill every field. Field keys below are deliberately the same
# string used after the "eml_" prefix on each Shiny input id in app.R
# (e.g. key "creator_given" <-> input$eml_creator_given), so the
# upload-and-autofill logic is a single small loop, not 30 special cases.
#
# Field types drive both how a value is written into Excel and which
# Shiny update*Input() function fills it back in:
#   text     - updateTextInput
#   textarea - updateTextAreaInput (value may contain embedded newlines)
#   date     - updateDateInput (expects/produces "YYYY-MM-DD")
#   logical  - updateCheckboxInput (Excel cell: TRUE/FALSE)
#   select   - updateSelectInput (value must be one of a fixed set - see
#              EML_LICENSE_CHOICES in app.R for "license"; PUBLISHER/
#              AUTHOR/PROCESSOR/EDITOR/REVIEWER/OWNER for "ap_role")

EML_FIELD_DEFS <- list(
  list(key = "title",             label = "Dataset title",                     type = "text"),
  list(key = "abstract",          label = "Abstract",                          type = "textarea", notes = "One paragraph per line"),
  list(key = "keywords",          label = "Keywords",                         type = "text",     notes = "Comma-separated"),
  list(key = "license",           label = "License URL",                       type = "select",   notes = "One of the exact CC license URLs FAIRe2OBIS offers"),
  list(key = "pub_date",          label = "Publication date",                  type = "date",     notes = "YYYY-MM-DD"),
  list(key = "distribution_url",  label = "Project/organization website",      type = "text",     notes = "Optional"),
  list(key = "org_name",          label = "Organization name",                 type = "text"),
  list(key = "org_address",       label = "Street address",                    type = "text"),
  list(key = "org_city",          label = "City",                              type = "text"),
  list(key = "org_admin_area",    label = "State/region",                      type = "text"),
  list(key = "org_country",       label = "Country code",                      type = "text",     notes = "e.g. AU"),
  list(key = "creator_given",     label = "Creator - given name",              type = "text"),
  list(key = "creator_sur",       label = "Creator - surname",                 type = "text"),
  list(key = "creator_position",  label = "Creator - position",                type = "text"),
  list(key = "creator_email",     label = "Creator - email",                   type = "text"),
  list(key = "mp_same",           label = "Metadata provider same as creator?", type = "logical"),
  list(key = "mp_given",          label = "Metadata provider - given name",    type = "text",     notes = "Only if not same as creator"),
  list(key = "mp_sur",            label = "Metadata provider - surname",       type = "text"),
  list(key = "mp_position",       label = "Metadata provider - position",      type = "text"),
  list(key = "mp_email",          label = "Metadata provider - email",         type = "text"),
  list(key = "contact_same",      label = "Contact same as creator?",          type = "logical"),
  list(key = "contact_given",     label = "Contact - given name",              type = "text",     notes = "Only if not same as creator"),
  list(key = "contact_sur",       label = "Contact - surname",                 type = "text"),
  list(key = "contact_position",  label = "Contact - position",                type = "text"),
  list(key = "contact_email",     label = "Contact - email",                   type = "text"),
  list(key = "ap_include",        label = "Include an associated party?",      type = "logical"),
  list(key = "ap_given",          label = "Associated party - given name",     type = "text",     notes = "Only if included"),
  list(key = "ap_sur",            label = "Associated party - surname",        type = "text"),
  list(key = "ap_position",       label = "Associated party - position",       type = "text"),
  list(key = "ap_email",          label = "Associated party - email",          type = "text"),
  list(key = "ap_role",           label = "Associated party - role",          type = "select",   notes = "PUBLISHER / AUTHOR / PROCESSOR / EDITOR / REVIEWER / OWNER"),
  list(key = "methods",           label = "Method steps",                      type = "textarea", notes = "One step per line, in order"),
  list(key = "study_extent",      label = "Study extent description",          type = "textarea"),
  list(key = "sampling_desc",     label = "Sampling description",              type = "textarea"),
  list(key = "project_id",        label = "Project ID",                        type = "text",     notes = "Leave blank to omit the whole Project section"),
  list(key = "project_title",     label = "Project title",                     type = "text"),
  list(key = "project_abstract",  label = "Project abstract",                  type = "textarea"),
  list(key = "funding",           label = "Funding",                          type = "textarea"),
  list(key = "study_area_desc",   label = "Study area description",           type = "textarea"),
  list(key = "design_desc",       label = "Design description",                type = "textarea")
)

#' Write the metadata Excel template (or a pre-filled copy, if `values` is given).
#'
#' @param path Output .xlsx path
#' @param values Optional named list: field key -> value, to pre-fill (e.g. from
#'   an existing eml.xml). Logical values may be TRUE/FALSE or "TRUE"/"FALSE".
write_eml_metadata_excel <- function(path, values = NULL) {
  df <- data.frame(
    Field = vapply(EML_FIELD_DEFS, function(f) f$label, character(1)),
    Value = vapply(EML_FIELD_DEFS, function(f) {
      v <- if (!is.null(values)) values[[f$key]] else NULL
      if (is.null(v) || (length(v) == 1 && is.na(v))) "" else paste(v, collapse = if (f$type %in% c("textarea")) "\n" else ", ")
    }, character(1)),
    Notes = vapply(EML_FIELD_DEFS, function(f) if (!is.null(f$notes)) f$notes else "", character(1)),
    key = vapply(EML_FIELD_DEFS, function(f) f$key, character(1)),
    stringsAsFactors = FALSE
  )

  wb <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb, "metadata")
  openxlsx::writeData(wb, "metadata", df[, c("Field", "Value", "Notes")])
  openxlsx::setColWidths(wb, "metadata", cols = 1:3, widths = c(32, 60, 40))
  wrap_style <- openxlsx::createStyle(wrapText = TRUE, valign = "top")
  openxlsx::addStyle(wb, "metadata", wrap_style, rows = 2:(nrow(df) + 1), cols = 2, gridExpand = TRUE)
  header_style <- openxlsx::createStyle(textDecoration = "bold", fgFill = "#eceae4")
  openxlsx::addStyle(wb, "metadata", header_style, rows = 1, cols = 1:3, gridExpand = TRUE)
  # A hidden 4th column keeps the field key next to its row, so the
  # reader below doesn't have to re-derive it from the (editable) label.
  openxlsx::writeData(wb, "metadata", data.frame(key = df$key), startCol = 4)
  openxlsx::setColWidths(wb, "metadata", cols = 4, hidden = TRUE)

  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  invisible(path)
}

#' Read a filled-in metadata Excel file back into a named list of values,
#' keyed the same way as EML_FIELD_DEFS (and thus the same as the "eml_"
#' Shiny input ids, minus the prefix).
#'
#' @param path Path to the uploaded .xlsx
#' @return Named list: field key -> value (character, or TRUE/FALSE for
#'   logical fields; missing/blank cells are omitted)
read_eml_metadata_excel <- function(path) {
  raw <- openxlsx::read.xlsx(path, sheet = 1, colNames = TRUE)
  if (!"key" %in% names(raw)) {
    stop("This file doesn't look like a FAIRe2OBIS metadata template - missing the hidden 'key' column (column D). Start from the downloaded template rather than a blank workbook.")
  }

  values <- list()
  for (i in seq_len(nrow(raw))) {
    key <- raw$key[i]
    def <- Filter(function(f) f$key == key, EML_FIELD_DEFS)
    if (length(def) == 0) next
    def <- def[[1]]

    val <- raw$Value[i]
    if (is.na(val) || !nzchar(trimws(as.character(val)))) next
    val <- gsub("\r\n", "\n", as.character(val))

    values[[key]] <- switch(def$type,
      logical = toupper(trimws(val)) %in% c("TRUE", "YES", "Y", "1"),
      val
    )
  }
  values
}
