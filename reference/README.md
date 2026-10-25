# Reference tables

Hand-maintained lookup tables that turn the raw Kiesraad party names into
consistent, research-ready identities. They are loaded by `R/harmonize.R` and
applied to every aggregated table in the pipeline (`run.R`), so editing a CSV
here changes the harmonized `party_short` / `green` columns everywhere.

## `party_harmonization.csv`

One row per **raw** party name as it appears in the Kiesraad files (party names
change spelling and formatting between years), mapping it to a stable
harmonized identity.

| column         | description                                                    |
|----------------|----------------------------------------------------------------|
| `source_party` | the raw `PartijNaam` exactly as in the Kiesraad data            |
| `party`        | harmonized short key, stable across years (e.g. `CDA`, `GL`)    |
| `party_label`  | human-readable label for the harmonized party                  |

Names that collapse across years include: `Democraten 66 (D66)` / `D66` →
`D66`; `Christen Democratisch Appèl (CDA)` / `CDA` → `CDA`;
`LP (Libertaire Partij)` / `Libertarische Partij (LP)` → `LP`. `GROENLINKS`
maps to `GL` and `Partij van de Arbeid (P.v.d.A.)` to `PvdA`, while the 2023
joint list `GROENLINKS / Partij van de Arbeid (PvdA)` is its **own** identity
`GL-PvdA` (it is a distinct combined list, not the same object as either party
alone). The 2025 spellings `Nieuw Sociaal Contract (NSC)`,
`Belang Van Nederland (BVNL)` and `NL PLAN` join `NSC`, `BVNL` and
`Nederland met een PLAN`. Unlisted raw names keep their own name as the
harmonized identity.

## `green_classification.csv`

The flat list of harmonized parties treated as green / environmental. This is a
deliberately **rough binary proxy**: a party is either on the list (green) or
not. Any harmonized party absent from this table is not green.

| column        | description                                                  |
|---------------|--------------------------------------------------------------|
| `party`       | harmonized key (joins to `party` in the harmonization table) |
| `party_label` | human-readable label                                         |
| `note`        | short rationale for including the party                      |

Parties on the list: `GL` GroenLinks, `PvdA`, `GL-PvdA` (2023 combined list),
`Groenen` De Groenen, `PvdD` Partij voor de Dieren, `PP-Groenen` (2023
Piratenpartij–De Groenen), `Volt`. PvdA is included as a rough proxy (it ran a
joint list with GroenLinks in 2023); delete its row to exclude it.

`Vrede voor Dieren` (an animal-rights list new in 2025) is **not** on the list;
add a row for it if you count it alongside `PvdD`.

Downstream, `harmonize_parties()` adds the boolean `green` column (TRUE for the
parties on this list). The bar charts in `scripts/plot_elections.R` use it for
the total and per-party green vote share.

## `gemeente_crosswalk.csv` and `gemeente_periods.csv`

Municipal boundary history, generated from CBS StatLine 70739ned (*Gebieden;
overzicht vanaf 1830*) by `scripts/build_gemeente_crosswalk.R` — regenerate
rather than edit by hand. `R/boundaries.R` uses them to build the
`gemeente2025` tables (every election on the 2025 municipalities).

`gemeente_crosswalk.csv` — one row per municipality code valid at any point
since 2010 and per 2025 municipality it went to:

| column      | description                                                         |
|-------------|---------------------------------------------------------------------|
| `from_code` | CBS municipality code as used by the Kiesraad (no leading zeros)    |
| `from_name` | its name                                                            |
| `to_code`   | the 2025 municipality it belongs to                                 |
| `to_name`   | that municipality's name                                            |
| `weight`    | share of `from_code`'s inhabitants that went to `to_code` (1 for a merge; a split's weights sum to 1) |

Codes that still exist map to themselves with weight 1.

`gemeente_periods.csv` — each code's validity period (`code`, `cbs_code`,
`name`, `begin_date`, `end_date`; `end_date` empty = still exists), used to
know which municipalities existed on each election day.
