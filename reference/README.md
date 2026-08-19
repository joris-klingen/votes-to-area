# Reference tables

Hand-maintained lookup tables that turn the raw Kiesraad party names into
consistent, research-ready identities. They are loaded by `R/harmonize.R` and
applied to every aggregated table in the pipeline (`run.R`), so editing a CSV
here changes the harmonized `party_harmonized` / `green` columns everywhere.

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

Flags the harmonized parties that are green / environmental. Only green parties
are listed; any harmonized party absent from this table is treated as not green.

| column               | description                                                  |
|----------------------|--------------------------------------------------------------|
| `party`              | harmonized key (joins to `party` in the harmonization table) |
| `party_label`        | human-readable label                                         |
| `green`              | `green` (core environmental party) or `partly` (mixed/joint list with a green component) |
| `environmental_core` | `TRUE` if the environment is a core plank of the party       |
| `note`               | short rationale for the classification                       |

Classification used here:

- **green (core):** `GL` GroenLinks, `Groenen` De Groenen, `PvdD` Partij voor de
  Dieren.
- **partly green:** `GL-PvdA` (2023 combined list, GroenLinks half),
  `PP-Groenen` (2023 Piratenpartij–De Groenen joint list, De Groenen half),
  `Volt` (strong climate agenda, but not primarily an environmental party —
  a deliberately inclusive, borderline call; delete the row to exclude it).

Downstream, `harmonize_parties()` derives `is_green` (green **or** partly) and
`green_core` (green only), so an analysis can choose how inclusive to be. The
green time series in `scripts/plot_gl_pvda_2023.R` plots both a core and an
inclusive line.
