#!/usr/bin/env Rscript
# run.R
#
# End-to-end pipeline for the Dutch general elections (Tweede Kamer), 2012 to
# 2023: download the Kiesraad results, aggregate votes to the 4-digit postal
# code (PC4) level, and write long (tidy) tables of votes and vote share per
# party per area, plus a single combined file across all years.
#
# Usage:
#   Rscript run.R                # all default years (2012, 2017, 2021, 2023)
#   Rscript run.R 2021 2023      # only the given years
#
# Outputs are written as Parquet (via nanoparquet). A final panel layer rolls
# each election forward into the non-election years in between, giving one
# balanced yearly panel.
#
# For each year the pipeline uses PC4 when the polling-station postcode coverage
# clears `pc4_min_coverage`, otherwise it falls back to the municipality level.
# 2012 and 2017 have partial postcode coverage (~64-69%): PC4 output for those
# years omits the polling stations (and whole municipalities) that did not record
# a postcode in the source EML. Per-year coverage and the votes left unassigned
# are reported below and written to `*_unassigned_postcode.csv`.
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
source(file.path(project_root, "R", "panel.R"))

#' Write a data frame to Parquet with snappy compression.
write_output <- function(df, path) {
  nanoparquet::write_parquet(df, path, compression = "snappy")
  invisible(path)
}

# ---- Configuration ---------------------------------------------------------
DEFAULT_YEARS    <- c("2012", "2017", "2021", "2023")
PC4_MIN_COVERAGE <- 0.5   # use PC4 when >= 50% of station rows have a postcode

cli_years <- commandArgs(trailingOnly = TRUE)
years <- if (length(cli_years)) cli_years else DEFAULT_YEARS

raw_dir       <- file.path(project_root, "data", "raw")
processed_dir <- file.path(project_root, "data", "processed")
dir.create(processed_dir, recursive = TRUE, showWarnings = FALSE)

# ---- Per-year processing ---------------------------------------------------
all_data <- list()
summary_rows <- list()

for (year in years) {
  message("\n=== Tweede Kamer ", year, " ===")
  paths <- download_kiesraad_tk(year, raw_dir = raw_dir)
  res   <- aggregate_year(paths, pc4_min_coverage = PC4_MIN_COVERAGE)
  m     <- res$meta

  message(sprintf("Level: %s | postcode coverage: %s | %s areas x %s parties = %s rows | %s votes",
                  m$level,
                  if (is.na(m$coverage)) "n/a" else sprintf("%.1f%%", 100 * m$coverage),
                  format(m$n_areas, big.mark = ","),
                  m$n_parties,
                  format(m$n_rows, big.mark = ","),
                  format(m$total_votes, big.mark = ",")))

  # Per-year output.
  out_year <- file.path(processed_dir, sprintf("tk%s_%s_party_votes_long.parquet", year, m$level))
  write_output(res$data, out_year)
  message("Wrote ", out_year)

  # When PC4 was used, report the polling-station votes that had no postcode and
  # were therefore left out of the PC4 aggregation.
  unassigned_votes <- 0L
  if (m$level == "pc4" && !is.na(paths$stembureau_csv)) {
    votes   <- read_stembureau_votes(paths$stembureau_csv)
    missing <- votes[is.na(derive_pc4(votes$Postcode)), ]
    unassigned_votes <- sum(missing$AantalStemmen, na.rm = TRUE)
    if (nrow(missing) > 0) {
      out_missing <- file.path(processed_dir, sprintf("tk%s_unassigned_postcode.parquet", year))
      write_output(missing, out_missing)
      message(sprintf("  %s votes across %s stations had no postcode (excluded from PC4) -> %s",
                      format(unassigned_votes, big.mark = ","),
                      format(nrow(unique(missing[c("GemeenteCode", "StembureauCode")])), big.mark = ","),
                      basename(out_missing)))
    }
  }

  all_data[[year]] <- res$data
  summary_rows[[year]] <- data.frame(
    year = year, level = m$level,
    postcode_coverage = round(m$coverage, 4),
    areas = m$n_areas, parties = m$n_parties, rows = m$n_rows,
    votes_assigned = m$total_votes, votes_unassigned = unassigned_votes,
    stringsAsFactors = FALSE
  )
}

# ---- Combined output (election years only) ---------------------------------
combined <- dplyr::bind_rows(all_data)
out_combined <- file.path(processed_dir, "tk_all_years_party_votes_long.parquet")
write_output(combined, out_combined)
message("\nWrote combined file: ", out_combined,
        " (", format(nrow(combined), big.mark = ","), " rows)")

# ---- Panel: roll each election forward into non-election years -------------
# Only meaningful when more than one election year is present.
if (dplyr::n_distinct(combined$year) > 1) {
  panel <- build_panel(combined)
  out_panel <- file.path(processed_dir, "tk_panel_party_votes_long.parquet")
  write_output(panel, out_panel)
  message(sprintf("Wrote panel file: %s (%s calendar years %d-%d, %s rows)",
                  out_panel,
                  format(dplyr::n_distinct(panel$year), big.mark = ","),
                  min(panel$year), max(panel$year),
                  format(nrow(panel), big.mark = ",")))
}

# ---- Summary (kept as CSV for quick human inspection) ----------------------
summary_df <- dplyr::bind_rows(summary_rows)
out_summary <- file.path(processed_dir, "summary.csv")
readr::write_csv(summary_df, out_summary)
message("Wrote summary: ", out_summary)
message("")
print(summary_df, row.names = FALSE)
message("\nDone.")
