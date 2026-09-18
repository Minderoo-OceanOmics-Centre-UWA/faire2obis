# oceanomics-faire2obis

Converts OceanOmics FAIRe-format eDNA metabarcoding metadata into a
**Darwin Core Event core + per-assay Occurrence extensions + DNA Derived
Data extensions**, ready for upload to an OBIS node IPT.

## Why Event core (not the MDT/Occurrence-core route)

This project sequences the **same physical water samples** with multiple
assays (e.g. 16SFishD, MarVer1, MiFishUE2). The GBIF Metabarcoding Data
Toolkit (MDT) and the existing `FAIRe2MDT.R` script assume one dataset =
one assay, and would produce three independent Occurrence-core datasets,
each repeating the same sample/location/date/environmental metadata.

Instead, this pipeline builds:

- **One Event core** — one row per physical sample (`eventID`), holding
  everything that doesn't change between assays: coordinates, eventDate,
  depth, environmental measurements, sampling method, etc. Built once
  from `sampleMetadata`, verified identical across all assay files.
- **One Occurrence extension per assay** — ASV/taxon detections for that
  assay, each row linked back to its `eventID`.
- **One DNA Derived Data extension per assay** — sequencing/PCR metadata
  (primers, target gene, sequencing method) linked via `occurrenceID`.
- **Control samples** (negative/positive) are pulled out into a separate,
  unmapped file — not included in the Occurrence extension.

## Repo structure

```
config.R                        # paths, project settings
scripts/
  01_build_event_core.R         # sampleMetadata -> Event core (once, shared)
  02_build_occurrence.R         # taxaFinal + otuFinal -> Occurrence ext (per assay)
  03_build_dna_extension.R      # experimentRunMetadata -> DNA Derived Data ext (per assay)
  04_worms_match.R              # scientificName -> scientificNameID via WoRMS (separate, reviewable step)
  05_qc_checks.R                # obistools checks before IPT upload
output/
  event_core/                   # Event.csv
  occurrence/                   # Occurrence_<assay>.csv (one per assay)
  dna_extension/                # DNADerivedData_<assay>.csv (one per assay)
  controls/                     # Controls_<assay>.csv (excluded from Occurrence, kept for reference)
data/                           # raw FAIRe .xlsx files (not committed - see .gitignore)
```

## Status

- [x] Verified: sample metadata is identical across all 3 assay files (628/628 samples, 0 mismatches)
- [x] `01_build_event_core.R` — Event core builder
- [ ] `02_build_occurrence.R`
- [ ] `03_build_dna_extension.R`
- [ ] `04_worms_match.R`
- [ ] `05_qc_checks.R`

## Running

```r
source("config.R")
source("scripts/01_build_event_core.R")
```
