# votes-to-area

Download the official Dutch general election results (Tweede Kamer) from the
Kiesraad open data and turn them into the project's headline product:

> **`green_share_pc4_panel.parquet` — the estimated green-party vote share of
> every 4-digit postal code (PC4), for every calendar year, rolled forward from
> the elections into the years in between.**

Along the way it also produces the general-purpose building blocks: votes
aggregated to the **PC4** and **municipality (gemeente)** levels in a **long /
tidy** table with each party's vote share, harmonized party names, green /
environmental party flags, and a balanced yearly panel.

> **Research use.** This repository is used for research on **green
> technologies**: it provides a geographically fine-grained, over-time measure
> of the political demand side — the local vote share of green / environmental
> parties — to relate to the adoption and diffusion of green technologies.

## What it does

For each election year it:

1. **Downloads** the Kiesraad "Verkiezingsuitslag(en) Tweede Kamer &lt;year&gt;"
   CSV bundle from [data.overheid.nl](https://data.overheid.nl/community/organization/kiesraad)
   (published by the Kiesraad / Dutch Electoral Council).
2. **Reads** `TK<year>_Stemmen_Per_Lijst_Per_Stembureau.csv` — one row per party
   per polling station (*stembureau*), including the polling station's postcode
   where it was recorded in the source EML files.
3. **Aggregates** to PC4 by summing the votes of **every polling station within
   a PC4 area**, and computes each party's **vote share** within the area.
4. **Writes** a long table with one row per `PC4 × party`, so it is trivial to
   re-aggregate (to municipality, province, party families, …), reshape wide,
   or stack years.

Finally it **merges the years into a panel**, rolling each election forward into
the non-election years in between (last observation carried forward).

All analytical outputs are written as **Parquet**.

## Outputs

Written to `data/processed/` (which is git-ignored — everything is reproducible
with `Rscript run.R`):

Every table is produced at **both** the `pc4` and the `gemeente` level (`<level>`
below is `pc4` or `gemeente`):

| file | contents |
|------|----------|
| **`green_share_pc4_panel.parquet`** | **the deliverable** — one row per `PC4 × calendar year`, estimated green vote share (see [*The green-share PC4 panel*](#the-green-share-pc4-panel)) |
| `green_share_pc4_elections.parquet` | the same estimates, election years only (not rolled forward) |
| `pc4_gemeente_weights.parquet` | PC4 → municipality crosswalk with vote-mass weights |
| `estimator_validation.csv` | leave-one-election-out scores of the estimator (`scripts/validate_estimator.R`) |
| `unmatched_parties.csv` | raw party names missing from the harmonization table, with their national share |
| `tk_<level>_panel_long.parquet`     | **the panel** — one balanced row per `year × area × party`, 2012–2023 |
| `tk_<level>_all_years_long.parquet` | combined election-year data (election years only) |
| `tk<year>_<level>_long.parquet`     | per-year long table |
| `tk<year>_unassigned_postcode.parquet` | polling-station rows with no postcode, excluded from that year's PC4 output |
| `summary.csv`                       | per-year postcode coverage and area/party counts |

The gemeente tables are the complete municipal tally (aggregated from all
polling stations, no postcode needed); the PC4 tables cover the postcode-tagged
stations only (see the coverage caveat below).

### Long schema (all `*_long` files)

| column               | description                                                        |
|----------------------|--------------------------------------------------------------------|
| `year`               | election year — or, in the panel, the **calendar** year            |
| `source_year`        | *(panel only)* the election the row's values were carried from     |
| `is_election_year`   | *(panel only)* TRUE when an election was actually held that year    |
| `level`              | area level: `pc4` or `gemeente`                                    |
| `area_code`          | PC4 code (e.g. `1011`), or CBS municipality code at gemeente level |
| `area_name`          | municipality name at gemeente level; empty at PC4 level (a PC4 can span municipalities) |
| `party`              | raw party name (`PartijNaam`) — the data is *long* in this dimension |
| `votes`              | summed votes for that party in that area (**NA** on imputed PC4 rows) |
| `valid_votes_area`   | total valid list votes in the area (**NA** on imputed PC4 rows)     |
| `vote_share`         | `votes / valid_votes_area` (shares sum to 1 within an area; imputed = the municipality's share) |
| `party_short`        | regular party abbreviation, stable across years (e.g. `PvdA`, `GL`, `VVD`) |
| `party_label`        | human-readable harmonized party name                              |
| `green`              | logical — TRUE for green / environmental parties (see reference tables) |
| `imputed`            | logical — TRUE where a PC4's shares were inferred from its municipality rather than observed (see *Imputation* below); always FALSE at gemeente level |

## The green-share PC4 panel

`data/processed/green_share_pc4_panel.parquet` is the product this repository
exists for: **one row per PC4 per calendar year**, with the estimated share of
votes going to green / environmental parties.

### Schema

| column | description |
|--------|-------------|
| `year` | calendar year (2012 … the current year) |
| `pc4` | 4-digit postal code, e.g. `1011` |
| `green_share` | **the estimate** — share of valid list votes going to green parties |
| `green_share_se` | approximate standard error of `green_share` |
| `green_core_share` | the ecological core only: PvdD + Volt + De Groenen (+ the 2023 Piratenpartij–De Groenen list) |
| `gl_pvda_family_share` | GroenLinks + PvdA + the 2023 GroenLinks-PvdA list, pooled so the series survives the merger |
| `pvdd_share`, `volt_share`, `groenen_family_share` | the individual components |
| `green_share_observed` | the raw observed share — `NA` where the PC4 was not observed that election |
| `green_share_municipal` | the naive municipal fill, for comparison |
| `green_votes`, `valid_votes` | observed vote counts (`NA` when not observed) |
| `observed` | TRUE when the election recorded polling-station postcodes in this PC4 |
| `estimate_method` | `observed`, `modelled_pc4_effect`, `modelled_municipal`, `modelled_national`, `not_on_ballot` |
| `pc4_effect` | the PC4's fitted log-odds deviation from its municipality (the persistent "how green is this postcode area" term) |
| `n_years_observed` | number of elections in which this PC4 was observed |
| `reference_level` | `gemeente` or `national` — the level the municipal reference share came from |
| `gem_code`, `gem_name`, `gem_weight` | the PC4's dominant municipality and its share of the PC4's votes |
| `source_year`, `election_date` | the election the row's values come from, and its polling day |
| `is_election_year` | TRUE when an election was held in `year` |

The group estimates are produced independently (each with its own shrinkage), so
`gl_pvda_family_share + green_core_share` only *approximately* equals
`green_share`; use `green_share` for the headline number.

### How the estimate is made

Postcodes are only partially recorded in the older elections (2012: ~69% of
votes, 2017: ~64%), so a large share of PC4-years is not directly observed and
has to be estimated. Simply giving an unobserved PC4 its municipality's share —
what the general-purpose tables' `imputed` rows do — throws away the most
informative fact available about that area: *how it votes relative to its
municipality in the years it is observed*. Within-municipality differences
between postcode areas are large and highly persistent, so the municipal fill is
worst for exactly the areas that carry the signal.

The estimator (`R/estimate.R`) therefore models the share on the log-odds scale:

```
logit(p_it) = logit(m_it) + d_i + e_it
```

- `m_it` — the vote-weighted share of the municipalit(y/ies) the PC4 lies in,
  taken from the **complete** municipal tally (observed for every municipality
  in the source, every year, no postcode needed);
- `d_i` — a **persistent PC4 effect**, pooled over the years the PC4 *is*
  observed with weights `1/(sampling variance + ψ²)`, then shrunk towards zero
  by an empirical-Bayes (DerSimonian–Laird) factor so a thinly observed PC4
  cannot acquire an over-fitted effect;
- `e_it` — the year-specific deviation with variance `ψ²`, the part that is not
  predictable. `τ²` (spread of the PC4 effects) and `ψ²` are estimated jointly
  by a short fixed-point iteration.

Each PC4-year is then the precision-weighted combination of the observation (if
any) and the model prediction:

- **observed** → posterior mean on the logit scale. A normal PC4 with thousands
  of votes is ~all observation; a PC4 with a handful of votes is pulled towards
  the model, which removes sampling noise from the panel;
- **unobserved** → the prediction `expit(logit(m_it) + d_i)`.

A party group that stood nowhere in a year (Volt before 2021) gets an exact
zero, flagged `not_on_ballot`.

### Does it actually help?

Two checks, both runnable:

```bash
Rscript scripts/selftest_estimator.R    # simulated data, no network needed
Rscript scripts/validate_estimator.R    # the real data, after `Rscript run.R`
```

`selftest_estimator.R` simulates a country with known PC4 effects, hides cells
at the real coverage rates, and scores the hidden truth: the model cuts RMSE on
unobserved cells from **5.07 pp to 2.18 pp (−57%)** against the municipal fill.

`validate_estimator.R` is the real test: it drops one election at a time,
re-estimates the PC4 effects **without** it, predicts that year out of sample and
scores against what was actually observed. It writes
`data/processed/estimator_validation.csv`.

### Rolling forward

Every calendar year takes the most recent election on or before it (last
observation carried forward), and the last election is carried forward to the
current year. Note that the 2023 election was held on **22 November** and the
2025 one on **29 October**: calendar year 2023 therefore carries a result that
only arrived at the very end of it. `election_date` is in the panel so a
research design that needs the lag can shift the year itself.

### What it cannot fix

- The PC4 comes from the **polling station's** postcode, not the voter's, so a
  PC4's share reflects *where people voted*. Station catchments are local, but
  in city centres and for large central polling locations the two differ.
- The PC4 universe is *the set of PC4s ever seen with a postcode in the source*
  (coverage reaches 92% of votes in 2023). PC4s that never appear — a handful of
  sparsely populated or non-residential ones — are absent from the panel; there
  is no PC4 register in the source data to complete it from.
- 2017 is limited **by source**: the Kiesraad machine-readable bundle covers only
  279 of 388 municipalities (see below). PC4s in a missing municipality get the
  national reference, flagged `reference_level = "national"`, which is a weak
  estimate — filter on it if that matters.

## The panel

Tweede Kamer elections are held irregularly. The panel gives one row per
**calendar year** by carrying the most recent election forward:

```
 2012 2013 2014 2015 2016 | 2017 2018 2019 2020 | 2021 2022 | 2023
 \_________ 2012 ________/  \______ 2017 ______/  \_ 2021 _/   2023
```

So e.g. `year = 2019` holds the 2017 result with `source_year = 2019 → 2017`
and `is_election_year = FALSE`. By default the panel runs from the earliest to
the latest election (2012–2023); pass a later `end_year` to `build_panel()` to
carry the last election forward to the present.

### Latest run

| year | postcode coverage | PC4 areas | parties | rows  | votes assigned | votes unassigned |
|------|-------------------|-----------|---------|-------|----------------|------------------|
| 2012 | 69.1%             | 2,478     | 20      | 49,560 | 6,538,938     | 2,882,664        |
| 2017 | 63.9%             | 1,544     | 28      | 37,454 | 4,274,561     | 2,460,674        |
| 2021 | 86.3%             | 3,011     | 37      | 92,672 | 8,880,316     | 1,538,442        |
| 2023 | 92.1%             | 3,086     | 26      | 76,965 | 9,547,465     |   884,702        |

Panel: **12 calendar years (2012–2023), 659,925 rows.**

> **Coverage caveat.** Postcodes were only partially recorded in the earlier
> elections. In **2012 and 2017** roughly a third of the votes come from polling
> stations without a postcode (including whole municipalities), so their PC4
> tables — and the 2012–2020 panel years derived from them — are **incomplete**;
> treat 2012/2017 PC4 shares as indicative, not a full geographic census.
> Coverage improves to 86% (2021) and 92% (2023). Unobserved PC4s are filled by
> municipality-level imputation and flagged (see *Imputation* below). Not every
> party appears in every PC4: the parties on the ballot vary by electoral
> district (*kieskring*), so a PC4 with no ballot line for a party simply has no
> row for it.

## Usage

```bash
# 1. Install R package dependencies (readr, dplyr, stringr, nanoparquet)
Rscript setup.R

# 2. Run the full pipeline for all default years (2012, 2017, 2021, 2023, 2025)
Rscript run.R

# ...or only specific years
Rscript run.R 2021 2023

# 3. (optional) cross-validate the PC4 estimator against the municipal fill
Rscript scripts/validate_estimator.R
```

`run.R` caches each download under `data/raw/`; delete it or call
`download_kiesraad_tk(year, force = TRUE)` to re-fetch. A year whose bundle
cannot be fetched is **skipped with a warning** rather than aborting the run —
check the warning before using the output, because the panel then simply does
not contain that election.

The **2025** bundle has no hard-coded resource URL: its
[dataset page](https://data.overheid.nl/dataset/verkiezingsuitslag-tweede-kamer-2025)
is read at download time and the "CSV formaat" ZIP link taken from it, so the
year works without editing `R/download_data.R`. If the page layout changes,
download the ZIP by hand into `data/raw/TK2025_CSV.zip`.

### Download / SSL errors

The downloader forces R's `libcurl` method (some R builds otherwise pick a
method that cannot negotiate TLS, which shows up as an "SSL connection" error),
sends a browser `User-Agent` (data.overheid.nl returns **403 Forbidden** to the
default R/curl agent), retries with backoff, and falls back to the `curl`
package if installed (`install.packages("curl")`). If your network still blocks the host, download
the ZIP manually in a browser and drop it into `data/raw/` with the expected
name (e.g. `data/raw/TK2023_CSV.zip`); the pipeline reuses the cached ZIP and
skips the download. The bundle URLs are listed in `TK_DATASETS` in
`R/download_data.R`.

## Imputation of unobserved PC4s (general-purpose tables)

> This is the **crude** fill used by the all-party `tk_*_long.parquet` tables.
> The green-share panel does not use it — see
> [*The green-share PC4 panel*](#the-green-share-pc4-panel) for the model that
> replaces it, and `green_share_municipal` in that file for the comparison.

Because postcodes are only partially recorded in the earlier elections, many PC4
areas have no observed votes in a given year (their municipality reported no
postcodes there). For those, the pipeline **imputes** the PC4's party shares
uniformly from its **municipality**: each party's PC4 share is set to that
party's municipal share, and the row is flagged **`imputed = TRUE`**. Only
*shares* are inferred — `votes` and `valid_votes_area` are left `NA` — so
observed and inferred cells are never mixed in a vote count.

- The PC4 → municipality mapping is a **self-contained crosswalk** built from the
  pooled observed postcodes across all years (no external data / network); a PC4
  seen in any election is placed, most-recent year wins.
- A PC4 can only be imputed if its municipality is present that year, so PC4s in
  municipalities missing from a year's source remain unfilled. This bites hardest
  in **2017**: the Kiesraad machine-readable data covers only **279 of 388
  municipalities** (the per-station/CSV bundle; the full EML bundle reaches just
  294 — the other ~94 municipalities filed paper-only counts that exist in no
  EML/CSV). 2017 gemeente and PC4 coverage is therefore partial by source, and
  that gap cannot be closed from Kiesraad open data.
- Toggle with `IMPUTE_PC4` in `run.R` (default `TRUE`). Filter `imputed == FALSE`
  for observed-only analysis.

Imputed rows flow through to the combined and **panel** PC4 tables. Latest run,
PC4s per year (observed + imputed): 2012 2,478 + 812; 2017 1,544 + 683; 2021
3,010 + 351; 2023 3,086 + 274.

## Levels & the 2010 election

Every year is produced at **both** the PC4 and the gemeente level. The gemeente
tables are complete; the PC4 tables cover the postcode-tagged stations only
(hence the coverage caveat above — for 2012/2017 the gemeente level is the
reliable one). The 2010 election (0% postcode coverage, gemeente-only) is
configured in `R/download_data.R` but excluded from the default run; add
`"2010"` to the years to produce its gemeente table.

## Party harmonization & green classification

Raw Kiesraad party names change spelling and formatting between years, so the
pipeline harmonizes them and flags green / environmental parties from two
editable reference tables in [`reference/`](reference/):

- `reference/party_harmonization.csv` — raw `source_party` → harmonized `party`
  key + `party_label` (e.g. `Democraten 66 (D66)` and `D66` both → `D66`;
  `GROENLINKS` → `GL`; the 2023 combined list → its own key `GL-PvdA`).
- `reference/green_classification.csv` — the flat list of harmonized parties
  treated as green / environmental. This is a deliberately **rough binary
  proxy** (a party is green or not); it includes GroenLinks, PvdA, the 2023
  GroenLinks-PvdA list, De Groenen, Partij voor de Dieren, Piratenpartij–De
  Groenen and Volt.

`R/harmonize.R` applies both and adds `party_short`, `party_label` and the
boolean `green`. See [`reference/README.md`](reference/README.md) for the
rationale. Edit a CSV and re-run `Rscript run.R` to change the classification
everywhere.

## Plotting (CPB house style)

`scripts/plot_elections.R` produces, in the CPB house style via the
[`ggcpb`](https://github.com/joris-klingen/ggcpb) package:

- per-municipality choropleths of the combined **GroenLinks-PvdA** vote share,
  one map per election (2012, 2017, 2021, 2023);
- bar charts (`cpb_col`) of the national vote share of **green / environmental**
  parties per election — a total, and a stacked composition by party.

The script **reads the processed Parquet tables only** (no downloading) — run
`Rscript run.R` first.

```bash
# ggcpb is not on CRAN — install it from GitHub first:
Rscript -e 'remotes::install_github("joris-klingen/ggcpb")'
Rscript scripts/plot_elections.R    # writes PNGs to figures/
```

The maps use `ggcpb::cpb_map(level = "gemeente")` and the bar charts
`ggcpb::cpb_col()`. Two caveats:

- **Maps are at the gemeente level.** ggcpb currently ships only
  gemeente/COROP/province boundaries; **PC4 maps will follow once ggcpb can plot
  postcode areas**.
- **Boundary vintage.** ggcpb bundles a single (recent) set of municipal
  boundaries, so municipalities that were merged away before then appear grey
  (`NA`) on the earlier-year maps (most visibly 2012).

## Project layout

```
votes-to-area/
├── setup.R                 # install dependencies (via Posit Public Package Manager)
├── run.R                   # end-to-end pipeline: download -> aggregate -> harmonize -> panel
├── R/
│   ├── download_data.R     # per-year download config + fetch/extract
│   ├── aggregate.R         # read, derive PC4, aggregate to PC4/gemeente (long)
│   ├── harmonize.R         # apply party harmonization + green flags
│   ├── estimate.R          # empirical-Bayes PC4 share estimator (the model)
│   ├── green_panel.R       # green party groups -> PC4 x calendar-year panel
│   └── panel.R             # roll elections forward into a yearly panel
├── reference/
│   ├── party_harmonization.csv   # raw -> harmonized party names
│   ├── green_classification.csv  # green / environmental party flags
│   └── README.md                 # rationale for both tables
├── scripts/
│   ├── plot_elections.R      # GL-PvdA gemeente maps + green time series via ggcpb
│   ├── selftest_estimator.R  # estimator check on simulated data (no network)
│   └── validate_estimator.R  # leave-one-election-out validation on the real data
└── data/
    ├── raw/                # downloaded source data (git-ignored)
    └── processed/          # generated Parquet outputs (git-ignored)
```

## Using the functions directly

```r
source("R/download_data.R"); source("R/aggregate.R")
source("R/harmonize.R"); source("R/panel.R")
library(dplyr); library(nanoparquet)

paths <- download_kiesraad_tk("2023")                 # download + extract one year
votes <- read_stembureau_votes(paths$stembureau_csv)
gem   <- harmonize_parties(aggregate_to_gemeente_from_stations(votes, "2023"))

# Or just read the processed panels back:
panel <- read_parquet("data/processed/tk_gemeente_panel_long.parquet")

# The deliverable: green vote share per PC4 per calendar year.
green <- read_parquet("data/processed/green_share_pc4_panel.parquet")
green %>% filter(year == 2019) %>% select(pc4, green_share, estimate_method)

# Observed-only subset, if you would rather not use modelled cells:
green %>% filter(observed)

# Long + harmonized + green-flagged, so national green share per year is one step:
panel %>%
  filter(is_election_year) %>%
  group_by(year) %>%
  summarise(green_share = sum(votes[green]) / sum(votes))
```

## Notes & caveats

- This is **research data**, not the certified official result (per the Kiesraad
  README shipped in each bundle).
- An area's `vote_share` denominator is the **valid list votes** in that area;
  blank and invalid votes are not part of the per-list source files. (Some years
  include registered "Blanco (lijst NN)" *lists* — treated as ordinary parties,
  as in the source.)
- A PC4 area is assigned from the postcode of each **polling station**, not of
  the voters, so PC4 totals reflect *where people voted*, not strictly where they
  live.
- Party names **are** harmonised across years via `reference/party_harmonization.csv`
  (`party_short` / `party_label`). Raw names missing from that table keep their
  own name and are therefore **not** flagged green — `run.R` lists them, with
  their national vote share, and writes `data/processed/unmatched_parties.csv`.
  Check it after every new election.

## Data source & licence

Kiesraad, *Verkiezingsuitslag(en) Tweede Kamer 2012/2017/2021/2023*, via
[data.overheid.nl](https://data.overheid.nl/community/organization/kiesraad)
(CC0 / public domain). The Kiesraad does not provide support for the source
formats.
