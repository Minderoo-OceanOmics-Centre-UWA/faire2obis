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
  (Note: `georeferenceSources` in `01_build_event_core.R` is currently
  left **blank** (`NA`) — the real GPS/positioning system used in the
  field hasn't been confirmed yet, and may even vary by vessel (the
  sample-tracking sheet shows both `RV Investigator` and `NA` under
  `Vessel`). OK for a test-server upload; **must be filled in with the
  confirmed source before this goes to the production/public IPT.**)

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
- [x] `03_build_dna_extension.R` — done AND run against real data
      (17,595 / 32,234 / 18,600 rows for 16SFishD / MarVer1 / MiFishUE2
      - matches script 02's Occurrence row counts exactly, by design:
      reads script 02's `Occurrence_<assay>.csv` output directly rather
      than re-deriving detections from `otuFinal` independently, so the
      two extensions can never drift out of sync). Pulls PCR/primer/
      bioinformatics metadata from projectMetadata's long format
      (term_name x assay1..assay4), env_* fields joined back in from
      the Event core, `associatedSequences` from `config.R`'s
      `ASSOCIATED_SEQUENCES_URI` (see below). Handles MiFishUE2 by
      combining projectMetadata's assay1 (MiFish-U) + assay3
      (MiFish-E2) columns (see ASSAY_PROJECT_COLUMN in config.R) -
      **CONFIRMED with the user**: this project deliberately treats
      MiFish-U and MiFish-E2 as one combined assay (that's why there
      are 3 files instead of 4). Other OceanOmics projects may split
      them into two separate assays instead - re-check this mapping if
      reusing the pipeline elsewhere. Concatenation logic validated:
      shared values (e.g. target_gene) dedupe to one value, distinct
      values (e.g. primer sequences) concatenate with " | ".
- [x] `04_worms_match.R` — done AND run (network + `worrms` +
      `remotes`-installed `obistools` all confirmed working). Collects
      every unique scientificName across all 3 Occurrence tables,
      batches through `worrms::wm_records_names`, resolves as much as
      possible WITHOUT guessing (in order): (1) a small manual
      `name_corrections` table for confirmed spelling/genus fixes and
      voucher-code-contaminated names (e.g. `Trachyrhamphus
      IFBIO334-17` -> `Trachyrhamphus`), (2) a `manual_aphia_overrides`
      table for names that are cross-kingdom homonyms where WoRMS has
      >1 `accepted` record for genuinely different organisms (e.g.
      `Centropogon`, `Howella` - fish vs. plant/algae with the same
      genus name), (3) auto-resolve to the sole `accepted` WoRMS record
      when a name returns >1 candidate but only one is `accepted` (the
      rest being unaccepted/synonym/junior-homonym/unassessed
      bookkeeping variants - reading WoRMS' own canonical pick, not a
      guess), logged to `ambiguous_resolved.csv` for audit. Anything
      still ambiguous (>1 or 0 `accepted` records) or unmatched keeps
      scientificNameID blank rather than a wrong guess. Current run:
      **100% scientificNameID coverage, 0 ambiguous, 0 unmatched**
      across all three assays. Deliberately matches by NAME, not by
      the NCBI taxonID already in taxaFinal - see "Why name-based
      WoRMS matching" below.
- [x] `05_qc_checks.R` — done AND run, all checks pass. Runs
      obistools' check_eventdate/check_onland/check_extension_eventids,
      plus custom checks for: zero/out-of-range coordinates,
      occurrenceID consistency between each Occurrence table and its
      DNA Derived Data extension, and scientificNameID completeness
      post-WoRMS-matching. **Fixed a real bug during first run**:
      `obistools::check_fields()`'s `level` argument does NOT select
      an Event-vs-Occurrence required-field set (there's no such
      concept in that function - it always checks one fixed combined
      list: eventDate, decimalLongitude, decimalLatitude,
      scientificName, scientificNameID, occurrenceStatus,
      basisOfRecord, and `level` only toggles the separate
      recommended-fields warning check). Calling it against the Event
      core alone or an Occurrence extension alone always "fails" on
      whichever fields live in the other table by design - not a real
      problem. Fixed by joining Occurrence + Event core by eventID
      before calling check_fields, which is what the function actually
      expects.

## Fields deliberately left out (audited against real data, not guessed)

Every one of `sampleMetadata`'s 146 columns and `taxaFinal`'s 24
columns was checked against actual population counts (not just
presence) before deciding what belongs in the archive - "public users
need it" was the bar, not "the FAIRe schema has a slot for it":

- **Added**: `geo_loc_name` (Event core - populated, real locality
  string); fixed `samplingProtocol`, which was silently blank because
  it only read `samp_collect_method` (0/628 populated) - now falls
  back to `samp_collect_device` (populated, e.g. "Underway system");
  `scientificNameAuthorship`, `identificationReferences` (built from
  taxaFinal's accession_id + accession_id_ref_db), and match-quality
  metrics (percent_match/percent_query_cover/confidence_score/
  unusual_size) appended into `identificationRemarks` (Occurrence
  extension - all found genuinely populated in taxaFinal but
  previously discarded).
- **Confirmed empty, not added**: the entire environmental-chemistry
  block (nutrients, chlorophyll, wind, light - 0/628 populated) and all
  DNA-extraction fields (nucl_acid_ext, concentration,
  samp_vol_we_dna_ext, materialSampleID - 0/628 populated). **No eMoF
  extension needed for this dataset** - re-check population counts
  first if reusing this pipeline for a project that actually fills
  those fields in, since an eMoF extension would be the right answer
  there.
- **`associatedSequences`**: `experimentRunMetadata`'s own
  `associatedSequences` column is empty for every row (0/580
  populated); per-sample raw FASTQ filenames (`filename`/`filename2`)
  exist but aren't publicly resolvable on their own. Real value comes
  from `config.R`'s `ASSOCIATED_SEQUENCES_URI` - the project's ENA
  accession (`PRJEB107937`, study accession `ERP188796`, confirmed
  public 2026-09-18) - applied as one constant across every row in
  both the Occurrence and DNA Derived Data extensions. If per-sample
  ENA run accessions ever become available, prefer those over this
  project-level constant.

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
