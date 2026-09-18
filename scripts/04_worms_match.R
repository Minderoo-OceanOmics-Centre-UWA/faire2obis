### 04_worms_match.R
#
# Matches every unique scientificName produced by 02_build_occurrence.R
# against WoRMS, and fills in scientificNameID for all three Occurrence
# tables. Run this AFTER 02, as its own separate, reviewable step - see
# CLAUDE.md "Taxonomy - handle as a SEPARATE step" for why this isn't
# folded into script 02.
#
# Uses the `worrms` R package (wraps the WoRMS REST API
# AphiaRecordsByName / matchAphiaRecordsByNames services), the tool
# recommended in the OBIS course for this exact task.
#
# Output:
#   - output/dna_extension/../ (not touched by this script)
#   - Updates each Occurrence_<assay>.csv IN PLACE with scientificNameID
#     filled in for matched names
#   - output/worms_match/unmatched_names.csv   - names with NO WoRMS match at all
#   - output/worms_match/ambiguous_names.csv   - names with >1 possible match AND
#                                                 no single 'accepted' record among them
#   - output/worms_match/ambiguous_resolved.csv - names with >1 WoRMS record where
#                                                 exactly one was 'accepted' - auto-
#                                                 resolved to that record (WoRMS' own
#                                                 canonical pick, not a guess), logged
#                                                 here for audit
#   - output/worms_match/matched_names.csv     - the successful name -> LSID table (for reference/audit)
#
# IMPORTANT: unmatched_names.csv and ambiguous_names.csv need MANUAL
# REVIEW before you finalize the archive. Do not treat every row in
# matched_names.csv as necessarily correct either - spot check a sample,
# especially anything matched at genus/family level.
#
# Name corrections (see name_corrections / strip_voucher_code below):
# found by manually reviewing a prior run's unmatched_names.csv against
# WoRMS + FishBase. Two categories, both logged to
# output/worms_match/name_corrections_applied.csv for audit:
#   a) manual overrides for specific misspelled/outdated names, e.g.
#      "Lampanyctus reinhardti" -> "Hygophum reinhardtii" (WoRMS AphiaID
#      126604 - Lampanyctus reinhardtii is only an unaccepted synonym,
#      and the source data also had it misspelled with one "i").
#   b) generic stripping of voucher/accession codes the LCA pipeline
#      appended onto a genus/subfamily name when its best reference-
#      database hit was an unidentified specimen labelled by catalog
#      code rather than a real binomial, e.g.
#      "Trachyrhamphus IFBIO334-17" -> "Trachyrhamphus". Only names
#      containing a digit are touched, since real taxon names never do.
# taxonRank is NOT touched by either correction - it was already set
# correctly in script 02 from taxaFinal's own taxonRank column,
# independent of this contamination in the name string. The original,
# as-provided name remains untouched in verbatimIdentification.
#
# "Centropogon australis (in: eudicots)" - a homonym-disambiguation
# annotation leaking into the name from the source reference database -
# is deliberately NOT auto-corrected here; still needs manual review.

library(dplyr)
library(readr)
library(worrms)

WORMS_OUTPUT_DIR <- file.path(OUTPUT_FOLDER, "worms_match")
dir.create(WORMS_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

# ----------------------------------------------------------------------
# 1. Collect every unique scientificName across all three Occurrence tables
# ----------------------------------------------------------------------
occurrence_files <- list.files(
  OCCURRENCE_OUTPUT_DIR,
  pattern = "^Occurrence_.*\\.csv$",
  full.names = TRUE
)

if (length(occurrence_files) == 0) {
  stop("No Occurrence_*.csv files found in ", OCCURRENCE_OUTPUT_DIR,
       " - run 02_build_occurrence.R first.")
}

cat("Found", length(occurrence_files), "occurrence file(s):\n")
cat(paste(" -", basename(occurrence_files)), sep = "\n")

occurrence_tables <- lapply(occurrence_files, read_csv, show_col_types = FALSE)
names(occurrence_tables) <- basename(occurrence_files)

all_names <- unique(unlist(lapply(occurrence_tables, function(x) x$scientificName)))
all_names <- all_names[!is.na(all_names)]

# ----------------------------------------------------------------------
# 1b. Apply known name corrections (see header comment) before querying
#     WoRMS. clean_lookup maps every raw scientificName -> the name
#     actually sent to WoRMS (identical to the raw name when no
#     correction applies).
# ----------------------------------------------------------------------
name_corrections <- c(
  "Lampanyctus reinhardti" = "Hygophum reinhardtii",
  # "(in: eudicots)" is NCBI Taxonomy's own homonym-disambiguation tag
  # (NCBI has two unrelated "Centropogon" genera - TaxID 76572, a
  # eudicot plant, and TaxID 210578, the ray-finned fish genus). The
  # reference database behind taxaFinal did a name-based rather than
  # TaxID-based lookup and landed on the wrong (plant) homonym. This is
  # fish eDNA data, so the real organism is the marine fish Centropogon
  # australis (White, 1790) - confirmed accepted, WoRMS AphiaID 280056.
  "Centropogon australis (in: eudicots)" = "Centropogon australis"
)

strip_voucher_code <- function(name) {
  if (!grepl("[0-9]", name)) return(name)
  cleaned <- sub("\\s+gen\\.\\s*sp\\.\\s*\\S+$", "", name)
  cleaned <- sub("\\s+[A-Za-z]+:?[0-9]+-?[0-9]*$", "", cleaned)
  trimws(cleaned)
}

clean_name_for <- function(name) {
  if (name %in% names(name_corrections)) return(unname(name_corrections[name]))
  strip_voucher_code(name)
}

# ----------------------------------------------------------------------
# Manual AphiaID overrides for names where WoRMS returns >1 'accepted'
# record for genuinely different organisms (a homonym across kingdoms,
# same pattern as the Centropogon fix above) - the "exactly one
# accepted" auto-resolution rule below can't disambiguate these since
# BOTH candidates are legitimately 'accepted'. Checked via WoRMS'
# AphiaID -> external-ID (NCBI) cross-reference first (wm_external /
# wm_record_by_external) - no NCBI link exists for this taxon in either
# direction in WoRMS' database, so resolved instead from the WoRMS
# records' own family field, which cleanly separates the two organisms:
#   - Howella: AphiaID 126040 (Ogilby, 1899) is family Howellidae, a
#     fish genus - matches this project's 12S rRNA fish mtDNA data.
#     AphiaID 1647658 is family Halymeniaceae, a red-algae genus -
#     wrong kingdom entirely, not a candidate.
# ----------------------------------------------------------------------
manual_aphia_overrides <- c(
  "Howella" = 126040
)

# Incertae sedis already has its fixed WoRMS LSID assigned in script 02 -
# don't waste an API call on it.
raw_names_to_match <- setdiff(all_names, "Incertae sedis")
clean_lookup <- setNames(vapply(raw_names_to_match, clean_name_for, character(1)), raw_names_to_match)

corrections_made <- clean_lookup[clean_lookup != names(clean_lookup)]
if (length(corrections_made) > 0) {
  cat("Applying", length(corrections_made), "name correction(s) before WoRMS matching:\n")
  for (raw in names(corrections_made)) {
    cat("  '", raw, "' -> '", corrections_made[[raw]], "'\n", sep = "")
  }
  write_csv(
    tibble(rawName = names(corrections_made), correctedName = unname(corrections_made)),
    file.path(WORMS_OUTPUT_DIR, "name_corrections_applied.csv")
  )
  cat("\n")
}

names_to_match <- unique(unname(clean_lookup))

cat("\nUnique scientificName values across all assays:", length(all_names), "\n")
cat("Sending to WoRMS for matching:", length(names_to_match), "(after corrections)\n\n")

# ----------------------------------------------------------------------
# 2. Query WoRMS in batches (wm_records_names takes a vector, max ~50
#    names per call is safest / matches the WoRMS Taxon Match tool's
#    own row limit mentioned in the course material)
# ----------------------------------------------------------------------
batch_size <- 50
batches <- split(names_to_match, ceiling(seq_along(names_to_match) / batch_size))

matched_rows       <- list()
unmatched_names    <- character()
ambiguous_names    <- list()
resolved_ambiguous <- list()

for (i in seq_along(batches)) {
  batch <- batches[[i]]
  cat("Matching batch", i, "of", length(batches), "(", length(batch), "names )...\n")

  # marine_only = FALSE: we want to see non-marine flags too, rather
  # than have WoRMS silently exclude them - non-marine review is
  # handled downstream in 05_qc_checks.R, but it's better to see
  # matches happen here than have them silently filtered out.
  result <- tryCatch(
    worrms::wm_records_names(name = batch, marine_only = FALSE),
    error = function(e) {
      cat("  WARNING: batch", i, "failed:", conditionMessage(e), "\n")
      NULL
    }
  )

  if (is.null(result)) next

  for (j in seq_along(batch)) {
    queried_name <- batch[j]
    recs <- result[[j]]

    if (is.null(recs) || nrow(recs) == 0) {
      unmatched_names <- c(unmatched_names, queried_name)

    } else if (nrow(recs) == 1) {
      matched_rows[[queried_name]] <- tibble(
        queriedName      = queried_name,
        scientificNameID = paste0("urn:lsid:marinespecies.org:taxname:", recs$AphiaID[1]),
        worms_status      = recs$status[1],
        worms_valid_name  = recs$valid_name[1],
        worms_rank        = recs$rank[1],
        worms_isMarine    = recs$isMarine[1]
      )

    } else {
      # More than one WoRMS record shares this name. Three ways this
      # gets resolved, in order - never by guessing:
      #   1. A manual AphiaID override (see manual_aphia_overrides above)
      #      - reviewed by hand for names where >1 candidate is
      #      'accepted' but they're genuinely different organisms.
      #   2. Exactly one candidate has status == "accepted" - that's
      #      WoRMS' own designated canonical record for this name (the
      #      rest are unaccepted/synonym/junior homonym/unassessed
      #      housekeeping variants). Resolving to it reads WoRMS'
      #      bookkeeping, not a taxon-identity guess.
      #   3. Otherwise: genuine ambiguity - flag for manual review.
      # Cases 1 and 2 are both logged to ambiguous_resolved.csv for audit.
      accepted_rows <- recs %>% filter(status == "accepted")

      if (queried_name %in% names(manual_aphia_overrides)) {
        chosen_id  <- unname(manual_aphia_overrides[queried_name])
        chosen_row <- recs %>% filter(AphiaID == chosen_id)
        matched_rows[[queried_name]] <- tibble(
          queriedName      = queried_name,
          scientificNameID = paste0("urn:lsid:marinespecies.org:taxname:", chosen_id),
          worms_status      = chosen_row$status[1],
          worms_valid_name  = chosen_row$valid_name[1],
          worms_rank        = chosen_row$rank[1],
          worms_isMarine    = chosen_row$isMarine[1]
        )
        resolved_ambiguous[[queried_name]] <- recs %>%
          mutate(queriedName = queried_name, chosenAphiaID = chosen_id, resolution = "manual_override") %>%
          select(queriedName, AphiaID, scientificname, status, rank, isMarine, chosenAphiaID, resolution)

      } else if (nrow(accepted_rows) == 1) {
        matched_rows[[queried_name]] <- tibble(
          queriedName      = queried_name,
          scientificNameID = paste0("urn:lsid:marinespecies.org:taxname:", accepted_rows$AphiaID[1]),
          worms_status      = accepted_rows$status[1],
          worms_valid_name  = accepted_rows$valid_name[1],
          worms_rank        = accepted_rows$rank[1],
          worms_isMarine    = accepted_rows$isMarine[1]
        )
        resolved_ambiguous[[queried_name]] <- recs %>%
          mutate(queriedName = queried_name, chosenAphiaID = accepted_rows$AphiaID[1], resolution = "single_accepted") %>%
          select(queriedName, AphiaID, scientificname, status, rank, isMarine, chosenAphiaID, resolution)

      } else {
        ambiguous_names[[queried_name]] <- recs %>%
          mutate(queriedName = queried_name) %>%
          select(queriedName, AphiaID, scientificname, status, rank, isMarine)
      }
    }
  }
}

cat("\nMatching complete.\n")
cat("  Unique matches:          ", length(matched_rows), "\n")
cat("  - of which auto-resolved from >1 WoRMS record (single 'accepted'):", length(resolved_ambiguous), "\n")
cat("  Ambiguous (>1 accepted, or 0):", length(ambiguous_names), "\n")
cat("  No match found:          ", length(unmatched_names), "\n\n")

# ----------------------------------------------------------------------
# 3. Write review files
# ----------------------------------------------------------------------
matched_df <- bind_rows(matched_rows)
write_csv(matched_df, file.path(WORMS_OUTPUT_DIR, "matched_names.csv"))

if (length(resolved_ambiguous) > 0) {
  resolved_df <- bind_rows(resolved_ambiguous)
  write_csv(resolved_df, file.path(WORMS_OUTPUT_DIR, "ambiguous_resolved.csv"))
  cat("AUTO-RESOLVED (single 'accepted' record among multiple WoRMS candidates) -",
      "see output/worms_match/ambiguous_resolved.csv for audit:\n")
  for (n in names(resolved_ambiguous)) cat("  '", n, "'\n", sep = "")
  cat("\n")
}

if (length(ambiguous_names) > 0) {
  ambiguous_df <- bind_rows(ambiguous_names)
  write_csv(ambiguous_df, file.path(WORMS_OUTPUT_DIR, "ambiguous_names.csv"))
  cat("REVIEW NEEDED: output/worms_match/ambiguous_names.csv\n")
}

if (length(unmatched_names) > 0) {
  write_csv(
    tibble(scientificName = unmatched_names),
    file.path(WORMS_OUTPUT_DIR, "unmatched_names.csv")
  )
  cat("REVIEW NEEDED: output/worms_match/unmatched_names.csv\n")
  cat("  (For genuinely unresolved names, consider: is the rank too low for\n",
      "  WoRMS to have an exact-name entry? e.g. 'Diaphus' might need to stay\n",
      "  at genus level and still match - if it doesn't, check spelling against\n",
      "  the source data before assuming no match exists.)\n\n")
}

# ----------------------------------------------------------------------
# 4. Flag non-marine matches too - these need the same manual review
#    process described in the course (check WoRMS/IRMNG, contact WoRMS
#    Data Management Team if marine status is wrong, otherwise expect
#    OBIS to drop these records)
# ----------------------------------------------------------------------
non_marine <- matched_df %>% filter(worms_isMarine == 0 | is.na(worms_isMarine))
if (nrow(non_marine) > 0) {
  write_csv(non_marine, file.path(WORMS_OUTPUT_DIR, "non_marine_matches.csv"))
  cat("REVIEW NEEDED:", nrow(non_marine),
      "matched names are flagged non-marine by WoRMS - see output/worms_match/non_marine_matches.csv\n",
      "These will be DROPPED by OBIS QC unless resolved (see Module 6: Non-marine species).\n\n")
}

# ----------------------------------------------------------------------
# 5. Apply matched scientificNameIDs back into each Occurrence table -
#    and, where a name correction (section 1b) was applied AND that
#    corrected name found a WoRMS match, also replace scientificName
#    with the corrected form. A correction that did NOT find a match is
#    left completely untouched (raw name, no ID) - do not rename a
#    taxon based on an unverified guess.
# ----------------------------------------------------------------------
lookup <- setNames(matched_df$scientificNameID, matched_df$queriedName)

for (fname in names(occurrence_tables)) {
  occ <- occurrence_tables[[fname]]

  occ <- occ %>%
    mutate(
      cleanName = case_when(
        scientificName == "Incertae sedis"      ~ scientificName,
        scientificName %in% names(clean_lookup) ~ unname(clean_lookup[scientificName]),
        TRUE                                     ~ scientificName
      ),
      scientificNameID = case_when(
        scientificName == "Incertae sedis" ~ scientificNameID,  # already set in script 02
        cleanName %in% names(lookup)       ~ unname(lookup[cleanName]),
        TRUE ~ scientificNameID  # leave as-is (NA) for unmatched/ambiguous - do not guess
      ),
      scientificName = if_else(
        scientificName != "Incertae sedis" & !is.na(scientificNameID),
        cleanName,
        scientificName
      )
    ) %>%
    select(-cleanName)

  out_path <- file.path(OCCURRENCE_OUTPUT_DIR, fname)
  write_csv(occ, out_path, na = "")

  n_filled <- sum(!is.na(occ$scientificNameID))
  cat("Updated", fname, "-", n_filled, "/", nrow(occ), "rows now have scientificNameID\n")
}

cat("\nDone. Before publishing: review ambiguous_names.csv, unmatched_names.csv,",
    "and non_marine_matches.csv in output/worms_match/.\n")
