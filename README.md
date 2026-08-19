# votes-to-area

Download the official Dutch general election results (Tweede Kamer) for
**2012, 2017, 2021 and 2023** from the Kiesraad open data and aggregate the
votes to the **4-digit postal code (PC4)** level, in a **long / tidy** table
with the share of votes per political party — then roll the elections forward
into a balanced **yearly panel**.

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

| file | contents |
|------|----------|
| `tk_panel_party_votes_long.parquet`     | **the panel** — one balanced row per `year × PC4 × party`, 2012–2023 |
| `tk_all_years_party_votes_long.parquet` | combined election-year data (election years only) |
| `tk<year>_pc4_party_votes_long.parquet` | per-year long table |
| `tk<year>_unassigned_postcode.parquet`  | polling-station rows with no postcode, excluded from that year's PC4 output |
| `summary.csv`                           | per-year level, postcode coverage, area/party/row counts, votes assigned vs. unassigned |

### Long schema (all `*_long` files)

| column             | description                                                        |
|--------------------|--------------------------------------------------------------------|
| `year`             | election year — or, in the panel, the **calendar** year            |
| `source_year`      | *(panel only)* the election the row's values were carried from     |
| `is_election_year` | *(panel only)* TRUE when an election was actually held that year    |
| `level`            | area level: `pc4` (or `gemeente` for the fallback, see below)      |
| `area_code`        | PC4 code (e.g. `1011`), or CBS municipality code at gemeente level |
| `area_name`        | municipality name at gemeente level; empty at PC4 level (a PC4 can span municipalities) |
| `party`            | party name (`PartijNaam`) — the data is *long* in this dimension   |
| `votes`            | summed votes for that party in that area                           |
| `valid_votes_area` | total valid list votes in the area (sum over all parties)          |
| `vote_share`       | `votes / valid_votes_area` (shares sum to 1 within an area)        |

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
> Coverage improves to 86% (2021) and 92% (2023). Not every party appears in
> every PC4: the parties on the ballot vary by electoral district (*kieskring*),
> so a PC4 with no ballot line for a party simply has no row for it.

## Usage

```bash
# 1. Install R package dependencies (readr, dplyr, stringr, nanoparquet)
Rscript setup.R

# 2. Run the full pipeline for all default years (2012, 2017, 2021, 2023)
Rscript run.R

# ...or only specific years
Rscript run.R 2021 2023
```

`run.R` caches each download under `data/raw/`; delete it or call
`download_kiesraad_tk(year, force = TRUE)` to re-fetch.

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

## Municipality fallback

The pipeline can fall back to the **municipality (gemeente)** level for years
whose postcode coverage is too low to be meaningful (below `PC4_MIN_COVERAGE`,
default 50% in `run.R`). At that setting all of 2012–2023 use PC4. The 2010
election (0% postcode coverage) is configured in `R/download_data.R` but excluded
from the default run because it would have to fall back to municipality; add
`"2010"` to the years to produce a gemeente-level table for it. Raise
`PC4_MIN_COVERAGE` (e.g. `> 0.7`) to send 2012/2017 to the municipality level too.

## Project layout

```
votes-to-area/
├── setup.R                 # install dependencies (via Posit Public Package Manager)
├── run.R                   # end-to-end pipeline: download -> aggregate -> panel
├── R/
│   ├── download_data.R     # per-year download config + fetch/extract
│   ├── aggregate.R         # read, derive PC4, aggregate to PC4/gemeente (long)
│   └── panel.R             # roll elections forward into a yearly panel
└── data/
    ├── raw/                # downloaded source data (git-ignored)
    └── processed/          # generated Parquet outputs (git-ignored)
```

## Using the functions directly

```r
source("R/download_data.R"); source("R/aggregate.R"); source("R/panel.R")
library(dplyr); library(nanoparquet)

paths    <- download_kiesraad_tk("2023")          # download + extract one year
res      <- aggregate_year(paths)                  # list(data = long tibble, meta)
combined <- bind_rows(lapply(c("2012","2017","2021","2023"),
                             \(y) aggregate_year(download_kiesraad_tk(y))$data))
panel    <- build_panel(combined)                  # rolled-forward yearly panel

# Read an output back:
read_parquet("data/processed/tk_panel_party_votes_long.parquet")

# Because it is long, re-aggregating is a one-liner, e.g. national share per year:
combined %>%
  group_by(year, party) %>% summarise(votes = sum(votes), .groups = "drop_last") %>%
  mutate(share = votes / sum(votes)) %>% arrange(year, desc(votes))
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
- Party names are **not** harmonised across years (e.g. the 2023
  "GROENLINKS / Partij van de Arbeid (PvdA)" combination). Map them yourself if
  you need consistent party identities over time.

## Data source & licence

Kiesraad, *Verkiezingsuitslag(en) Tweede Kamer 2012/2017/2021/2023*, via
[data.overheid.nl](https://data.overheid.nl/community/organization/kiesraad)
(CC0 / public domain). The Kiesraad does not provide support for the source
formats.
