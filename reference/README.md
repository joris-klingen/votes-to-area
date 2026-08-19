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
alone). Unlisted raw names keep their own name as the harmonized identity.

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

Downstream, `harmonize_parties()` adds the boolean `green` column (TRUE for the
parties on this list). The bar charts in `scripts/plot_elections.R` use it for
the total and per-party green vote share.
