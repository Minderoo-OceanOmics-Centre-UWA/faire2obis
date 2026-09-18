# CLAUDE.md

Context for Claude Code when working in this repository. Read this before
making changes — it captures the domain rules and decisions this project
depends on, not just the code.

## What this project does

Converts OceanOmics eDNA metabarcoding data (FAIRe format) into a Darwin
Core Archive for publishing to OBIS (Ocean Biodiversity Information
System). Project ID `OcOm_2408`: one set of physical water samples,
sequenced with **three separate metabarcoding assays** (16SFishD,
MarVer1, MiFishUE2).

## The core architectural decision: Event core, not Occurrence core

This is the single most important decision in this repo and should not
be silently changed.

- All three assays sequence the **same physical samples**. Verified:
  628/628 samples identical across all three FAIRe files, 0 mismatches
  in shared sample metadata (coordinates, dates, depth, env measurements).
- GBIF's Metabarcoding Data Toolkit (MDT) and the existing
  `FAIRe2MDT.R` script assume **one dataset = one assay**, which would
  triplicate all sample/location/environmental metadata across three
  independent datasets. We are deliberately not using that approach.
- Instead: **one Event core** (physical sample = one event, written
  once) + **one Occurrence extension per assay** (linked via `eventID`)
  + **one DNA Derived Data extension per assay** (linked via
  `occurrenceID`). This is the OBIS-ENV-DATA structure.

```
Event core (490 rows, one per real sample)
    |
    +-- eventID --> Occurrence extension: 16SFishD
    |                   |
    |                   +-- occurrenceID --> DNA Derived Data ext: 16SFishD
    |
    +-- eventID --> Occurrence extension: MarVer1
    |                   +-- occurrenceID --> DNA Derived Data ext: MarVer1
    |
    +-- eventID --> Occurrence extension: MiFishUE2
                        +-- occurrenceID --> DNA Derived Data ext: MiFishUE2
```

## OBIS / Darwin Core rules this pipeline must follow

### Identifiers
- `eventID` in the core table must be **unique**. Built here as
  `samp_name` as-is (e.g. `OcOm_2408_1_1`) — confirmed globally unique
  across all 628 samples in all 3 files, project_id already embedded.
- `occurrenceID` should be built by extending `eventID` (e.g.
  `eventID` + ASV ID), not invented separately.
- IDs in an **extension** table (Occurrence, eMoF, DNA Derived Data)
  are allowed to repeat (multiple rows can share the same `eventID`),
  but IDs in a **core** table must be unique per row.

### Dates
- `eventDate` must be ISO 8601. **Never pad with zeros** for unknown
  date parts (`2011-03`, not `2011-03-00`).
- Keep the original as-provided string in `verbatimEventDate`.

### Coordinates
- `decimalLatitude`/`decimalLongitude` must be decimal degrees.
  Zero coordinates and out-of-range coordinates get records **dropped**
  by OBIS QC — validate before publishing.
- If coordinates were estimated (gazetteer, midpoint, etc.), document
  the source in `georeferenceSources` and method in `georeferenceRemarks`.
  (Note: current placeholder value in `georeferenceSources` in
  `01_build_event_core.R` needs to be replaced with the real source —
  this was flagged as a TODO, not a final answer.)

### Control samples
- Negative/positive controls (`samp_category` = "negative control" /
  "positive control" in the FAIRe sheet) must be **excluded** from the
  mapped Occurrence extension — they are lab/field QC artifacts, not
  biodiversity occurrences.
- They are kept in `output/controls/` as an unmapped reference file
  only — not part of the archive uploaded to the IPT.
- 490 real samples / 138 controls (131 negative + 7 positive) in this
  dataset.

### DNA-derived data specifics (Category I/II eDNA — no physical
specimen, sequence is the only evidence)
- `organismQuantity` = reads of that specific ASV in that sample.
- `organismQuantityType` = always the literal string
  `"DNA sequence reads"`.
- `sampleSizeValue` = **total** reads in that sample (for relative
  abundance calculation). `sampleSizeUnit` = `"DNA sequence reads"`.
- These are NOT organism counts — never confuse with `individualCount`.
- `DNA_sequence` field (in the DNA Derived Data extension) is the
  actual ASV/OTU sequence string — the single most important field,
  makes the record searchable via sequence alignment / the OBIS
  sequence search tool.
- `basisOfRecord` = `MaterialSample` for DNA-derived occurrences.

### Taxonomy — handle as a SEPARATE step, not inline
- `taxaFinal` sheet's taxonomy came from a DNA reference database, not
  WoRMS — names may not match WoRMS directly (spelling, rank, or may
  not exist in WoRMS at all).
- Decision made: **do not auto-match during core conversion**. Run
  WoRMS matching (`worrms::wm_records_names` or similar) as its own
  reviewable step (`04_worms_match.R`, not yet built) so ambiguous or
  unmatched names can be checked manually before they enter the final
  archive.
- For sequences with no confident species-level ID: `scientificName`
  = lowest confidently-known rank; for wholly unknown sequences: use
  `scientificName` = `"Incertae sedis"`, `scientificNameID` =
  `urn:lsid:marinespecies.org:taxname:12`.
- Keep the originally-assigned name in `verbatimIdentification` /
  `originalNameUsage` regardless of what WoRMS match is found.

## FAIRe file structure (input format)

Each `.xlsx` has sheets: `README`, `projectMetadata`, `sampleMetadata`,
`experimentRunMetadata`, `taxaRaw`, `taxaFinal`, `Drop-down values`,
`otuRaw`, `otuFinal`.

**Important quirk**: `sampleMetadata`, `experimentRunMetadata`, and
`taxaFinal` all have a **3-row header** before the data starts:
- row 1 = `requirement_level_code` (M/R/O/HR)
- row 2 = `section`
- row 3 = actual column names
- row 4+ = data

Always read with `col_names = FALSE` and manually promote row 3, see
`read_faire_sheet()` in `scripts/01_build_event_core.R`.

`otuFinal` is a straightforward ASV-by-sample matrix (ASV IDs as rows,
`samp_name` as columns, read counts as values) with a normal single
header row — no 3-row header quirk there.

## Status / what's built vs. not

- [x] `01_build_event_core.R` — done, validated against real data
      (490/490 unique eventIDs, all field mappings confirmed to exist)
- [x] `02_build_occurrence.R` — done, validated against real 16SFishD
      data (17,595 detections, 0 unresolved scientificName after the
      "dropped" placeholder fix). Handles the LCA pipeline's "dropped"
      placeholder values in taxaFinal by falling back to the column
      matching taxonRank; rows with taxonRank == "not applicable" get
      scientificName = "Incertae sedis". Excludes control samples
      (matches against the same real_event_ids as script 01).
- [x] `03_build_dna_extension.R` — done, validated against real
      MiFishUE2 data (18,607 detections, 0 missing DNA_sequence).
      Pulls PCR/primer/bioinformatics metadata from projectMetadata's
      long format (term_name x assay1..assay4), env_* fields joined
      back in from the Event core. Handles MiFishUE2 by combining
      projectMetadata's assay1 (MiFish-U) + assay3 (MiFish-E2) columns
      (see ASSAY_PROJECT_COLUMN in config.R) - **CONFIRMED with the
      user**: this project deliberately treats MiFish-U and MiFish-E2
      as one combined assay (that's why there are 3 files instead of
      4). Other OceanOmics projects may split them into two separate
      assays instead - re-check this mapping if reusing the pipeline
      elsewhere. Concatenation logic validated: shared values (e.g.
      target_gene) dedupe to one value, distinct values (e.g. primer
      sequences) concatenate with " | ".
- [x] `04_worms_match.R` — done (not yet run - needs an environment
      with network access + the `worrms` package). Collects every
      unique scientificName across all 3 Occurrence tables, batches
      through `worrms::wm_records_names`, writes 3 review files
      (`unmatched_names.csv`, `ambiguous_names.csv`,
      `non_marine_matches.csv`) that MUST be manually reviewed before
      publishing, then fills scientificNameID back into the Occurrence
      CSVs in place. Never guesses on ambiguous/unmatched names - those
      rows keep scientificNameID blank rather than a wrong guess.
      Deliberately matches by NAME, not by the NCBI taxonID already in
      taxaFinal - see "Why name-based WoRMS matching" below.
- [x] `05_qc_checks.R` — done (not yet run, same reason as above).
      Runs obistools' check_fields/check_eventdate/check_onland/
      check_extension_eventids, plus custom checks for: zero/out-of-
      range coordinates, occurrenceID consistency between each
      Occurrence table and its DNA Derived Data extension, and
      scientificNameID completeness post-WoRMS-matching.

## Why name-based WoRMS matching, not the existing NCBI taxonID

`taxaFinal` already carries `taxonID`/`taxonID_db` (an NCBI taxID), and
`worrms::wm_record_by_external(id, type = "ncbi")` could look up an
AphiaID directly from that ID. We deliberately do NOT do this, because:

1. WoRMS's external-ID crosswalk is incomplete - many valid WoRMS taxa
   have no NCBI ID cross-referenced, so ID-based lookup would report
   false "not found" results for taxa that are actually matchable by name.
2. More importantly: `taxonID` was assigned by the LCA pipeline at
   whatever rank it originally computed (often species-level), even for
   rows where we've deliberately backed `scientificName` off to a safer
   rank (see the "dropped" placeholder handling in script 02). Using
   `taxonID` to fetch an AphiaID would silently reintroduce a
   species-level identification exactly where we chose not to claim one.
   Matching by the (already rank-appropriate) `scientificName` string
   keeps the WoRMS match consistent with the confidence level already
   decided.

Only run WoRMS ID-based lookup as a secondary cross-check for rows
where `taxonRank == "species"` if you want extra confidence - not as
a replacement for name matching.

## Non-negotiables (don't "fix" these without asking)

- Don't merge the three assays into one Occurrence table — they must
  stay as three separate Occurrence extension tables sharing one Event
  core.
- Don't auto-run WoRMS matching inside the core-building scripts.
- Don't include control samples in the mapped Occurrence extension.
- Don't zero-pad incomplete dates.
