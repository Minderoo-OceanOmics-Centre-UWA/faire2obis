### app.R
#
# FAIRe2OBIS - interactive web app.
#
# Wraps the same R/*.R functions the CLI pipeline (scripts/01-05) uses,
# in a guided, validated workflow instead of hand-editing config.R and
# running scripts one at a time. Deploy as-is to Posit Cloud / Connect /
# shinyapps.io - app.R sits at the repo root alongside R/ and config.R
# so relative paths (source("R/...")) work the same way they do for the
# CLI scripts, with no extra packaging step.
#
# Status: all seven steps are functional - Upload & Configure, Validate
# & Fix, Build Core Files, interactive WoRMS Taxonomy Review, QC
# Checks, Metadata (generates eml.xml), and Results & Download.
#
# UI architecture note: each step has its OWN persistent output
# (step2_body/step3_body via renderUI, step 1 fully static), shown or
# hidden with conditionalPanel rather than swapped in and out of a
# single shared output. A single shared "switch(current_step, ...)"
# output looked simpler at first but re-renders whichever step becomes
# active from scratch every time - which silently wiped file inputs
# (browsers won't let a re-rendered <input type="file"> keep its
# selection) and would have reset Step 3's dropdowns too, the moment
# Back/Restart navigation was added. Step 1's assay rows are managed
# with insertUI()/removeUI() against a static container div for the
# same reason: adding a row must never touch the DOM nodes of rows
# already there.

library(shiny)
library(bslib)
library(bsicons)
library(DT)
library(dplyr)
library(ggplot2)
library(zip)

source("R/faire_io.R")
source("R/validate_faire_files.R")
source("R/suggest_assay_mapping.R")
source("R/detect_assay_name.R")
source("R/build_event_core.R")
source("R/build_occurrence.R")
source("R/build_dna_extension.R")
source("R/worms_match.R")
source("R/qc_checks.R")
source("R/build_eml.R")
source("R/eml_excel.R")
source("R/archive_history.R")

# Converts a scientific name into a safe Shiny input-id fragment (no
# spaces/punctuation) for the Step 4 per-name review widgets.
safe_id <- function(x) gsub("[^A-Za-z0-9]", "_", x)

# Defined once, used both as the Step 6 license selectInput's choices
# (label = name, value = URL) and to look the label back up from the
# chosen URL when generating eml.xml.
EML_LICENSE_CHOICES <- c(
  "CC0 1.0 (Public Domain)" = "https://creativecommons.org/publicdomain/zero/1.0/legalcode",
  "CC-BY 4.0"               = "https://creativecommons.org/licenses/by/4.0/legalcode",
  "CC-BY-NC 4.0"            = "https://creativecommons.org/licenses/by-nc/4.0/legalcode"
)

# Shiny's default upload cap is 5MB - FAIRe workbooks with real ASV/OTU
# tables commonly run 10-20MB+. Raised to 100MB per file; adjust if a
# project's files run larger than that.
options(shiny.maxRequestSize = 100 * 1024^2)

# ---------------------------------------------------------------------
# Theme - same palette as the README charts (validated categorical/
# sequential blue, #2a78d6) for a consistent brand between the app and
# the docs.
# ---------------------------------------------------------------------
app_theme <- bs_theme(
  version      = 5,
  bg           = "#f9f9f7",
  fg           = "#0b0b0b",
  primary      = "#2a78d6",
  secondary    = "#898781",
  success      = "#0ca30c",
  warning      = "#fab219",
  danger       = "#d03b3b",
  base_font    = bslib::font_google("Inter"),
  heading_font = bslib::font_google("Inter"),
  "border-radius" = "0.65rem",
  "card-border-color" = "#eceae4"
)

STEPS <- c("Upload", "Validate", "Build", "Taxonomy", "QC Checks", "Metadata", "Results")
ACTIVE_STEPS <- 1:7  # all steps functional

app_css <- "
  body { background-color: #f9f9f7; }
  html, body { height: auto !important; overflow-y: auto !important; }

  /* Positioning context for the file-input scroll-jack fix in the
     <script> below (that fix has to happen in JS - Shiny's own
     fileInput ships an inline `!important` style that no CSS rule,
     however specific, can override). */
  .btn-file { position: relative; overflow: hidden; }

  .app-header {
    background: linear-gradient(135deg, #0b0b0b 0%, #16171a 100%);
    color: #ffffff; padding: 18px 36px; display: flex; align-items: center; gap: 14px;
  }
  .app-header .brand-mark {
    width: 38px; height: 38px; border-radius: 9px; background: #2a78d6;
    display: flex; align-items: center; justify-content: center; flex-shrink: 0;
    font-weight: 700; font-size: 1rem; color: #fff;
  }
  .app-header h1 { font-size: 1.32rem; font-weight: 700; margin: 0; letter-spacing: -0.01em; }
  .app-header p { color: #a9a89f; margin: 1px 0 0 0; font-size: 0.86rem; }
  .app-header .header-spacer { flex: 1; }
  .restart-btn { color: #c3c2b7 !important; border-color: #3a3a38 !important; }
  .restart-btn:hover { color: #fff !important; border-color: #d03b3b !important; background: rgba(208,59,59,0.15) !important; }

  .stepper-flex { display: flex; align-items: flex-start; padding: 26px 48px 22px 48px; background: #ffffff; border-bottom: 1px solid #eceae4; }
  .step-item { display: flex; flex-direction: column; align-items: center; }
  .step-circle {
    width: 34px; height: 34px; border-radius: 50%; display: flex; align-items: center; justify-content: center;
    font-weight: 700; font-size: 0.82rem; border: 2px solid #dedcd3; color: #a9a89f; background: #fff; transition: all .15s ease;
  }
  .step-circle.active { border-color: #2a78d6; background: #2a78d6; color: #fff; box-shadow: 0 0 0 5px rgba(42,120,214,0.14); }
  .step-circle.done { border-color: #0ca30c; background: #0ca30c; color: #fff; }
  .step-circle.disabled { border-color: #eceae4; color: #c3c2b7; }
  .step-label { font-size: 0.74rem; margin-top: 7px; color: #a9a89f; text-align: center; max-width: 84px; }
  .step-label.active { color: #0b0b0b; font-weight: 600; }
  .step-line { flex: 1; height: 2px; background: #eceae4; margin: 16px 6px 0 6px; }
  .step-line.done { background: #0ca30c; }

  .content-wrap { max-width: 880px; margin: 0 auto; padding: 32px 24px 70px 24px; }
  .card { box-shadow: 0 1px 2px rgba(11,11,11,0.03), 0 4px 10px rgba(11,11,11,0.03); margin-bottom: 18px; }
  .card-header { background: #fff; font-weight: 600; font-size: 0.94rem; padding: 14px 20px; display:flex; align-items:center; gap:8px; }
  .card-body { padding: 20px; }
  .section-icon { color: #2a78d6; }

  .issue-card { border-left: 4px solid #d03b3b; }
  .issue-card.warning { border-left-color: #fab219; }

  .assay-row { border: 1px solid #eceae4; border-radius: 10px; padding: 16px; margin-bottom: 12px; background: #fdfdfc; }
  .muted { color: #898781; font-size: 0.86rem; }
  .stat-box { border: 1px solid #eceae4; border-radius: 10px; padding: 16px 18px; text-align: center; background: #fff; }
  .stat-box .stat-value { font-size: 1.6rem; font-weight: 700; color: #0b0b0b; }
  .stat-box .stat-label { font-size: 0.78rem; color: #898781; margin-top: 2px; }

  .btn-primary { font-weight: 600; }
  h4, h5 { font-weight: 700; letter-spacing: -0.01em; }
  .nav-row { display: flex; justify-content: space-between; align-items: center; margin-top: 18px; }
"

# ---------------------------------------------------------------------
# One assay upload row's markup. Reused for the first row and for every
# row added via insertUI - each gets a stable id so it (and only it)
# can be removed later without touching its siblings.
# ---------------------------------------------------------------------
assay_row_ui <- function(i) {
  div(id = paste0("assay_row_", i), class = "assay-row",
      fluidRow(
        column(6, fileInput(paste0("assay_file_", i), "FAIRe .xlsx file", accept = ".xlsx")),
        column(5, textInput(paste0("assay_name_", i), "Assay name",
                             placeholder = "Auto-detected after upload - edit if you'd rather use a different name")),
        column(1, style = "padding-top: 32px;",
               actionButton(paste0("remove_assay_", i), bsicons::bs_icon("x-lg"), class = "btn-sm btn-outline-danger"))
      )
  )
}

# One Step 6 creator row's markup - same insertUI/removeUI pattern as
# assay_row_ui above (safe here because step6_body's renderUI has no
# reactive dependency and only ever runs once, so rows added later
# never get wiped out by a re-render). EML allows multiple <creator>
# elements per dataset. Each creator has their OWN organization/address
# fields (NOT the shared "Organization / address" block below, which is
# only for metadata provider/contact/associated party/project personnel)
# - real multi-author datasets commonly have co-authors at different
# institutions (e.g. a funder's staff alongside the university team).
creator_row_ui <- function(i) {
  div(id = paste0("creator_row_", i), class = "assay-row",
      fluidRow(
        column(3, textInput(paste0("eml_creator_given_", i), "Given name")),
        column(3, textInput(paste0("eml_creator_sur_", i), "Surname")),
        column(3, textInput(paste0("eml_creator_email_", i), "Email")),
        column(2, textInput(paste0("eml_creator_position_", i), "Position (optional)")),
        column(1, style = "padding-top: 32px;",
               actionButton(paste0("remove_creator_", i), bsicons::bs_icon("x-lg"), class = "btn-sm btn-outline-danger"))
      ),
      fluidRow(
        column(3, textInput(paste0("eml_creator_org_", i), "Organization (optional)")),
        column(3, textInput(paste0("eml_creator_address_", i), "Street address (optional)")),
        column(2, textInput(paste0("eml_creator_city_", i), "City (optional)")),
        column(2, textInput(paste0("eml_creator_admin_area_", i), "State/region (optional)")),
        column(1, textInput(paste0("eml_creator_country_", i), "Country")),
        column(1, textInput(paste0("eml_creator_phone_", i), "Phone"))
      )
  )
}

# One Step 6 project-personnel row's markup - same insertUI/removeUI
# pattern as creator_row_ui. Unlike creators, personnel SHARE the
# "Organization / address" block below (matches the reference sample:
# project personnel used the same UWA address as the associated party,
# not a separate one) - each row just needs its own name/position/
# email/role, since one project commonly lists several people in
# different roles (point of contact, curator, etc.).
personnel_row_ui <- function(i) {
  div(id = paste0("personnel_row_", i), class = "assay-row",
      fluidRow(
        column(3, textInput(paste0("eml_personnel_given_", i), "Given name")),
        column(3, textInput(paste0("eml_personnel_sur_", i), "Surname")),
        column(3, textInput(paste0("eml_personnel_email_", i), "Email")),
        column(2, textInput(paste0("eml_personnel_position_", i), "Position (optional)")),
        column(1, style = "padding-top: 32px;",
               actionButton(paste0("remove_personnel_", i), bsicons::bs_icon("x-lg"), class = "btn-sm btn-outline-danger"))
      ),
      fluidRow(
        column(3, textInput(paste0("eml_personnel_role_", i), "Role",
                             value = "POINT_OF_CONTACT", placeholder = "e.g. POINT_OF_CONTACT, CURATOR, AUTHOR"))
      )
  )
}

# One Step 6 associated-party row's markup - same pattern as
# personnel_row_ui (shares the "Organization / address" block). A
# dataset commonly credits several people here, each in a DIFFERENT
# role - the full role vocabulary EML/GBIF recognise is listed in the
# dropdown below so every "position type" this project might use
# (author, editor, reviewer, processor, curator, programmer, content
# provider, ...) is visible as an option, not just typed from memory.
ap_row_ui <- function(i) {
  div(id = paste0("ap_row_", i), class = "assay-row",
      fluidRow(
        column(3, textInput(paste0("eml_ap_given_", i), "Given name (optional)")),
        column(3, textInput(paste0("eml_ap_sur_", i), "Surname (optional)")),
        column(3, textInput(paste0("eml_ap_email_", i), "Email (optional)")),
        column(2, textInput(paste0("eml_ap_position_", i), "Position (optional)")),
        column(1, style = "padding-top: 32px;",
               actionButton(paste0("remove_ap_", i), bsicons::bs_icon("x-lg"), class = "btn-sm btn-outline-danger"))
      ),
      fluidRow(
        column(4, selectInput(paste0("eml_ap_role_", i), "Role", choices = c(
          "PUBLISHER", "AUTHOR", "CONTENT_PROVIDER", "CURATOR", "EDITOR",
          "OWNER", "POINT_OF_CONTACT", "PROCESSOR", "PROGRAMMER", "REVIEWER"
        )))
      )
  )
}

# =======================================================================
# UI
# =======================================================================
ui <- page_fluid(
  theme = app_theme,
  tags$head(
    tags$style(HTML(app_css)),
    # Shiny's own fileInput ships an INLINE style with !important
    # (position: absolute !important; top: -99999px !important) to
    # hide the native <input type=file> off-screen. Inline !important
    # beats anything in an external stylesheet, even with !important
    # there too - only JS can override an element's own inline style
    # at runtime, which is what causes the browser to try to scroll
    # that -99999px-positioned element into view on focus/click,
    # yanking the whole page to the top. Re-pin every file input to
    # sit inside its own (clipped, relatively-positioned) button
    # instead, on load and whenever Shiny binds a new one (covers
    # rows added later via insertUI too).
    tags$script(HTML("
      function fixFileInputPosition(el) {
        el.style.setProperty('position', 'absolute', 'important');
        el.style.setProperty('top', '0', 'important');
        el.style.setProperty('left', '0', 'important');
        el.style.setProperty('width', '100%', 'important');
        el.style.setProperty('height', '100%', 'important');
        el.style.setProperty('opacity', '0', 'important');
        var btn = el.closest('.btn-file');
        if (btn) { btn.style.position = 'relative'; btn.style.overflow = 'hidden'; }
      }
      document.addEventListener('shiny:bound', function(e) {
        var inp = e.target.querySelector ? e.target.querySelector('input[type=file]') : null;
        if (inp) fixFileInputPosition(inp);
      });
      document.addEventListener('DOMContentLoaded', function() {
        document.querySelectorAll('input[type=file]').forEach(fixFileInputPosition);
      });
    "))
  ),

  div(class = "app-header",
      div(class = "brand-mark", "F2O"),
      div(
        h1("FAIRe2OBIS"),
        p("Convert FAIRe eDNA metabarcoding data into an OBIS-ready Darwin Core Archive")
      ),
      div(class = "header-spacer"),
      actionButton("restart_app", tagList(bsicons::bs_icon("arrow-counterclockwise"), " Restart"),
                   class = "btn btn-outline-light btn-sm restart-btn")
  ),

  # Top-level tab bar: "Generate" (the step wizard) and "History" (past
  # archives, independent of wherever the wizard currently is) - the two
  # main sections of the app. History's own content lives in a dedicated
  # uiOutput (history_tab_body) so switching tabs never disturbs wizard
  # state, the same reasoning as each step having its own renderUI.
  navset_tab(
    id = "main_tab",
    nav_panel(
      "Generate",
      div(uiOutput("stepper_ui")),

      div(class = "content-wrap",
          # Step 1 is fully static (no renderUI) - its assay rows are
          # managed imperatively via insertUI/removeUI, and must never be
          # regenerated wholesale (see architecture note above).
          conditionalPanel(
            condition = "output.current_step_num == '1'",
            card(
              card_header(bsicons::bs_icon("folder2-open", class = "section-icon"), "Project"),
              card_body(
                textInput("project_id", "Project ID", value = "", placeholder = "e.g. OcOm_2408"),
                p(class = "muted", "Used as a label only at this stage - not yet embedded into output filenames.")
              )
            ),
            card(
              card_header(bsicons::bs_icon("file-earmark-spreadsheet", class = "section-icon"), "Assay files"),
              card_body(
                p(class = "muted", "Add one FAIRe .xlsx file per assay run on this project's samples. All assays must share the same physical samples."),
                div(id = "assay_rows_container", assay_row_ui(1)),
                actionButton("add_assay", tagList(bsicons::bs_icon("plus-lg"), " Add another assay"), class = "btn-outline-secondary btn-sm")
              )
            ),
            card(
              card_header(bsicons::bs_icon("sliders", class = "section-icon"), "Sample handling"),
              card_body(
                textInput("sample_category_keep", "Value of samp_category that marks a REAL (non-control) sample", value = "sample"),
                p(class = "muted", "Everything else (e.g. \"negative control\", \"positive control\") is excluded from the published archive.")
              )
            ),
            div(style = "text-align: right; margin-top: 10px;",
                actionButton("to_step2", tagList("Validate files ", bsicons::bs_icon("arrow-right")), class = "btn-primary")
            )
          ),

          conditionalPanel(condition = "output.current_step_num == '2'", uiOutput("step2_body")),
          conditionalPanel(condition = "output.current_step_num == '3'", uiOutput("step3_body")),
          conditionalPanel(condition = "output.current_step_num == '4'", uiOutput("step4_body")),
          conditionalPanel(condition = "output.current_step_num == '5'", uiOutput("step5_body")),
          conditionalPanel(condition = "output.current_step_num == '6'", uiOutput("step6_body")),
          conditionalPanel(condition = "output.current_step_num == '7'", uiOutput("step7_body"))
      )
    ),
    nav_panel(
      "History",
      div(class = "content-wrap", uiOutput("history_tab_body"))
    )
  )
)

# =======================================================================
# Server
# =======================================================================
server <- function(input, output, session) {

  rv <- reactiveValues(
    current_step    = 1,
    assay_ids       = c(1),   # currently-visible assay row ids, in order added
    next_assay_id   = 2,      # ever-increasing - ids are never reused
    creator_ids     = c(1),   # currently-visible Step 6 creator row ids, in order added
    next_creator_id = 2,      # ever-increasing - ids are never reused
    personnel_ids     = c(1), # currently-visible Step 6 project-personnel row ids
    next_personnel_id = 2,    # ever-increasing - ids are never reused
    ap_ids          = c(1),   # currently-visible Step 6 associated-party row ids (can go to zero - optional)
    next_ap_id      = 2,      # ever-increasing - ids are never reused
    validation      = NULL,
    answers         = list(georeference_sources = NA_character_, associated_sequences_uri = NA_character_),
    build_result    = NULL,   # list(event_core, controls, occurrence, dna_extension)
    build_error     = NULL,
    worms_result       = NULL,   # match_worms() output
    name_corrections   = character(),  # user-entered corrections for unmatched names, this session
    manual_aphia_overrides = c(),      # user-chosen AphiaIDs for ambiguous names, this session
    qc_result       = NULL,  # run_qc_checks() output
    eml_xml         = NULL   # build_eml_xml() output (Step 6)
  )

  # Bumped after a successful save_archive_to_s3() to invalidate the
  # Step 7 history table so a newly-generated archive shows up without
  # requiring a manual page refresh.
  history_refresh <- reactiveVal(0)

  output$current_step_num <- renderText({ as.character(rv$current_step) })
  outputOptions(output, "current_step_num", suspendWhenHidden = FALSE)

  # ---- Stepper --------------------------------------------------------
  output$stepper_ui <- renderUI({
    items <- list()
    for (i in seq_along(STEPS)) {
      state <- if (i %in% ACTIVE_STEPS && i < rv$current_step) "done"
                else if (i == rv$current_step) "active"
                else if (!(i %in% ACTIVE_STEPS)) "disabled"
                else "todo"
      circle_content <- if (state == "done") bsicons::bs_icon("check-lg") else as.character(i)
      items[[length(items) + 1]] <- div(
        class = "step-item",
        div(class = paste("step-circle", state), circle_content),
        div(class = paste("step-label", if (state == "active") "active" else ""), STEPS[i])
      )
      if (i < length(STEPS)) {
        line_state <- if (i %in% ACTIVE_STEPS && i < rv$current_step) "done" else "todo"
        items[[length(items) + 1]] <- div(class = paste("step-line", line_state))
      }
    }
    div(class = "stepper-flex", items)
  })

  # =====================================================================
  # STEP 1 - Upload & Configure (assay row management)
  # =====================================================================
  setup_remove_handler <- function(id) {
    local({
      this_id <- id
      observeEvent(input[[paste0("remove_assay_", this_id)]], {
        if (length(rv$assay_ids) <= 1) {
          showNotification("At least one assay is required.", type = "warning")
          return()
        }
        removeUI(selector = paste0("#assay_row_", this_id))
        rv$assay_ids <- setdiff(rv$assay_ids, this_id)
      }, ignoreInit = TRUE, once = TRUE)
    })
  }
  # Auto-detect the assay name from experimentRunMetadata$assay_name the
  # moment a file is uploaded into a row - pre-fills the name field but
  # leaves it fully editable, and only overwrites in response to a file
  # actually being (re-)chosen, never on its own.
  setup_assay_name_autodetect <- function(id) {
    local({
      this_id <- id
      observeEvent(input[[paste0("assay_file_", this_id)]], {
        file_val <- input[[paste0("assay_file_", this_id)]]
        req(file_val)
        detected <- tryCatch(detect_assay_name_combined(file_val$datapath, file_val$name), error = function(e) NA_character_)
        if (!is.na(detected)) {
          updateTextInput(session, paste0("assay_name_", this_id), value = detected)
        } else {
          showNotification(
            paste0("Couldn't auto-detect an assay name for this file - enter one manually."),
            type = "warning", duration = 4
          )
        }
      }, ignoreInit = TRUE)
    })
  }

  setup_remove_handler(1)          # the row already in the static UI
  setup_assay_name_autodetect(1)

  observeEvent(input$add_assay, {
    new_id <- rv$next_assay_id
    insertUI(selector = "#assay_rows_container", where = "beforeEnd", ui = assay_row_ui(new_id))
    setup_remove_handler(new_id)
    setup_assay_name_autodetect(new_id)
    rv$assay_ids <- c(rv$assay_ids, new_id)
    rv$next_assay_id <- new_id + 1
  })

  # ---- Step 6 creator row management (same insertUI/removeUI pattern) ----
  setup_creator_remove_handler <- function(id) {
    local({
      this_id <- id
      observeEvent(input[[paste0("remove_creator_", this_id)]], {
        if (length(rv$creator_ids) <= 1) {
          showNotification("At least one creator is required.", type = "warning")
          return()
        }
        removeUI(selector = paste0("#creator_row_", this_id))
        rv$creator_ids <- setdiff(rv$creator_ids, this_id)
      }, ignoreInit = TRUE, once = TRUE)
    })
  }
  setup_creator_remove_handler(1)  # the row already in the static UI

  observeEvent(input$add_creator, {
    new_id <- rv$next_creator_id
    insertUI(selector = "#creator_rows_container", where = "beforeEnd", ui = creator_row_ui(new_id))
    setup_creator_remove_handler(new_id)
    rv$creator_ids <- c(rv$creator_ids, new_id)
    rv$next_creator_id <- new_id + 1
  })

  # Rebuilds the creator rows to match a freshly-uploaded metadata Excel's
  # "creators" sheet: clears every row but the first (kept and reused so
  # there's always at least one), adds however many more are needed, then
  # returns the id list so the caller can updateTextInput() each one.
  set_creator_rows <- function(n) {
    for (id in setdiff(rv$creator_ids, 1)) removeUI(selector = paste0("#creator_row_", id))
    rv$creator_ids <- c(1)
    n <- max(n, 1)
    while (length(rv$creator_ids) < n) {
      new_id <- rv$next_creator_id
      insertUI(selector = "#creator_rows_container", where = "beforeEnd", ui = creator_row_ui(new_id))
      setup_creator_remove_handler(new_id)
      rv$creator_ids <- c(rv$creator_ids, new_id)
      rv$next_creator_id <- new_id + 1
    }
    rv$creator_ids
  }

  # ---- Step 6 project-personnel row management (same pattern again) -----
  setup_personnel_remove_handler <- function(id) {
    local({
      this_id <- id
      observeEvent(input[[paste0("remove_personnel_", this_id)]], {
        if (length(rv$personnel_ids) <= 1) {
          showNotification("At least one person is required (or remove the Project ID to omit personnel entirely).", type = "warning")
          return()
        }
        removeUI(selector = paste0("#personnel_row_", this_id))
        rv$personnel_ids <- setdiff(rv$personnel_ids, this_id)
      }, ignoreInit = TRUE, once = TRUE)
    })
  }
  setup_personnel_remove_handler(1)

  observeEvent(input$add_personnel, {
    new_id <- rv$next_personnel_id
    insertUI(selector = "#personnel_rows_container", where = "beforeEnd", ui = personnel_row_ui(new_id))
    setup_personnel_remove_handler(new_id)
    rv$personnel_ids <- c(rv$personnel_ids, new_id)
    rv$next_personnel_id <- new_id + 1
  })

  set_personnel_rows <- function(n) {
    for (id in setdiff(rv$personnel_ids, 1)) removeUI(selector = paste0("#personnel_row_", id))
    rv$personnel_ids <- c(1)
    n <- max(n, 1)
    while (length(rv$personnel_ids) < n) {
      new_id <- rv$next_personnel_id
      insertUI(selector = "#personnel_rows_container", where = "beforeEnd", ui = personnel_row_ui(new_id))
      setup_personnel_remove_handler(new_id)
      rv$personnel_ids <- c(rv$personnel_ids, new_id)
      rv$next_personnel_id <- new_id + 1
    }
    rv$personnel_ids
  }

  # ---- Step 6 associated-party row management (same pattern, but this
  # one is allowed to go all the way to ZERO rows - associated parties
  # are fully optional, unlike creators/personnel) ----------------------
  setup_ap_remove_handler <- function(id) {
    local({
      this_id <- id
      observeEvent(input[[paste0("remove_ap_", this_id)]], {
        removeUI(selector = paste0("#ap_row_", this_id))
        rv$ap_ids <- setdiff(rv$ap_ids, this_id)
      }, ignoreInit = TRUE, once = TRUE)
    })
  }
  setup_ap_remove_handler(1)

  observeEvent(input$add_ap, {
    new_id <- rv$next_ap_id
    insertUI(selector = "#ap_rows_container", where = "beforeEnd", ui = ap_row_ui(new_id))
    setup_ap_remove_handler(new_id)
    rv$ap_ids <- c(rv$ap_ids, new_id)
    rv$next_ap_id <- new_id + 1
  })

  # Removes every currently-visible row (whatever ids they happen to be -
  # row 1 might already be gone, since ap rows can be removed down to
  # zero) and inserts exactly `n` fresh ones with new ids. Simpler and
  # more robust than reusing id 1 specially, which only worked for
  # creators/personnel because those can never be removed below one.
  set_ap_rows <- function(n) {
    for (id in rv$ap_ids) removeUI(selector = paste0("#ap_row_", id))
    rv$ap_ids <- integer(0)
    while (length(rv$ap_ids) < n) {
      new_id <- rv$next_ap_id
      insertUI(selector = "#ap_rows_container", where = "beforeEnd", ui = ap_row_ui(new_id))
      setup_ap_remove_handler(new_id)
      rv$ap_ids <- c(rv$ap_ids, new_id)
      rv$next_ap_id <- new_id + 1
    }
    rv$ap_ids
  }

  get_input_files <- reactive({
    files <- list()
    for (i in rv$assay_ids) {
      name_val <- input[[paste0("assay_name_", i)]]
      file_val <- input[[paste0("assay_file_", i)]]
      if (!is.null(name_val) && nzchar(name_val) && !is.null(file_val)) {
        files[[name_val]] <- file_val$datapath
      }
    }
    files
  })

  observeEvent(input$to_step2, {
    input_files <- get_input_files()

    if (length(input_files) == 0) {
      showNotification("Upload at least one assay file with a name before continuing.", type = "error")
      return()
    }

    withProgress(message = "Validating uploaded files...", value = 0.3, {
      rv$validation <- tryCatch(
        validate_faire_files(
          input_files               = input_files,
          sample_category_keep      = input$sample_category_keep,
          georeference_sources      = rv$answers$georeference_sources,
          associated_sequences_uri  = rv$answers$associated_sequences_uri
        ),
        error = function(e) {
          showNotification(paste("Validation error:", conditionMessage(e)), type = "error", duration = NULL)
          NULL
        }
      )
      incProgress(0.7)
    })

    if (!is.null(rv$validation)) rv$current_step <- 2
  })

  # =====================================================================
  # STEP 2 - Validate & Fix
  # =====================================================================
  output$step2_body <- renderUI({
    if (is.null(rv$validation)) return(p("Run validation from Step 1 first."))

    issues <- rv$validation$issues
    if (length(issues) == 0) {
      return(tagList(
        div(class = "alert alert-success d-flex align-items-center gap-2",
            bsicons::bs_icon("check-circle-fill"), "All checks passed - no missing fields or inconsistencies found."),
        div(class = "nav-row",
            actionButton("back_to_1_from_2", tagList(bsicons::bs_icon("arrow-left"), " Back"), class = "btn-outline-secondary"),
            actionButton("to_step3", tagList("Continue ", bsicons::bs_icon("arrow-right")), class = "btn-primary"))
      ))
    }

    tagList(
      lapply(issues, render_issue_card),
      div(class = "nav-row",
          actionButton("back_to_1_from_2", tagList(bsicons::bs_icon("arrow-left"), " Back"), class = "btn-outline-secondary"),
          div(
            actionButton("revalidate", tagList(bsicons::bs_icon("arrow-repeat"), " Re-check"), class = "btn-outline-secondary"),
            actionButton("to_step3", tagList("Continue ", bsicons::bs_icon("arrow-right")), class = "btn-primary",
                         disabled = if (isTRUE(rv$validation$any_blocking)) "disabled" else NULL)
          )
      ),
      if (isTRUE(rv$validation$any_blocking))
        p(class = "muted", style = "text-align: right;", "Resolve the error(s) above before continuing.")
    )
  })

  render_issue_card <- function(issue) {
    card(
      class = paste("issue-card", if (issue$severity == "warning") "warning" else ""),
      card_body(
        span(class = if (issue$severity == "error") "badge bg-danger" else "badge bg-warning text-dark",
             toupper(issue$severity)),
        h5(issue$title, style = "margin-top: 8px;"),
        p(issue$message),
        if (issue$fix_type == "config_question") {
          tagList(
            textInput(paste0("answer_", issue$id), NULL,
                      value = rv$answers[[issue$field]] %||% "",
                      placeholder = "Type your answer here", width = "100%"),
            actionButton(paste0("save_", issue$id), "Save answer", class = "btn-sm btn-primary")
          )
        } else if (issue$fix_type == "data_table") {
          tagList(
            DTOutput(paste0("table_", issue$id)),
            p(class = "muted", "Double-click a cell to edit it, then click Re-check above.")
          )
        } else {
          NULL
        }
      )
    )
  }

  observe({
    req(rv$validation)
    for (issue in rv$validation$issues) {
      if (issue$fix_type == "data_table") {
        local({
          this_issue <- issue
          tbl_id <- paste0("table_", this_issue$id)
          output[[tbl_id]] <- renderDT({
            datatable(this_issue$data, editable = TRUE, rownames = FALSE,
                      options = list(pageLength = 10, dom = "tp"))
          })
          proxy <- dataTableProxy(tbl_id)
          observeEvent(input[[paste0(tbl_id, "_cell_edit")]], {
            edit <- input[[paste0(tbl_id, "_cell_edit")]]
            new_data <- this_issue$data
            new_data[edit$row, edit$col + 1] <- edit$value
            replaceData(proxy, new_data, resetPaging = FALSE, rownames = FALSE)
          })
        })
      }
    }
  })

  observe({
    req(rv$validation)
    for (issue in rv$validation$issues) {
      if (issue$fix_type == "config_question") {
        local({
          this_issue <- issue
          observeEvent(input[[paste0("save_", this_issue$id)]], {
            val <- input[[paste0("answer_", this_issue$id)]]
            rv$answers[[this_issue$field]] <- val
            showNotification(paste0("Saved: ", this_issue$field), type = "message", duration = 2)
          }, ignoreInit = TRUE)
        })
      }
    }
  })

  observeEvent(input$revalidate, {
    withProgress(message = "Re-checking...", value = 0.3, {
      rv$validation <- validate_faire_files(
        input_files               = get_input_files(),
        sample_category_keep      = input$sample_category_keep,
        georeference_sources      = rv$answers$georeference_sources,
        associated_sequences_uri  = rv$answers$associated_sequences_uri
      )
      incProgress(0.7)
    })
  })

  observeEvent(input$back_to_1_from_2, { rv$current_step <- 1 })
  observeEvent(input$to_step3, { rv$current_step <- 3 })

  # =====================================================================
  # STEP 3 - Build Core Files
  # =====================================================================
  project_meta_raw <- reactive({
    input_files <- get_input_files()
    req(length(input_files) > 0)
    tryCatch(readxl::read_excel(input_files[[1]], sheet = "projectMetadata", col_names = TRUE), error = function(e) NULL)
  })

  project_meta_preview <- reactive({
    pm <- project_meta_raw()
    req(!is.null(pm))

    assay_cols <- grep("^assay[0-9]+$", names(pm), value = TRUE)
    preview_fields <- c("target_gene", "pcr_primer_name_forward", "pcr_primer_name_reverse")

    preview <- lapply(assay_cols, function(col) {
      vals <- vapply(preview_fields, function(f) {
        row <- pm[pm$term_name == f, ]
        if (nrow(row) == 0 || is.na(row[[col]][1]) || row[[col]][1] == "") "-" else as.character(row[[col]][1])
      }, character(1))
      paste0(names(vals), ": ", vals, collapse = "  |  ")
    })
    names(preview) <- assay_cols
    preview
  })

  output$step3_body <- renderUI({
    input_files <- get_input_files()
    if (length(input_files) == 0) return(p("Go back to Step 1 and upload files first."))

    preview <- tryCatch(project_meta_preview(), error = function(e) NULL)
    pm <- tryCatch(project_meta_raw(), error = function(e) NULL)

    tagList(
      card(
        card_header(bsicons::bs_icon("diagram-3", class = "section-icon"), "Which assay's sampleMetadata is the source of truth?"),
        card_body(
          p(class = "muted", "Every other assay's sampleMetadata is cross-checked against this one and must match exactly (same physical samples)."),
          selectInput("event_core_source_assay", NULL, choices = names(input_files))
        )
      ),
      card(
        card_header(bsicons::bs_icon("link-45deg", class = "section-icon"), "Map each assay to its projectMetadata column(s)"),
        card_body(
          p(class = "muted", "projectMetadata stores PCR/primer/sequencing details per assay column (assay1, assay2, ...). Matches are suggested below by comparing each assay's name against the primer/gene names shown - review and adjust, don't just accept blindly."),
          if (is.null(preview)) {
            div(class = "alert alert-warning", "Could not read projectMetadata from the first uploaded file - check it has that sheet.")
          } else {
            tagList(lapply(names(input_files), function(assay) {
              suggested <- if (!is.null(pm)) suggest_assay_columns(assay, pm) else character()
              div(class = "assay-row",
                  div(class = "d-flex align-items-center gap-2",
                      strong(assay),
                      if (length(suggested) > 0) {
                        span(class = "badge bg-primary-subtle text-primary-emphasis",
                             bsicons::bs_icon("stars"), " Suggested - please verify")
                      }
                  ),
                  selectizeInput(paste0("map_", assay), NULL,
                                  choices = setNames(names(preview), paste0(names(preview), "  (", unlist(preview), ")")),
                                  selected = suggested,
                                  multiple = TRUE)
              )
            }))
          }
        )
      ),
      div(class = "nav-row", style = "margin-bottom: 18px;",
          actionButton("back_to_2_from_3", tagList(bsicons::bs_icon("arrow-left"), " Back"), class = "btn-outline-secondary"),
          actionButton("do_build", tagList(bsicons::bs_icon("gear-fill"), " Build Event core, Occurrence & DNA extensions"), class = "btn-primary")
      ),
      uiOutput("build_results")
    )
  })

  observeEvent(input$back_to_2_from_3, { rv$current_step <- 2 })

  observeEvent(input$do_build, {
    input_files <- get_input_files()
    assay_project_column <- setNames(
      lapply(names(input_files), function(a) input[[paste0("map_", a)]]),
      names(input_files)
    )
    if (any(vapply(assay_project_column, length, integer(1)) == 0)) {
      showNotification("Map every assay to at least one projectMetadata column before building.", type = "error")
      return()
    }

    rv$build_error <- NULL
    withProgress(message = "Building archive files...", value = 0.1, {
      result <- tryCatch({
        incProgress(0.1, detail = "Event core")
        ec <- build_event_core(
          input_files             = input_files,
          event_core_source_assay = input$event_core_source_assay,
          sample_category_keep    = input$sample_category_keep,
          georeference_sources    = rv$answers$georeference_sources
        )

        incProgress(0.3, detail = "Occurrence extensions")
        real_event_ids <- ec$event_core$eventID
        occ <- build_occurrence(
          input_files              = input_files,
          real_event_ids           = real_event_ids,
          associated_sequences_uri = rv$answers$associated_sequences_uri
        )

        incProgress(0.4, detail = "DNA Derived Data extensions")
        dna <- build_dna_extension(
          input_files              = input_files,
          occurrence_tables        = occ$occurrence,
          event_core               = ec$event_core,
          assay_project_column     = assay_project_column,
          associated_sequences_uri = rv$answers$associated_sequences_uri
        )
        incProgress(0.2)

        list(event_core = ec$event_core, controls = ec$controls, occurrence = occ$occurrence, dna_extension = dna$dna_extension)
      }, error = function(e) {
        rv$build_error <- conditionMessage(e)
        NULL
      })
    })

    if (!is.null(result)) {
      rv$build_result <- result
      # A rebuild invalidates any taxonomy matching / QC results
      # computed against the old data - clear them so Step 4/5 show a
      # fresh "run" prompt instead of a stale result from before.
      rv$worms_result <- NULL
      rv$qc_result     <- NULL
      showNotification("Build complete.", type = "message")
    }
  })

  output$build_results <- renderUI({
    if (!is.null(rv$build_error)) {
      return(div(class = "alert alert-danger", strong("Build failed: "), rv$build_error))
    }
    req(rv$build_result)
    r <- rv$build_result

    stat_box <- function(value, label) div(class = "stat-box", div(class = "stat-value", format(value, big.mark = ",")), div(class = "stat-label", label))

    tagList(
      card(
        card_header(bsicons::bs_icon("check-circle", class = "section-icon"), "Build results"),
        card_body(
          div(class = "d-flex flex-wrap gap-3",
              stat_box(nrow(r$event_core), "Event core rows"),
              stat_box(nrow(r$controls), "Controls excluded"),
              lapply(names(r$occurrence), function(a) stat_box(nrow(r$occurrence[[a]]), paste0(a, " detections")))
          )
        )
      ),
      div(style = "text-align: right;",
          actionButton("to_step4", tagList("Continue to Taxonomy Review ", bsicons::bs_icon("arrow-right")), class = "btn-primary")
      )
    )
  })

  observeEvent(input$to_step4, { rv$current_step <- 4 })

  # =====================================================================
  # STEP 4 - Taxonomy Review (interactive WoRMS matching)
  # =====================================================================
  run_worms_matching <- function() {
    req(rv$build_result)
    withProgress(message = "Matching scientific names against WoRMS...", value = 0.2, {
      result <- tryCatch(
        match_worms(
          occurrence_tables      = rv$build_result$occurrence,
          name_corrections       = rv$name_corrections,
          manual_aphia_overrides = rv$manual_aphia_overrides
        ),
        error = function(e) {
          showNotification(paste("WoRMS matching failed:", conditionMessage(e)), type = "error", duration = NULL)
          NULL
        }
      )
      incProgress(0.8)
    })
    if (!is.null(result)) {
      rv$worms_result <- result
      # Any change to taxonomy matching invalidates a previously-run QC
      # result - clear it so Step 5 re-checks fresh instead of silently
      # showing a stale pass/fail from before this change.
      rv$qc_result <- NULL
    }
  }

  observeEvent(input$run_worms, { run_worms_matching() })

  output$step4_body <- renderUI({
    req(rv$build_result)

    if (is.null(rv$worms_result)) {
      all_names <- unique(unlist(lapply(rv$build_result$occurrence, function(x) x$scientificName)))
      n_names <- length(all_names[!is.na(all_names)])
      return(tagList(
        card(
          card_header(bsicons::bs_icon("search", class = "section-icon"), "Match scientific names against WoRMS"),
          card_body(
            p(class = "muted", paste0(n_names, " unique scientific name(s) will be matched against the World Register of Marine Species. Ambiguous or unmatched names will be shown here for you to resolve - nothing is guessed.")),
            actionButton("run_worms", tagList(bsicons::bs_icon("play-fill"), " Run WoRMS matching"), class = "btn-primary")
          )
        ),
        div(class = "nav-row", actionButton("back_to_3_from_4", tagList(bsicons::bs_icon("arrow-left"), " Back"), class = "btn-outline-secondary"), div())
      ))
    }

    r <- rv$worms_result
    ambiguous_names <- unique(r$ambiguous_df$queriedName)
    unmatched_names <- r$unmatched_names
    n_matched <- length(unique(r$matched_df$queriedName))
    n_auto <- length(unique(r$resolved_ambiguous_df$queriedName))

    stat_box <- function(value, label) div(class = "stat-box", div(class = "stat-value", value), div(class = "stat-label", label))

    tagList(
      card(
        card_header(bsicons::bs_icon("bar-chart-fill", class = "section-icon"), "Matching summary"),
        card_body(
          div(class = "d-flex flex-wrap gap-3",
              stat_box(n_matched, "Matched"),
              stat_box(n_auto, "Auto-resolved"),
              stat_box(length(ambiguous_names), "Need your review"),
              stat_box(length(unmatched_names), "Unmatched"),
              stat_box(nrow(r$non_marine_df), "Flagged non-marine")
          )
        )
      ),

      if (length(ambiguous_names) > 0) {
        card(
          class = "issue-card",
          card_header(bsicons::bs_icon("question-circle", class = "section-icon"), "Ambiguous names - pick the correct WoRMS record"),
          card_body(
            p(class = "muted", "WoRMS returned more than one candidate with no single clearly-accepted record among them. Pick the correct one below, or leave it unresolved."),
            tagList(lapply(ambiguous_names, function(nm) {
              cand <- r$ambiguous_df %>% filter(queriedName == nm)
              choices <- setNames(
                as.character(cand$AphiaID),
                paste0(cand$AphiaID, " — ", cand$scientificname, " (", cand$status, ", ", cand$rank, ", marine=", cand$isMarine, ")")
              )
              div(class = "assay-row",
                  strong(nm),
                  selectInput(paste0("choose_aphia_", safe_id(nm)), NULL, choices = c("Leave unresolved" = "", choices))
              )
            }))
          )
        )
      },

      if (length(unmatched_names) > 0) {
        card(
          class = "issue-card warning",
          card_header(bsicons::bs_icon("exclamation-circle", class = "section-icon"), "Unmatched names - try a correction"),
          card_body(
            p(class = "muted", "No WoRMS record found at all. Where possible, a correction is pre-filled below using WoRMS' own fuzzy-match (typo-tolerant) service, followed through to the current accepted name - review it, it's a suggestion, not a fact. Otherwise check for a contaminated name (voucher/accession code attached to a genus), or leave it blank to publish without a scientificNameID."),
            tagList(lapply(unmatched_names, function(nm) {
              suggestion <- r$suggested_corrections[[nm]]
              has_suggestion <- !is.null(suggestion) && !is.na(suggestion)
              div(class = "assay-row",
                  div(class = "d-flex align-items-center gap-2",
                      strong(nm),
                      if (has_suggestion) {
                        span(class = "badge bg-primary-subtle text-primary-emphasis",
                             bsicons::bs_icon("stars"), " Suggested via WoRMS fuzzy match - please verify")
                      }
                  ),
                  textInput(paste0("correct_name_", safe_id(nm)), NULL,
                            value = if (has_suggestion) suggestion else "",
                            placeholder = "Corrected name to try instead (leave blank to skip)")
              )
            }))
          )
        )
      },

      if (nrow(r$non_marine_df) > 0) {
        card(
          card_header(bsicons::bs_icon("flag", class = "section-icon"), "Flagged non-marine (review before publishing)"),
          card_body(
            p(class = "muted", "OBIS may drop these unless their marine status is confirmed correct - check WoRMS/IRMNG."),
            tableOutput("non_marine_table")
          )
        )
      },

      div(class = "nav-row",
          actionButton("back_to_3_from_4", tagList(bsicons::bs_icon("arrow-left"), " Back"), class = "btn-outline-secondary"),
          div(
            if (length(ambiguous_names) > 0 || length(unmatched_names) > 0) {
              actionButton("apply_corrections", tagList(bsicons::bs_icon("arrow-repeat"), " Apply & re-check"), class = "btn-outline-secondary")
            },
            actionButton("to_step5", tagList("Continue to QC Checks ", bsicons::bs_icon("arrow-right")), class = "btn-primary")
          )
      )
    )
  })

  output$non_marine_table <- renderTable({
    req(rv$worms_result)
    rv$worms_result$non_marine_df %>% select(queriedName, worms_valid_name, worms_status, worms_rank)
  })

  observeEvent(input$apply_corrections, {
    req(rv$worms_result)
    r <- rv$worms_result
    ambiguous_names <- unique(r$ambiguous_df$queriedName)
    unmatched_names <- r$unmatched_names

    for (nm in ambiguous_names) {
      val <- input[[paste0("choose_aphia_", safe_id(nm))]]
      if (!is.null(val) && nzchar(val)) rv$manual_aphia_overrides[nm] <- as.integer(val)
    }
    for (nm in unmatched_names) {
      val <- input[[paste0("correct_name_", safe_id(nm))]]
      if (!is.null(val) && nzchar(val)) rv$name_corrections[nm] <- val
    }
    run_worms_matching()
  })

  observeEvent(input$back_to_3_from_4, { rv$current_step <- 3 })
  observeEvent(input$to_step5, { rv$current_step <- 5 })

  # =====================================================================
  # STEP 5 - QC Checks
  # =====================================================================
  run_qc <- function() {
    req(rv$build_result, rv$worms_result)
    withProgress(message = "Running QC checks...", value = 0.3, {
      result <- tryCatch(
        run_qc_checks(rv$build_result$event_core, rv$worms_result$occurrence_tables, rv$build_result$dna_extension),
        error = function(e) {
          showNotification(paste("QC checks failed:", conditionMessage(e)), type = "error", duration = NULL)
          NULL
        }
      )
      incProgress(0.7)
    })
    if (!is.null(result)) rv$qc_result <- result
  }

  observeEvent(input$run_qc, { run_qc() })

  output$step5_body <- renderUI({
    req(rv$build_result, rv$worms_result)

    if (is.null(rv$qc_result)) {
      return(tagList(
        card(
          card_header(bsicons::bs_icon("clipboard-check", class = "section-icon"), "Run QC checks"),
          card_body(
            p(class = "muted", "Runs obistools' validation checks against the finished archive - required fields, date/coordinate sanity, and cross-file ID consistency - before anything is downloaded."),
            actionButton("run_qc", tagList(bsicons::bs_icon("play-fill"), " Run QC checks"), class = "btn-primary")
          )
        ),
        div(class = "nav-row", actionButton("back_to_4_from_5", tagList(bsicons::bs_icon("arrow-left"), " Back"), class = "btn-outline-secondary"), div())
      ))
    }

    qc <- rv$qc_result
    r <- qc$results

    fields_ok <- all(vapply(names(r)[grepl("^check_fields_", names(r))], function(k) nrow(r[[k]]) == 0, logical(1)))
    ext_ok <- all(vapply(names(r)[grepl("^check_extension_eventids_", names(r))], function(k) {
      x <- r[[k]]; length(x) == 0 || (is.data.frame(x) && nrow(x) == 0) || all(is.na(x))
    }, logical(1)))
    crosscheck_ok <- all(vapply(r$occ_dna_crosscheck, function(x) length(x$missing_in_dna) == 0 && length(x$missing_in_occ) == 0, logical(1)))
    coverage_ok <- all(vapply(r$scientificname_coverage, function(x) x$missing == 0, logical(1)))

    checklist <- list(
      list(label = "Required Darwin Core fields present (Event + Occurrence)", passed = fields_ok),
      list(label = "eventID unique in Event core; parentEventID valid", passed = nrow(r$check_eventids) == 0),
      list(label = "eventDate format valid", passed = nrow(r$check_eventdate) == 0),
      list(label = "No coordinates on land", passed = nrow(r$check_onland) == 0),
      list(label = "No zero, missing, or out-of-range coordinates", passed = nrow(r$coord_out_of_range) == 0),
      list(label = "Every Occurrence/DNA row's eventID exists in the Event core", passed = ext_ok),
      list(label = "Occurrence ↔ DNA Derived Data occurrenceID consistency", passed = crosscheck_ok),
      list(label = "100% scientificNameID coverage", passed = coverage_ok)
    )

    check_row <- function(item) {
      div(class = "d-flex align-items-center gap-2", style = "padding: 7px 0;",
          if (item$passed) bsicons::bs_icon("check-circle-fill", class = "text-success") else bsicons::bs_icon("x-circle-fill", class = "text-danger"),
          item$label)
    }

    tagList(
      card(
        card_header(bsicons::bs_icon("clipboard-check", class = "section-icon"), "QC results"),
        card_body(
          lapply(checklist, check_row),
          if (length(qc$any_skipped) > 0) {
            div(class = "alert alert-warning", style = "margin-top: 12px;",
                strong("Not verified: "), paste(qc$any_skipped, collapse = "; "))
          }
        )
      ),
      if (!qc$any_failures) {
        div(class = "alert alert-success d-flex align-items-center gap-2",
            bsicons::bs_icon("check-circle-fill"), "All runnable checks passed. Still worth spot-checking a sample of rows before publishing.")
      } else {
        div(class = "alert alert-danger d-flex align-items-center gap-2",
            bsicons::bs_icon("exclamation-triangle-fill"), "Some checks failed - review above. You can still continue to see results, but resolve these before publishing.")
      },
      div(class = "nav-row",
          actionButton("back_to_4_from_5", tagList(bsicons::bs_icon("arrow-left"), " Back"), class = "btn-outline-secondary"),
          div(
            actionButton("rerun_qc", tagList(bsicons::bs_icon("arrow-repeat"), " Re-check"), class = "btn-outline-secondary"),
            actionButton("to_step6", tagList("Continue to Results ", bsicons::bs_icon("arrow-right")), class = "btn-primary")
          )
      )
    )
  })

  observeEvent(input$rerun_qc, { run_qc() })

  observeEvent(input$back_to_4_from_5, { rv$current_step <- 4 })
  observeEvent(input$to_step6, { rv$current_step <- 6 })

  # =====================================================================
  # STEP 6 - Metadata (generates eml.xml - the dataset-level metadata
  # file IPT can import directly instead of retyping everything into
  # its own metadata screens). Person fields share one organization/
  # address block since in practice everyone listed is usually at the
  # same institution - "same as creator" checkboxes cover the common
  # case where the metadata provider/contact IS the creator, without
  # forcing re-entry.
  # =====================================================================
  output$step6_body <- renderUI({
    tagList(
      card(
        card_header(bsicons::bs_icon("file-earmark-arrow-up", class = "section-icon"), "Fill from Excel (optional)"),
        card_body(
          p(class = "muted", "Prepare this metadata offline in a spreadsheet instead of the form below - download a blank template, fill it in, then upload it here to auto-fill every field. You can still edit anything by hand afterward."),
          fluidRow(
            column(6, downloadButton("download_eml_template", "Download blank template (.xlsx)", class = "btn-outline-secondary")),
            column(6, fileInput("eml_upload", "Upload a filled-in copy", accept = ".xlsx"))
          )
        )
      ),
      card(
        card_header(bsicons::bs_icon("card-text", class = "section-icon"), "Dataset"),
        card_body(
          textInput("eml_title", "Dataset title", placeholder = "e.g. OcOm_2408_16SFishD"),
          textAreaInput("eml_abstract", "Abstract (one paragraph per line)", rows = 4,
                        placeholder = "This dataset contains environmental DNA (eDNA) metabarcoding data..."),
          textInput("eml_keywords", "Keywords (comma-separated)", placeholder = "metabarcoding, DNA, eDNA, OceanOmics"),
          fluidRow(
            column(6, selectInput("eml_license", "License", choices = EML_LICENSE_CHOICES)),
            column(6, dateInput("eml_pub_date", "Publication date", value = Sys.Date()))
          ),
          textInput("eml_distribution_url", "Project/organization website (optional)", placeholder = "https://...")
        )
      ),
      card(
        card_header(bsicons::bs_icon("people-fill", class = "section-icon"), "People"),
        card_body(
          strong("Organization / address"), p(class = "muted", "Shared by everyone listed below, unless a person needs a different one."),
          fluidRow(
            column(6, textInput("eml_org_name", "Organization name")),
            column(6, textInput("eml_org_address", "Street address"))
          ),
          fluidRow(
            column(4, textInput("eml_org_city", "City")),
            column(4, textInput("eml_org_admin_area", "State/region")),
            column(4, textInput("eml_org_country", "Country code (e.g. AU)"))
          ),
          textInput("eml_org_phone", "Phone number (optional)"),
          tags$hr(),
          strong("Creator(s)"), p(class = "muted", "The person/people who generated this dataset - add one row per creator."),
          div(id = "creator_rows_container", creator_row_ui(1)),
          actionButton("add_creator", tagList(bsicons::bs_icon("plus-lg"), " Add another creator"), class = "btn-outline-secondary btn-sm"),
          tags$hr(),
          checkboxInput("eml_mp_same", "Metadata provider is the same person as the creator", value = TRUE),
          conditionalPanel(condition = "input.eml_mp_same == false",
            strong("Metadata provider"),
            fluidRow(
              column(3, textInput("eml_mp_given", "Given name")),
              column(3, textInput("eml_mp_sur", "Surname")),
              column(3, textInput("eml_mp_position", "Position")),
              column(3, textInput("eml_mp_email", "Email"))
            )
          ),
          tags$hr(),
          checkboxInput("eml_contact_same", "Contact is the same person as the creator", value = TRUE),
          conditionalPanel(condition = "input.eml_contact_same == false",
            strong("Contact"),
            fluidRow(
              column(3, textInput("eml_contact_given", "Given name")),
              column(3, textInput("eml_contact_sur", "Surname")),
              column(3, textInput("eml_contact_position", "Position")),
              column(3, textInput("eml_contact_email", "Email"))
            )
          ),
          tags$hr(),
          strong("Associated parties (optional)"), p(class = "muted", "Other people credited on this dataset, each with their own role - author, editor, reviewer, processor, curator, programmer, content provider, publisher, and more. Shares the Organization/address block above. Remove all rows to omit entirely."),
          div(id = "ap_rows_container", ap_row_ui(1)),
          actionButton("add_ap", tagList(bsicons::bs_icon("plus-lg"), " Add another associated party"), class = "btn-outline-secondary btn-sm")
        )
      ),
      card(
        card_header(bsicons::bs_icon("list-check", class = "section-icon"), "Methods"),
        card_body(
          textAreaInput("eml_methods", "Method steps (one per line, in order)", rows = 5,
                        placeholder = "Environmental sample collection from designated marine sampling locations.\nDNA extraction from collected environmental samples.\nPCR amplification of targeted genetic markers.\n..."),
          textAreaInput("eml_study_extent", "Study extent description", rows = 2),
          textAreaInput("eml_sampling_desc", "Sampling description", rows = 2)
        )
      ),
      card(
        card_header(bsicons::bs_icon("diagram-3", class = "section-icon"), "Project (optional)"),
        card_body(
          p(class = "muted", "Leave the Project ID blank to omit this section entirely."),
          textInput("eml_project_id", "Project ID"),
          textInput("eml_project_title", "Project title"),
          textAreaInput("eml_project_abstract", "Project abstract", rows = 2),
          textInput("eml_funding", "Funding"),
          textAreaInput("eml_study_area_desc", "Study area description", rows = 2),
          textAreaInput("eml_design_desc", "Design description", rows = 2),
          tags$hr(),
          strong("Project personnel"), p(class = "muted", "People with a role on this project specifically (e.g. point of contact, curator) - shares the Organization/address block above. Only used if Project ID is filled in."),
          div(id = "personnel_rows_container", personnel_row_ui(1)),
          actionButton("add_personnel", tagList(bsicons::bs_icon("plus-lg"), " Add another person"), class = "btn-outline-secondary btn-sm")
        )
      ),
      div(class = "nav-row",
          actionButton("back_to_5_from_6", tagList(bsicons::bs_icon("arrow-left"), " Back"), class = "btn-outline-secondary"),
          actionButton("generate_eml", tagList(bsicons::bs_icon("file-earmark-code"), " Generate metadata & continue"), class = "btn-primary")
      )
    )
  })

  observeEvent(input$back_to_5_from_6, { rv$current_step <- 5 })

  output$download_eml_template <- downloadHandler(
    filename = function() "faire2obis_metadata_template.xlsx",
    content = function(file) write_eml_metadata_excel(file)
  )

  observeEvent(input$eml_upload, {
    req(input$eml_upload)
    parsed <- tryCatch(
      read_eml_metadata_excel(input$eml_upload$datapath),
      error = function(e) {
        showNotification(paste("Could not read that file:", conditionMessage(e)), type = "error", duration = NULL)
        NULL
      }
    )
    if (is.null(parsed)) return()

    for (def in EML_FIELD_DEFS) {
      if (!def$key %in% names(parsed)) next
      val <- parsed[[def$key]]
      input_id <- paste0("eml_", def$key)
      switch(def$type,
        text     = updateTextInput(session, input_id, value = val),
        textarea = updateTextAreaInput(session, input_id, value = val),
        date     = updateDateInput(session, input_id, value = as.Date(val)),
        logical  = updateCheckboxInput(session, input_id, value = isTRUE(val)),
        select   = updateSelectInput(session, input_id, selected = val)
      )
    }

    creators <- parsed$creators
    if (!is.null(creators) && length(creators) > 0) {
      ids <- set_creator_rows(length(creators))
      for (i in seq_along(ids)) {
        c <- creators[[i]]
        updateTextInput(session, paste0("eml_creator_given_", ids[i]), value = c$given_name %||% "")
        updateTextInput(session, paste0("eml_creator_sur_", ids[i]), value = c$sur_name %||% "")
        updateTextInput(session, paste0("eml_creator_position_", ids[i]), value = c$position %||% "")
        updateTextInput(session, paste0("eml_creator_email_", ids[i]), value = c$email %||% "")
        updateTextInput(session, paste0("eml_creator_org_", ids[i]), value = c$organization %||% "")
        updateTextInput(session, paste0("eml_creator_address_", ids[i]), value = c$delivery_point %||% "")
        updateTextInput(session, paste0("eml_creator_city_", ids[i]), value = c$city %||% "")
        updateTextInput(session, paste0("eml_creator_admin_area_", ids[i]), value = c$admin_area %||% "")
        updateTextInput(session, paste0("eml_creator_country_", ids[i]), value = c$country %||% "")
        updateTextInput(session, paste0("eml_creator_phone_", ids[i]), value = c$phone %||% "")
      }
    }

    personnel <- parsed$personnel
    if (!is.null(personnel) && length(personnel) > 0) {
      ids <- set_personnel_rows(length(personnel))
      for (i in seq_along(ids)) {
        p <- personnel[[i]]
        updateTextInput(session, paste0("eml_personnel_given_", ids[i]), value = p$given_name %||% "")
        updateTextInput(session, paste0("eml_personnel_sur_", ids[i]), value = p$sur_name %||% "")
        updateTextInput(session, paste0("eml_personnel_position_", ids[i]), value = p$position %||% "")
        updateTextInput(session, paste0("eml_personnel_email_", ids[i]), value = p$email %||% "")
        updateTextInput(session, paste0("eml_personnel_role_", ids[i]), value = p$role %||% "POINT_OF_CONTACT")
      }
    }

    aps <- parsed$associated_parties
    if (!is.null(aps)) {
      ids <- set_ap_rows(length(aps))
      for (i in seq_along(ids)) {
        a <- aps[[i]]
        updateTextInput(session, paste0("eml_ap_given_", ids[i]), value = a$given_name %||% "")
        updateTextInput(session, paste0("eml_ap_sur_", ids[i]), value = a$sur_name %||% "")
        updateTextInput(session, paste0("eml_ap_position_", ids[i]), value = a$position %||% "")
        updateTextInput(session, paste0("eml_ap_email_", ids[i]), value = a$email %||% "")
        updateSelectInput(session, paste0("eml_ap_role_", ids[i]), selected = a$role %||% "PUBLISHER")
      }
    }

    showNotification(paste0("Filled ", length(parsed), " field(s) from the uploaded file - review before continuing."),
                      type = "message", duration = 6)
  })

  observeEvent(input$generate_eml, {
    org <- list(
      organization   = input$eml_org_name,
      delivery_point = input$eml_org_address,
      city           = input$eml_org_city,
      admin_area     = input$eml_org_admin_area,
      country        = input$eml_org_country,
      phone          = input$eml_org_phone
    )
    creators <- lapply(rv$creator_ids, function(id) {
      list(given_name     = input[[paste0("eml_creator_given_", id)]],
           sur_name       = input[[paste0("eml_creator_sur_", id)]],
           position       = input[[paste0("eml_creator_position_", id)]],
           email          = input[[paste0("eml_creator_email_", id)]],
           organization   = input[[paste0("eml_creator_org_", id)]],
           delivery_point = input[[paste0("eml_creator_address_", id)]],
           city           = input[[paste0("eml_creator_city_", id)]],
           admin_area     = input[[paste0("eml_creator_admin_area_", id)]],
           country        = input[[paste0("eml_creator_country_", id)]],
           phone          = input[[paste0("eml_creator_phone_", id)]])
    })
    # "Same as creator" (metadata provider / contact) means the FIRST
    # listed creator - EML only ever has one metadataProvider/contact,
    # unlike creator which can repeat.
    first_creator <- creators[[1]]

    metadata_provider <- if (isTRUE(input$eml_mp_same)) {
      first_creator
    } else {
      c(list(given_name = input$eml_mp_given, sur_name = input$eml_mp_sur,
             position = input$eml_mp_position, email = input$eml_mp_email), org)
    }

    contact <- if (isTRUE(input$eml_contact_same)) {
      first_creator
    } else {
      c(list(given_name = input$eml_contact_given, sur_name = input$eml_contact_sur,
             position = input$eml_contact_position, email = input$eml_contact_email), org)
    }

    associated_party <- lapply(rv$ap_ids, function(id) {
      c(list(given_name = input[[paste0("eml_ap_given_", id)]],
             sur_name    = input[[paste0("eml_ap_sur_", id)]],
             position    = input[[paste0("eml_ap_position_", id)]],
             email       = input[[paste0("eml_ap_email_", id)]],
             role        = input[[paste0("eml_ap_role_", id)]]), org)
    })

    project_personnel <- lapply(rv$personnel_ids, function(id) {
      c(list(given_name = input[[paste0("eml_personnel_given_", id)]],
             sur_name    = input[[paste0("eml_personnel_sur_", id)]],
             position    = input[[paste0("eml_personnel_position_", id)]],
             email       = input[[paste0("eml_personnel_email_", id)]],
             role        = input[[paste0("eml_personnel_role_", id)]]), org)
    })

    keywords <- trimws(strsplit(input$eml_keywords %||% "", ",")[[1]])
    abstract_paragraphs <- strsplit(input$eml_abstract %||% "", "\n")[[1]]
    method_steps <- strsplit(input$eml_methods %||% "", "\n")[[1]]

    eml <- tryCatch(
      build_eml_xml(
        title                     = input$eml_title,
        creator                   = creators,
        metadata_provider         = metadata_provider,
        contact                   = contact,
        associated_party          = associated_party,
        pub_date                  = input$eml_pub_date,
        abstract_paragraphs       = abstract_paragraphs,
        keywords                  = keywords,
        license_url               = input$eml_license,
        license_title             = names(EML_LICENSE_CHOICES)[EML_LICENSE_CHOICES == input$eml_license],
        distribution_url          = input$eml_distribution_url,
        method_steps              = method_steps,
        study_extent_description  = input$eml_study_extent,
        sampling_description      = input$eml_sampling_desc,
        project_id                = input$eml_project_id,
        project_title             = input$eml_project_title,
        project_abstract          = input$eml_project_abstract,
        funding                   = input$eml_funding,
        study_area_description    = input$eml_study_area_desc,
        design_description        = input$eml_design_desc,
        project_personnel         = project_personnel
      ),
      error = function(e) {
        showNotification(paste("Could not generate metadata:", conditionMessage(e)), type = "error", duration = NULL)
        NULL
      }
    )

    if (!is.null(eml)) {
      rv$eml_xml <- eml
      rv$current_step <- 7
    }
  })

  # =====================================================================
  # STEP 7 - Results & Download
  # =====================================================================
  output$step7_body <- renderUI({
    req(rv$build_result, rv$worms_result)
    tagList(
      card(
        card_header(bsicons::bs_icon("people-fill", class = "section-icon"), "Samples"),
        card_body(plotOutput("chart_samples", height = "300px"))
      ),
      card(
        card_header(bsicons::bs_icon("bar-chart-fill", class = "section-icon"), "Detections per assay"),
        card_body(plotOutput("chart_detections", height = "300px"))
      ),
      card(
        card_header(bsicons::bs_icon("check2-square", class = "section-icon"), "Taxonomy resolution"),
        card_body(tableOutput("taxonomy_table"))
      ),
      card(
        card_header(bsicons::bs_icon("download", class = "section-icon"), "Download"),
        card_body(
          p(class = "muted", paste0(
            "A zip with the Event core, one Occurrence extension per assay, one DNA Derived Data extension per assay",
            if (!is.null(rv$eml_xml)) ", and eml.xml" else " (no eml.xml - go back to Step 6 to generate one)",
            " - ready to upload to an IPT."
          )),
          downloadButton("download_archive", "Download archive (.zip)", class = "btn-primary"),
          if (archive_history_enabled())
            p(class = "muted", style = "margin-top: 8px;", "Every archive generated here is also saved to the History tab.")
        )
      ),
      div(class = "nav-row", actionButton("back_to_6_from_7", tagList(bsicons::bs_icon("arrow-left"), " Back"), class = "btn-outline-secondary"), div())
    )
  })

  chart_theme <- theme_minimal(base_size = 14) +
    theme(axis.title = element_blank(), panel.grid.minor = element_blank(),
          panel.grid.major.x = element_blank(), legend.position = "none")

  output$chart_samples <- renderPlot({
    req(rv$build_result)
    samples <- tibble(
      category = factor(c("Real samples (in the archive)", "Controls (excluded)"),
                         levels = c("Real samples (in the archive)", "Controls (excluded)")),
      n = c(nrow(rv$build_result$event_core), nrow(rv$build_result$controls)),
      is_real = c(TRUE, FALSE)
    )
    ggplot(samples, aes(x = category, y = n, fill = is_real)) +
      geom_col(width = 0.5) +
      geom_text(aes(label = n), vjust = -0.6, fontface = "bold", size = 5) +
      scale_fill_manual(values = c(`TRUE` = "#2a78d6", `FALSE` = "#c3c2b7")) +
      scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
      chart_theme
  })

  output$chart_detections <- renderPlot({
    req(rv$build_result)
    df <- tibble(assay = names(rv$build_result$occurrence), n = vapply(rv$build_result$occurrence, nrow, integer(1)))
    ggplot(df, aes(x = assay, y = n)) +
      geom_col(fill = "#2a78d6", width = 0.45) +
      geom_text(aes(label = format(n, big.mark = ",")), vjust = -0.6, fontface = "bold", size = 5) +
      scale_y_continuous(labels = scales::comma, expand = expansion(mult = c(0, 0.15))) +
      chart_theme
  })

  output$taxonomy_table <- renderTable({
    req(rv$worms_result)
    r <- rv$worms_result
    if (nrow(r$resolved_ambiguous_df) > 0) {
      n_manual <- length(unique(r$resolved_ambiguous_df$queriedName[r$resolved_ambiguous_df$resolution == "manual_override"]))
      n_auto   <- length(unique(r$resolved_ambiguous_df$queriedName[r$resolved_ambiguous_df$resolution == "single_accepted"]))
    } else {
      n_manual <- 0
      n_auto   <- 0
    }
    n_matched  <- length(unique(r$matched_df$queriedName))
    n_direct   <- n_matched - n_auto - n_manual
    n_corrected <- length(rv$name_corrections)
    n_ambiguous <- length(unique(r$ambiguous_df$queriedName))
    n_unmatched <- length(r$unmatched_names)

    tibble(
      Resolution = c("Matched directly", "Corrected by you, then matched", "Auto-resolved (single accepted WoRMS record)",
                      "Manually resolved by you", "Still ambiguous", "Still unmatched"),
      Names = c(n_direct, n_corrected, n_auto, n_manual, n_ambiguous, n_unmatched)
    )
  })

  output$download_archive <- downloadHandler(
    filename = function() paste0("faire2obis_archive_", format(Sys.Date(), "%Y%m%d"), ".zip"),
    content = function(file) {
      req(rv$build_result, rv$worms_result)
      tmpdir <- tempfile("faire2obis_")
      dir.create(tmpdir, recursive = TRUE)

      # All data files sit flat in one folder, matching standard Darwin
      # Core Archive layout (core + every extension side-by-side; it's
      # meta.xml, not folder structure, that records which file is the
      # core and how each extension links back to it - no meta.xml yet,
      # since these files are meant to be uploaded individually into an
      # institutional IPT, which builds the real archive itself).
      write.csv(rv$build_result$event_core, file.path(tmpdir, "Event.csv"), row.names = FALSE, na = "")
      for (a in names(rv$worms_result$occurrence_tables)) {
        write.csv(rv$worms_result$occurrence_tables[[a]], file.path(tmpdir, paste0("Occurrence_", a, ".csv")), row.names = FALSE, na = "")
      }
      for (a in names(rv$build_result$dna_extension)) {
        write.csv(rv$build_result$dna_extension[[a]], file.path(tmpdir, paste0("DNADerivedData_", a, ".csv")), row.names = FALSE, na = "")
      }
      if (!is.null(rv$eml_xml)) {
        writeLines(rv$eml_xml, file.path(tmpdir, "eml.xml"))
      }

      old_wd <- setwd(tmpdir)
      on.exit(setwd(old_wd))
      zip::zip(file, files = list.files(".", recursive = TRUE))
      setwd(old_wd)

      if (archive_history_enabled()) {
        tryCatch({
          save_archive_to_s3(file, input$project_id, names(rv$build_result$dna_extension))
          history_refresh(isolate(history_refresh()) + 1)
        }, error = function(e) {
          showNotification(paste("Archive downloaded, but saving it to history failed:", conditionMessage(e)), type = "warning", duration = 8)
        })
      }
    }
  )

  # ---- History tab (only functional when AWS credentials are set) --------
  archive_history_df <- reactive({
    history_refresh()
    req(archive_history_enabled())
    tryCatch(list_archive_history(), error = function(e) {
      showNotification(paste("Couldn't load archive history:", conditionMessage(e)), type = "error")
      NULL
    })
  })

  output$history_tab_body <- renderUI({
    if (!archive_history_enabled()) {
      return(card(
        card_header(bsicons::bs_icon("clock-history", class = "section-icon"), "History"),
        card_body(p(class = "muted",
          "Archive history isn't configured yet for this deployment (no AWS credentials set) - archives generated here aren't saved anywhere permanent."))
      ))
    }
    tagList(
      card(
        card_header(bsicons::bs_icon("clock-history", class = "section-icon"), "Public S3 folder contents"),
        card_body(
          p(class = "muted", paste0(
            "Everything currently under s3://", s3_bucket_name(), "/", s3_public_prefix(),
            "/ - not just archives generated by this app. Select a row to download it."
          )),
          DT::DTOutput("archive_history_table"),
          div(style = "margin-top: 10px;",
              downloadButton("download_history_item", "Download selected", class = "btn-outline-primary btn-sm"))
        )
      )
    )
  })

  output$archive_history_table <- DT::renderDT({
    df <- archive_history_df()
    req(df)
    DT::datatable(
      df[, c("last_modified", "path", "size_mb")],
      selection = "single", rownames = FALSE,
      colnames = c("Last modified (UTC)", "Path", "Size"),
      options = list(pageLength = 15, dom = "tip")
    )
  })

  output$download_history_item <- downloadHandler(
    filename = function() {
      sel <- input$archive_history_table_rows_selected
      req(sel)
      df <- archive_history_df()
      req(df)
      basename(df$s3_key[sel])
    },
    content = function(file) {
      sel <- input$archive_history_table_rows_selected
      req(sel)
      df <- archive_history_df()
      req(df)
      fetch_archive_from_s3(df$s3_key[sel], file)
    }
  )

  observeEvent(input$back_to_6_from_7, { rv$current_step <- 6 })

  # =====================================================================
  # Restart - clears all progress and returns to a genuinely blank Step 1
  # (fresh DOM nodes for the file inputs, not just cleared values, since
  # browsers won't let JS reset a file input's displayed selection).
  # =====================================================================
  observeEvent(input$restart_app, {
    showModal(modalDialog(
      title = "Restart process?",
      "This clears all uploaded files, answers, and progress. This cannot be undone.",
      footer = tagList(modalButton("Cancel"), actionButton("confirm_restart", "Restart", class = "btn-danger")),
      easyClose = TRUE
    ))
  })

  observeEvent(input$confirm_restart, {
    removeModal()

    for (id in rv$assay_ids) removeUI(selector = paste0("#assay_row_", id))

    updateTextInput(session, "project_id", value = "")
    updateTextInput(session, "sample_category_keep", value = "sample")

    rv$validation   <- NULL
    rv$answers      <- list(georeference_sources = NA_character_, associated_sequences_uri = NA_character_)
    rv$build_result <- NULL
    rv$build_error  <- NULL
    rv$worms_result <- NULL
    rv$name_corrections <- character()
    rv$manual_aphia_overrides <- c()
    rv$qc_result    <- NULL
    rv$eml_xml      <- NULL

    new_id <- rv$next_assay_id
    insertUI(selector = "#assay_rows_container", where = "beforeEnd", ui = assay_row_ui(new_id))
    setup_remove_handler(new_id)
    setup_assay_name_autodetect(new_id)
    rv$assay_ids <- c(new_id)
    rv$next_assay_id <- new_id + 1

    rv$current_step <- 1
    showNotification("Restarted.", type = "message", duration = 2)
  })
}

shinyApp(ui, server)
