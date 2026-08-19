#!/usr/bin/env Rscript
# run.R
#
# End-to-end pipeline for the Dutch general elections (Tweede Kamer), 2012 to
# 2023: download the Kiesraad results, aggregate votes to both the 4-digit
# postal code (PC4) and the municipality (gemeente) level, harmonize party
# names and flag green/environmental parties, and roll each election forward
# into a balanced yearly panel. All outputs are long (tidy) Parquet.
#
# Usage:
#   Rscript run.R                # all default years (2012, 2017, 2021, 2023)
#   Rscript run.R 2021 2023      # only the given years
#
# Outputs under data/processed/ (per level in {pc4, gemeente}):
#   tk<year>_<level>_long.parquet     per-year long table
#   tk_<level>_all_years_long.parquet combined election years
#   tk_<level>_panel_long.parquet     rolled-forward yearly panel
#   summary.csv                       per-year PC4 postcode coverage & counts
#
# Long schema: year, level, area_code, area_name, party, votes,
#   valid_votes_area, vote_share, party_short, party_label, green
#   (+ source_year, is_election_year in the panels).
#
# Requires R packages: readr, dplyr, stringr, nanoparquet.

# ---- Locate project root (works under `Rscript run.R` and `source()`) ------
this_file <- tryCatch(normalizePath(sys.frame(1)$ofile), error = function(e) NULL)
if (is.null(this_file)) {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  this_file <- if (length(file_arg)) normalizePath(file_arg) else "run.R"
}
project_root <- dirname(this_file)

suppressPackageStartupMessages(library(nanoparquet))

source(file.path(project_root, "R", "download_data.R"))
source(file.path(project_root, "R", "aggregate.R"))
source(file.path(project_root, "R", "harmonize.R"))
source(file.path(project_root, "R", "panel.R"))

#' Write a data frame to Parquet with snappy compression.
write_output <- function(df, path) {
  nanoparquet::write_parquet(df, path, compression = "snappy")
  invisible(path)
}

# ---- Configuration ---------------------------------------------------------
DEFAULT_YEARS <- c("2012", "2017", "2021", "2023")

cli_years <- commandArgs(trailingOnly = TRUE)
years <- if (length(cli_years)) cli_years else DEFAULT_YEARS

raw_dir       <- file.path(project_root, "data", "raw")
processed_dir <- file.path(project_root, "data", "processed")
dir.create(processed_dir, recursive = TRUE, showWarnings = FALSE)

# Reference tables (loaded once) drive the harmonization + green flags.
harmonization <- load_party_harmonization(file.path(project_root, PARTY_HARMONIZATION_CSV))
green_class   <- load_green_classification(file.path(project_root, GREEN_CLASSIFICATION_CSV))
harmonize <- function(long) harmonize_parties(long, harmonization, green_class)

# ---- Per-year processing (both levels) -------------------------------------
levels_data <- list(pc4 = list(), gemeente = list())
summary_rows <- list()

for (year in years) {
  message("\n=== Tweede Kamer ", year, " ===")
  paths <- download_kiesraad_tk(year, raw_dir = raw_dir)
  votes <- read_stembureau_votes(paths$stembureau_csv)

  pc4_long <- harmonize(aggregate_to_pc4(votes, year))
  gem_long <- harmonize(aggregate_to_gemeente_from_stations(votes, year))
  coverage <- postcode_coverage(votes)

  message(sprintf("  postcode coverage %.1f%% | PC4: %s areas, %s rows | gemeente: %s areas, %s rows",
                  100 * coverage,
                  format(dplyr::n_distinct(pc4_long$area_code), big.mark = ","),
                  format(nrow(pc4_long), big.mark = ","),
                  format(dplyr::n_distinct(gem_long$area_code), big.mark = ","),
                  format(nrow(gem_long), big.mark = ",")))

  for (lv in c("pc4", "gemeente")) {
    d <- if (lv == "pc4") pc4_long else gem_long
    write_output(d, file.path(processed_dir, sprintf("tk%s_%s_long.parquet", year, lv)))
    levels_data[[lv]][[year]] <- d
  }

  summary_rows[[year]] <- data.frame(
    year = year, postcode_coverage = round(coverage, 4),
    pc4_areas = dplyr::n_distinct(pc4_long$area_code),
    gemeente_areas = dplyr::n_distinct(gem_long$area_code),
    parties = dplyr::n_distinct(pc4_long$party),
    stringsAsFactors = FALSE
  )
}

# ---- Combined + panel per level --------------------------------------------
for (lv in c("pc4", "gemeente")) {
  combined <- dplyr::bind_rows(levels_data[[lv]])
  write_output(combined, file.path(processed_dir, sprintf("tk_%s_all_years_long.parquet", lv)))
  message(sprintf("\nWrote tk_%s_all_years_long.parquet (%s rows)",
                  lv, format(nrow(combined), big.mark = ",")))

  if (dplyr::n_distinct(combined$year) > 1) {
    panel <- build_panel(combined)
    write_output(panel, file.path(processed_dir, sprintf("tk_%s_panel_long.parquet", lv)))
    message(sprintf("Wrote tk_%s_panel_long.parquet (%s calendar years %d-%d, %s rows)",
                    lv, format(dplyr::n_distinct(panel$year), big.mark = ","),
                    min(panel$year), max(panel$year), format(nrow(panel), big.mark = ",")))
  }
}

# ---- Summary ---------------------------------------------------------------
summary_df <- dplyr::bind_rows(summary_rows)
readr::write_csv(summary_df, file.path(processed_dir, "summary.csv"))
message("")
print(summary_df, row.names = FALSE)
message("\nDone.")
