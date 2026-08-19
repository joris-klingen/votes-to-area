# votes-to-area

Download the official 2023 Dutch general election results (Tweede Kamer,
22 November 2023) from the Kiesraad open data and aggregate the votes to the
**4-digit postal code (PC4)** level, in a **long / tidy** table with the share
of votes per political party.

## What it does

1. **Downloads** the Kiesraad "Verkiezingsuitslag Tweede Kamer 2023" CSV bundle
   from [data.overheid.nl](https://data.overheid.nl/dataset/verkiezingsuitslag-tweede-kamer-2023)
   (published by the Kiesraad / Dutch Electoral Council).
2. **Reads** `TK2023_Stemmen_Per_Lijst_Per_Stembureau.csv` — one row per party
   per polling station (*stembureau*), including the polling station's postcode
   where it was recorded in the source EML files.
3. **Aggregates** to PC4 by taking the **sum of votes of every polling station
   within a PC4 area**, and computes each party's **vote share** within the area.
4. **Writes** a long table with one row per `PC4 × party`, so it is trivial to
   re-aggregate (to municipality, province, party families, …) or reshape wide.

## Output

`data/processed/pc4_party_votes_long.csv`

| column            | description                                                        |
|-------------------|--------------------------------------------------------------------|
| `pc4`             | 4-digit postal code (e.g. `1011`)                                  |
| `party`           | party name (`PartijNaam`) — the data is *long* in this dimension   |
| `votes`           | summed votes for that party across all polling stations in the PC4 |
| `valid_votes_pc4` | total valid list votes in the PC4 (sum over all parties)           |
| `vote_share`      | `votes / valid_votes_pc4` (shares sum to 1 within a PC4)           |

`data/processed/pc4_missing_postcode.csv` holds the raw polling-station rows that
had **no postcode** in the source data (mobile / postal-vote / some special
stations) and are therefore excluded from the PC4 output.

Latest run: **3,086 PC4 areas**, **26 parties**, **76,965 rows**. About 793
polling stations (~0.8M votes) lack a postcode and are reported separately.
(Not every party appears in every PC4: the parties on the ballot vary by
electoral district / *kieskring*, so a PC4 that had no ballot line for a party
simply has no row for it.)

## Usage

```bash
# 1. Install R package dependencies (readr, dplyr, stringr)
Rscript setup.R

# 2. Run the full pipeline: download -> aggregate -> write CSVs
Rscript run.R
```

`run.R` caches the download under `data/raw/` (git-ignored); delete it or call
`download_kiesraad_tk2023(force = TRUE)` to re-fetch.

## Project layout

```
votes-to-area/
├── setup.R                 # install dependencies (via Posit Public Package Manager)
├── run.R                   # end-to-end pipeline entry point
├── R/
│   ├── download_data.R     # download & extract the Kiesraad CSV bundle
│   └── aggregate_pc4.R     # read, derive PC4, aggregate to PC4 × party (long)
└── data/
    ├── raw/                # downloaded source data (git-ignored)
    └── processed/          # generated outputs
```

## Using the functions directly

```r
source("R/download_data.R")
source("R/aggregate_pc4.R")

csv   <- download_kiesraad_tk2023()          # -> path to the source CSV
votes <- read_stembureau_votes(csv)          # raw per-polling-station rows
pc4   <- aggregate_votes_to_pc4(votes)        # long PC4 × party table

# Because it is long, re-aggregating is a one-liner, e.g. national share:
library(dplyr)
pc4 %>%
  group_by(party) %>%
  summarise(votes = sum(votes)) %>%
  mutate(share = votes / sum(votes)) %>%
  arrange(desc(votes))
```

## Notes & caveats

- This is **research data**, not the certified official result (per the Kiesraad
  README shipped in the bundle).
- A PC4's `vote_share` denominator is the **valid list votes** in that area;
  blank and invalid votes are not part of the per-list source file.
- A PC4 area is assigned from the postcode of each **polling station**, not of
  the voters. Voters may cast their ballot outside their home postcode, so PC4
  totals reflect *where people voted*, not strictly where they live.

## Data source & licence

Kiesraad, *Verkiezingsuitslag Tweede Kamer 2023*, via
[data.overheid.nl](https://data.overheid.nl/dataset/verkiezingsuitslag-tweede-kamer-2023)
(CC0 / public domain). The Kiesraad does not provide support for the source
formats.
