### R/taxon_lookup.R
#
# In-app name checker for the Taxonomy Review step: look a name or an
# AphiaID up in WoRMS and show the record without leaving the app.
#
# WoRMS cannot be embedded in an iframe (its Content-Security-Policy
# frame-ancestors only allows VLIZ domains), so its record is fetched
# through the same worrms API the matching step already uses and shown
# natively. FishBase allows framing, so its species page is embedded.

worms_taxon_url <- function(aphia_id) {
  paste0("https://www.marinespecies.org/aphia.php?p=taxdetails&id=", aphia_id)
}

fishbase_species_url <- function(species_name) {
  if (is.na(species_name) || !grepl("^[A-Z][a-z-]+ [a-z-]+$", species_name)) return(NA_character_)
  paste0("https://www.fishbase.se/summary/", sub(" ", "-", species_name), ".html")
}

#' @param query A scientific name, or an AphiaID (digits only)
#' @return list(records = data.frame or NULL, best = 1-row data.frame or NULL,
#'   classification = tibble or NULL, fuzzy = logical, note = character)
lookup_taxon <- function(query) {
  query <- trimws(query)
  if (!nzchar(query)) return(list(records = NULL, note = "Type a scientific name or an AphiaID."))

  fuzzy <- FALSE
  if (grepl("^[0-9]+$", query)) {
    records <- tryCatch(worrms::wm_record(as.integer(query)), error = function(e) NULL)
  } else {
    records <- tryCatch(worrms::wm_records_name(query, fuzzy = FALSE, marine_only = FALSE), error = function(e) NULL)
    if (is.null(records) || nrow(records) == 0) {
      records <- tryCatch(worrms::wm_records_name(query, fuzzy = TRUE, marine_only = FALSE), error = function(e) NULL)
      fuzzy <- TRUE
    }
  }
  if (is.null(records) || nrow(records) == 0) {
    return(list(records = NULL, note = paste0("WoRMS has no record for \"", query, "\".")))
  }

  records <- as.data.frame(records)
  best <- records[order(records$status != "accepted"), ][1, , drop = FALSE]
  classification <- tryCatch(worrms::wm_classification(best$AphiaID), error = function(e) NULL)

  list(records = records, best = best, classification = classification, fuzzy = fuzzy, note = NULL)
}

.habitat_badges <- function(rec) {
  flags <- c(Marine = rec$isMarine, Brackish = rec$isBrackish, Freshwater = rec$isFreshwater, Terrestrial = rec$isTerrestrial)
  on <- names(flags)[!is.na(flags) & flags == 1]
  lapply(on, function(x) span(class = "badge bg-info-subtle text-info-emphasis me-1", x))
}

.status_badge <- function(status) {
  cls <- if (identical(status, "accepted")) "bg-success" else "bg-warning text-dark"
  span(class = paste("badge", cls), status)
}

#' Body of the "Check name" modal: a WoRMS tab (native) and a FishBase tab (embedded).
taxon_lookup_body <- function(res, query) {
  if (is.null(res$records)) {
    return(div(class = "alert alert-warning",
               res$note,
               " Check the spelling, or search WoRMS directly: ",
               tags$a(href = paste0("https://www.marinespecies.org/aphia.php?p=taxlist&tName=", utils::URLencode(query, reserved = TRUE)),
                      target = "_blank", rel = "noopener noreferrer", "open WoRMS search")))
  }

  recs <- utils::head(res$records, 25)
  best <- res$best

  worms_tab <- tagList(
    if (isTRUE(res$fuzzy)) div(class = "alert alert-warning py-2", "No exact match - these are WoRMS' closest (fuzzy) matches. Verify before using one."),
    if (!is.null(res$classification)) {
      div(class = "mb-3",
          div(class = "muted", "Classification of the top record"),
          div(paste(res$classification$scientificname, collapse = "  ›  ")))
    },
    tags$table(class = "table table-sm align-middle",
      tags$thead(tags$tr(tags$th("AphiaID"), tags$th("Name"), tags$th("Status"), tags$th("Rank"), tags$th("Habitat"), tags$th("Accepted name"), tags$th())),
      tags$tbody(lapply(seq_len(nrow(recs)), function(i) {
        r <- recs[i, ]
        tags$tr(
          tags$td(tags$code(r$AphiaID)),
          tags$td(tags$em(r$scientificname), " ", span(class = "muted", r$authority)),
          tags$td(.status_badge(r$status)),
          tags$td(r$rank),
          tags$td(.habitat_badges(r)),
          tags$td(if (!identical(r$status, "accepted")) paste0(r$valid_name, " (", r$valid_AphiaID, ")") else ""),
          tags$td(tags$a(href = worms_taxon_url(r$AphiaID), target = "_blank", rel = "noopener noreferrer", "WoRMS ↗"))
        )
      }))
    ),
    if (nrow(res$records) > nrow(recs)) p(class = "muted", paste0("Showing the first ", nrow(recs), " of ", nrow(res$records), " records."))
  )

  fb_name <- if (identical(best$rank, "Species")) best$valid_name else NA_character_
  fb_url <- fishbase_species_url(fb_name)

  fishbase_tab <- if (is.na(fb_url)) {
    div(class = "alert alert-secondary",
        "FishBase has pages for fish species only. The top WoRMS record here is not a species, so there is nothing to show. ",
        tags$a(href = "https://www.fishbase.se/search.php", target = "_blank", rel = "noopener noreferrer", "Search FishBase yourself ↗"))
  } else {
    tagList(
      div(class = "d-flex justify-content-between align-items-center mb-2",
          span(class = "muted", paste0("FishBase page for ", fb_name, ". If it says the species isn't found, it's not a fish.")),
          tags$a(href = fb_url, target = "_blank", rel = "noopener noreferrer", class = "btn btn-sm btn-outline-secondary", "Open in FishBase ↗")),
      tags$iframe(src = fb_url, loading = "lazy", referrerpolicy = "no-referrer",
                  sandbox = "allow-scripts allow-same-origin allow-popups allow-forms",
                  style = "width:100%; height:60vh; border:1px solid #eceae4; border-radius:10px;")
    )
  }

  bslib::navset_tab(
    bslib::nav_panel("WoRMS record", div(class = "pt-3", worms_tab)),
    bslib::nav_panel("FishBase", div(class = "pt-3", fishbase_tab))
  )
}
