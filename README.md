# FAIRe2OBIS

**Convert FAIRe-formatted eDNA metabarcoding data into an OBIS-ready Darwin Core Archive — including multi-assay projects, which GBIF's Metabarcoding Data Toolkit (MDT) doesn't support.**

FAIRe2OBIS is a set of R scripts that turns [FAIRe](https://fair-edna.github.io/)-formatted eDNA metabarcoding spreadsheets into a standards-compliant [Darwin Core Archive](https://dwc.tdwg.org/text/) (DwC-A), ready to publish through an [IPT](https://www.gbif.org/ipt) to [OBIS](https://obis.org/) (or GBIF). It follows the [OBIS-ENV-DATA](https://manual.obis.org/dna_data.html) Event Core pattern used for DNA-derived occurrence data.

## Why this exists

Environmental DNA (eDNA) metabarcoding projects often collect one set of physical samples (water, soil, sediment) and run them through **several different primer sets ("assays")** to capture different taxonomic groups — for example, one primer targeting fish and another targeting a broader range of marine vertebrates. The lab and field metadata (dates, coordinates, depth, environmental readings) is identical across every assay, because it's the *same physical sample*; only the sequencing and taxonomic results differ.

GBIF's [Metabarcoding Data Toolkit (MDT)](https://mdt.gbif.org/) is a great tool for converting a single-assay OTU table into a Darwin Core Archive — but it assumes **one dataset = one assay**. Running each assay through MDT separately would publish the same physical samples three times over, tripling every shared piece of sample/location/environmental metadata across independent datasets. MDT's own user guide is explicit about this: *"Mixed datasets (e.g., different primer sets used for the same set of samples) should be published separately."*

FAIRe2OBIS solves this by building the archive the other way around:

- **One Event core** — each physical sample is written as a single Event, once.
- **One Occurrence extension per assay** — the detections (ASVs) from each primer set, linked back to the Event core via `eventID`.
- **One DNA Derived Data extension per assay** — the sequence, PCR, and bioinformatics metadata for each detection, linked via `occurrenceID` (and, for archive-level linking, `eventID`).

```mermaid
flowchart TD
    EC["Event core<br/>one row per physical sample"]
    O1["Occurrence extension<br/>Assay 1"]
    O2["Occurrence extension<br/>Assay 2"]
    ON["Occurrence extension<br/>Assay N"]
    D1["DNA Derived Data extension<br/>Assay 1"]
    D2["DNA Derived Data extension<br/>Assay 2"]
    DN["DNA Derived Data extension<br/>Assay N"]

    EC -- eventID --> O1 -- occurrenceID --> D1
    EC -- eventID --> O2 -- occurrenceID --> D2
    EC -- eventID --> ON -- occurrenceID --> DN
```

No sample metadata is duplicated across assays, and the resulting archive correctly represents "one sampling event, multiple assays run against it" rather than N unrelated datasets.

## Who this is for

Anyone with a FAIRe-formatted multi-assay eDNA metabarcoding dataset who wants to publish it to OBIS/GBIF without triplicating their sample metadata. It's configured out of the box for a specific project's file layout, but the pipeline is written to be adapted — see [Adapting this to your own project](#adapting-this-to-your-own-project) below.

## How it works: the pipeline

The pipeline is five R scripts, run in order, plus a shared `config.R`. Each script reads the previous step's output and writes its own — nothing runs automatically end-to-end, by design, so a human reviews the output of each stage (especially taxonomy matching) before it feeds into the next.

| Script | What it does |
|---|---|
| `config.R` | Central configuration: input file paths, project ID, the assay↔projectMetadata-column mapping, output paths, and control-sample handling rules. Edit this first when adapting the pipeline to a new project. |
| `01_build_event_core.R` | Reads `sampleMetadata` from every assay's FAIRe file, cross-checks that they agree on shared sample metadata (since it should be identical across assays), splits samples into real events vs. control samples, maps FAIRe/MIxS fields to Darwin Core Event/Location terms, and writes the single Event core. Control samples are written to a separate reference file, excluded from the published archive. |
| `02_build_occurrence.R` | Reshapes each assay's OTU table (ASV × sample read-count matrix) into one row per non-zero detection, joins in taxonomy, and builds one Darwin Core Occurrence extension per assay. Handles low-confidence identifications by falling back to the lowest taxonomic rank that was actually resolved, rather than publishing a placeholder value as if it were a real name. |
| `03_build_dna_extension.R` | Builds one DNA Derived Data extension per assay — the actual ASV/OTU sequence, PCR primer and amplicon details, sequencing platform, and bioinformatics pipeline metadata — linked to script 02's output via `occurrenceID`, and to the Event core via `eventID`. See [PCR value conventions](#pcr-value-conventions) for how ranges are written. |
| `04_worms_match.R` | Matches every scientific name produced by script 02 against the [World Register of Marine Species (WoRMS)](https://www.marinespecies.org/) to get a proper `scientificNameID`. Run as a deliberately separate, reviewable step — ambiguous or unmatched names are written to review files rather than guessed at, and only resolved automatically when doing so is unambiguous (e.g. picking WoRMS' own designated "accepted" record among several bookkeeping variants of the same name). |
| `05_qc_checks.R` | Runs a battery of validation checks against the finished archive before it goes anywhere near a publishing tool: required-field completeness, date formatting, coordinate sanity (on land / out of range / zero), cross-file ID consistency between the Event core and every extension, and taxonomy-match coverage. |

Run them in order from the project root:

```r
source("config.R")
source("scripts/01_build_event_core.R")
source("scripts/02_build_occurrence.R")
source("scripts/03_build_dna_extension.R")
source("scripts/04_worms_match.R")
source("scripts/05_qc_checks.R")
```

## Input format: FAIRe workbooks

Each input is a `.xlsx` workbook with (at minimum) these sheets: `projectMetadata`, `sampleMetadata`, `experimentRunMetadata`, `taxaFinal`, `otuFinal`.

`sampleMetadata`, `experimentRunMetadata`, and `taxaFinal` all have a 3-row header before the data starts (requirement level, section, then the actual column names) — the pipeline handles this automatically via `read_faire_sheet()`. `otuFinal` is a plain ASV-by-sample read-count matrix with a normal single header row.

## Output

```
output/
  event_core/Event.csv                    <- Darwin Core core
  occurrence/Occurrence_<assay>.csv        <- one Occurrence extension per assay
  dna_extension/DNADerivedData_<assay>.csv <- one DNA Derived Data extension per assay
  controls/sample_controls_reference.csv   <- excluded control samples (NOT part of the archive)
  worms_match/                             <- taxonomy-matching audit trail (NOT part of the archive)
```

Only the files in `event_core/`, `occurrence/`, and `dna_extension/` go into the published archive. `controls/` and `worms_match/` are working/audit output for your own review — negative and positive control samples are lab/field QC artifacts, not biodiversity occurrences, and don't belong in a public archive.

### PCR value conventions

Two DNA Derived Data terms are numeric in the GBIF definition but often hold more than one number in FAIRe sheets. The pipeline handles them like this:

| Term | GBIF type | FAIRe value | Written as | Why |
|---|---|---|---|---|
| `ampliconSize` | integer | a range, e.g. `178-228` | `178 \| 228` | Follows [NOAA Omics' metabarcoding-assay guidance](https://github.com/NOAA-Omics/noaa-omics-metabarcoding-assays#assay-preps): *"A range can be entered separated by a bar"*. A combined assay gets its overall range (MiFish-U `163-185` + MiFish-E2 `163-212` → `163 \| 212`). |
| `annealingTemp` | decimal | not one number, e.g. `54-56` for a touchdown PCR | left blank, and `annealingTemp recorded as 54-56 Celsius (not a single value)` added to `pcr_cond` | An average would be wrong for a touchdown PCR. Most OBIS metabarcoding datasets leave this blank and describe the profile in `pcr_cond`. |

`ampliconSize` written as `min | max` is still off-spec for an integer term, so the IPT may flag it. The app's Darwin Core mapping check reports it as expected rather than as an error.

## Publishing

This pipeline produces the files, not the archive itself — it deliberately targets a **generic IPT** upload rather than MDT, since MDT can't accommodate a multi-assay dataset. In IPT:

1. Create a new resource and upload `Event.csv` as the core (Core Type: `Event`, ID field: `eventID`).
2. Add each `Occurrence_<assay>.csv` as a source file, set as an `Occurrence` extension, and map its `eventID` column as the core-linking ID.
3. Add each `DNADerivedData_<assay>.csv` as a source file, set as a `DNA derived data` extension, and map its `eventID` column (not `occurrenceID`) as the core-linking ID — a Darwin Core Archive has no concept of "extension of an extension," so every extension must link back to the core's own ID.
4. Map remaining fields (most auto-map, since columns are already named as exact Darwin Core terms), add dataset metadata, and publish — to a test/UAT environment first.

## Requirements

- R (developed against 4.5.x)
- Packages: `readxl`, `dplyr`, `tidyr`, `readr`, `tibble`, `worrms`, `obistools`

`worrms` is on CRAN. `obistools` is not — install it from GitHub:

```r
install.packages(c("readxl", "dplyr", "tidyr", "readr", "tibble", "worrms", "remotes"))
remotes::install_github("iobis/obistools")
```

Running the web app below also needs: `shiny`, `bslib`, `bsicons`, `DT`, `ggplot2`, `zip`, `openxlsx`, `scales`, `maps`, `xml2`, `base64enc`, `aws.s3`, `sodium`, `emayili`. It also uses `curl` and `jsonlite`, which are installed with `worrms`.

## Web application

The five scripts above are also wrapped in a guided Shiny web app (`app.R`), for running the pipeline step by step without hand-editing `config.R` — upload, validate, build, review taxonomy matches, run QC, fill in metadata, then download or save the finished archive.

The app adds a few things the CLI scripts don't need:

- **Accounts and roles.** Visitors can browse the whole process as a guest, but downloading, saving a draft, or publishing requires a UWA (`@uwa.edu.au`) account, verified by an emailed code. Three roles control what a signed-in account can do:

  | Role | Can |
  |---|---|
  | **User** (default for every new signup) | Download the archive, save it to Draft |
  | **Publisher** | Everything a user can, plus move a draft into Publish |
  | **Admin** | Everything a publisher can, plus manage accounts and roles |

- **Draft / Publish storage.** A built archive can be saved to an S3 bucket as a timestamped draft, or published as that project's canonical `<project>_CoreVersion.zip` — both reviewable later from the app's Draft and Publish tabs, without re-running the pipeline.

- **Assay mapping (Step 3).** Each uploaded assay has to be matched to its `projectMetadata` column(s) (`assay1`, `assay2`, … any number of columns). The app suggests a match and shows every column as a card (assay name, target gene, target taxa, primers) for you to tick or untick. Suggestions are made in this order:
  1. `projectMetadata`'s own `assay_name` matches the file's assay name, ignoring case and punctuation (`MiFish-U` = `MiFishU`).
  2. A combined assay is built from several columns' names (`MiFishUE2` → `MiFish-U` + `MiFishE2`). This works even when the same project also has separate `MiFishU` and `MiFishE2` files.
  3. Otherwise, the single most similar column by primer or gene name.

  Always check the suggestion before building.

- **Not-marine review (Step 4).** After WoRMS matching, names WoRMS doesn't record as marine are listed with their WoRMS habitat, the number of records, and an **OBIS outcome**. This predicts what OBIS's own quality check ([`obis-qc`](https://github.com/iobis/obis-qc)) will do after publishing:

  | OBIS outcome | When | What happens |
  |---|---|---|
  | Kept | WoRMS: marine or brackish | Published normally |
  | Kept – marked unsure | WoRMS: no marine or brackish record (e.g. freshwater only) | Published, with a `MARINE_UNSURE` flag |
  | Will be dropped | WoRMS: marine = no **and** brackish = no | Hidden from OBIS searches (still in the dataset download) |

  The OBIS outcome is a review aid only and isn't written into the archive. OBIS publishes most of these taxa, and GBIF publishes all of them, so contamination has to be removed before upload:
  - **Check** opens a popup with tabs for WoRMS, OBIS (its habitat flags, verdict and existing record counts), FishBase or SeaLifeBase (picked automatically: fish vs other animals), GBIF (classification, common name, habitat for any organism) and Wikipedia.
  - **Exclude** removes that taxon from the Occurrence and DNA Derived Data files, and adds a sentence listing it to the `eml.xml` methods. Everything is kept unless you exclude it.

  The Check popup calls public APIs (WoRMS, OBIS, GBIF, Wikipedia; no keys needed), so it needs internet access and takes a few seconds to open. If one service is down, only that tab is affected.

Run it locally with:

```r
shiny::runApp()
```

It needs the environment variables below to actually save/publish or send login emails — without them, the app still runs, but those features are disabled rather than erroring.

**Local runs use the same S3 bucket as the live app.** Anything saved as a draft while testing is real and has to be deleted by hand.

## Deployment

The live app runs under [Shiny Server](https://posit.co/products/open-source/shiny-server/) on a Nectar Research Cloud VM (Pawsey region). The app folder on the server, `/srv/shiny-server/faire2obis`, is a git clone of this repository. To release a change:

1. Commit and push to `main`.
2. On the server:
   ```bash
   cd /srv/shiny-server/faire2obis
   git pull
   ```
3. No restart is needed: new sessions pick up the new code. After CSS changes, hard-refresh the browser (Ctrl+F5).

`.Renviron` is gitignored and was created on the server by hand, so `git pull` never touches it. Add any new environment variable there yourself. Install any new R package on the server so the `shiny` user can load it. If the app shows "Disconnected from server", check the newest log in `/var/log/shiny-server/`.

The `rsconnect/` folder is an old shinyapps.io deploy record and isn't used.

## Environment variables (`.Renviron`)

The web app (not the CLI scripts, which don't need any of this) reads its configuration from an `.Renviron` file placed next to `app.R`. Copy `.Renviron.example` to `.Renviron` and fill in real values — `.Renviron` itself is gitignored, so credentials never get committed.

**S3 — Draft/Publish archive storage** (see `R/archive_history.R`):

| Variable | Required | What it's for |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Yes | AWS credentials for the bucket that stores saved Draft/Publish archives |
| `AWS_SECRET_ACCESS_KEY` | Yes | — |
| `AWS_DEFAULT_REGION` | Yes | e.g. `ap-southeast-2` |
| `FAIRE2OBIS_S3_BUCKET` | No | Overrides the default bucket name |
| `FAIRE2OBIS_S3_PREFIX` | No | Overrides the default `biodiversity-public` parent folder for `Draft/`/`Publish/`/`Report/` |

**Email — account signup, login codes, and password resets** (see `R/user_auth.R`):

| Variable | Required | What it's for |
|---|---|---|
| `SMTP_USER` | Yes | The sending email address (verification codes, reset codes, and the failed-login warning email all come from this address) |
| `SMTP_PASSWORD` | Yes | An app password for that address — **not** its normal login password (Gmail: Account → Security → 2-Step Verification → App passwords) |
| `SMTP_HOST` | No | Defaults to `smtp.gmail.com`; set this to switch providers (e.g. `smtp-mail.outlook.com`) |
| `SMTP_PORT` | No | Defaults to `587` |
| `ALLOWED_EMAIL_DOMAIN` | No | Defaults to `uwa.edu.au` — only addresses on this domain can sign up |
| `SUPPORT_CONTACT_EMAIL` | No | Defaults to `oceanomics.tech@gmail.com` — shown to anyone outside the allowed domain, and in every "log in required" message |

Without the S3 variables, Download still works but Draft/Publish saving is hidden. Without the SMTP variables, nobody can sign up, log in, or reset a password — the account system has no fallback for this, since there is no account system without email verification.

## Adapting this to your own project

This repository ships pre-configured for one specific project's file layout. To reuse it for a different dataset, edit `config.R`:

- `INPUT_FILES` — path to each assay's FAIRe `.xlsx` file.
- `PROJECT_ID`, `EVENT_CORE_SOURCE_ASSAY` — which assay's `sampleMetadata` is treated as the source of truth (script 01 cross-checks the others against it).
- `ASSAY_PROJECT_COLUMN` — how your FAIRe files' assay names map to `projectMetadata`'s `assay1..assayN` columns. This is genuinely project-specific (which primer sets were run, and whether any were combined, e.g. MiFish-U + MiFish-E2 run as one `MiFishUE2` assay or as two separate assays) — don't assume it carries over unchanged. The web app suggests this mapping in Step 3 instead.
- `SAMPLE_CATEGORY_KEEP` — the `samp_category` value that marks a real (non-control) sample.
- `ASSOCIATED_SEQUENCES_URI` — a link/accession to where your raw sequence reads are archived (e.g. an ENA or SRA project accession). This pipeline doesn't auto-detect this; it comes from wherever your project deposited its raw reads.

Also worth checking rather than assuming: which `sampleMetadata`/`taxaFinal` columns are actually *populated* in your data before deciding what to map. Several fields with a slot in the FAIRe schema (environmental chemistry measurements, DNA extraction protocol details) may be entirely empty depending on what your project recorded — map what's real, not just what the schema allows for.

## Design principles

- **Never guess.** Ambiguous taxonomy matches, unresolved identifications, and missing metadata are surfaced for manual review, not silently filled in or defaulted.
- **Taxonomy matching is a separate, reviewable step**, not baked into the core-building scripts — so a human can check ambiguous or unmatched names before they enter a published archive.
- **Control samples never reach the published archive.**
- **Removing a taxon is always a person's decision, and always recorded.** Nothing is excluded automatically. An excluded taxon is listed in the `eml.xml` methods, so data users know what was removed and why.
- **Dates are never zero-padded** for unknown parts (e.g. `2011-03`, not `2011-03-00`) — a padded date asserts a day that was never actually recorded.

## Validated against real data

This isn't a hypothetical pipeline — it's been run end-to-end against the OcOm_2408 project's real FAIRe files (three assays, 628 total samples) and checked with [`obistools`](https://github.com/iobis/obistools) before being considered done.

*Charts below are drawn by the same code the web app uses for its own Step 7 analysis report (`R/build_report.R`) — not a separate look-alike, so the README can't quietly drift out of sync with what the app actually produces. Regenerate them after reprocessing a new dataset with `scripts/make_readme_charts.R`.*

### Samples

![Samples in the archive: 490 real samples, 138 controls excluded](docs/img/samples_breakdown.png)

490 real samples made it into the archive; 138 control samples (131 negative, 7 positive) were excluded as lab/field QC artifacts, not biodiversity occurrences.

### Detections per assay

![Detections per assay: 17,595 for 16SFishD, 32,234 for MarVer1, 18,600 for MiFishUE2](docs/img/detections_per_assay.png)

### Sampling locations

![Sampling locations: 98 distinct positions off the eastern Australian coast](docs/img/sampling_map.png)

### Most-detected taxa

![Ten most-detected taxa by total DNA sequence reads across all three assays](docs/img/top_taxa.png)

### Taxonomy resolved without guessing

670 unique scientific names went through WoRMS matching. Every one was resolved to a `scientificNameID` — none guessed:

| Resolution | Names | How |
|---|---:|---|
| Matched directly | 655 | A single, unambiguous WoRMS record |
| Corrected, then matched | 6 | Spelling fixes, stripped voucher/accession codes, and a wrong-kingdom homonym correction — each checked by hand against WoRMS and FishBase before applying |
| Auto-resolved | 7 | WoRMS returned multiple records, but exactly one was marked `accepted` — resolved to WoRMS' own canonical record, not a guess |
| Manually resolved | 1 | A cross-kingdom homonym with **two** `accepted` WoRMS records for genuinely different organisms (a fish genus and a red-algae genus sharing a name) — resolved by family, logged for audit |
| Fixed rank placeholder | 1 | `Biota incertae sedis` (WoRMS AphiaID 12's actual name, per OBIS's DNA-derived-data guidance), for the one case with no confident identification at any rank |
| **Total** | **670** | **100% resolved · 0 left ambiguous · 0 unmatched** |

Full audit trail, for review before publishing: `output/worms_match/matched_names.csv`, `ambiguous_resolved.csv`, `name_corrections_applied.csv`.

That table is about matching *confidence* (did a name get a WoRMS ID at all). A related but different question is *how precisely* each detection could be identified in the first place — some ASVs only confidently resolve to genus or family, not species:

![How far each detection was identified, by assay and taxonomic rank](docs/img/taxonomic_resolution.png)

### QC checks (`05_qc_checks.R`)

- [x] Required Darwin Core fields present (Event + Occurrence combined)
- [x] `eventID` unique in the Event core; `parentEventID` references valid
- [x] `eventDate` format valid
- [x] No zero, missing, or out-of-range coordinates
- [x] No coordinates falling on land
- [x] Every Occurrence and DNA Derived Data row's `eventID` exists in the Event core
- [x] Every Occurrence row has a matching DNA Derived Data row, and vice versa
- [x] 100% `scientificNameID` coverage

*(Charts generated from real pipeline output by `scripts/make_readme_charts.R`, using `ggplot2` — rerun it after reprocessing a new dataset to refresh the numbers.)*

## License

*(Not yet set — decide and add a license before making this repository public.)*

## Acknowledgements

Built on top of [Darwin Core](https://dwc.tdwg.org/), the [OBIS-ENV-DATA](https://manual.obis.org/dna_data.html) extension pattern, the [`worrms`](https://docs.ropensci.org/worrms/) R client for the [WoRMS](https://www.marinespecies.org/) REST API, and [`obistools`](https://github.com/iobis/obistools) for OBIS-specific QC checks.
