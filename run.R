#!/usr/bin/env Rscript
# run.R
#
# End-to-end pipeline: download the Kiesraad TK2023 election results, aggregate
# votes to the 4-digit postal code (PC4) level, and write a long (tidy) table
# of votes and vote share per party per PC4.
#
# Usage:
#   Rscript run.R
#
# Outputs (under data/processed/):
#   - pc4_party_votes_long.csv   one row per PC4 x party
#   - pc4_missing_postcode.csv   polling-station rows that lacked a postcode
#
# Requires R packages: readr, dplyr, stringr.

# Resolve the project root so the script works from any working directory.
this_file <- tryCatch(
  normalizePath(sys.frame(1)$ofile),
  error = function(e) NULL
)
if (is.null(this_file)) {
  # Fallback for `Rscript run.R` invocation.
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  this_file <- if (length(file_arg)) normalizePath(file_arg) else "run.R"
}
project_root <- dirname(this_file)

source(file.path(project_root, "R", "download_data.R"))
source(file.path(project_root, "R", "aggregate_pc4.R"))

raw_dir       <- file.path(project_root, "data", "raw")
processed_dir <- file.path(project_root, "data", "processed")
dir.create(processed_dir, recursive = TRUE, showWarnings = FALSE)

# 1. Download & extract the Kiesraad per-polling-station CSV.
csv_path <- download_kiesraad_tk2023(raw_dir = raw_dir)

# 2. Read the raw per-polling-station votes.
votes <- read_stembureau_votes(csv_path)
# StembureauCode is only unique within a municipality, so identify a polling
# station by the (GemeenteCode, StembureauCode) pair.
n_stations <- nrow(unique(votes[c("GemeenteCode", "StembureauCode")]))
message(sprintf("Read %s rows across %s polling stations and %s parties.",
                format(nrow(votes), big.mark = ","),
                format(n_stations, big.mark = ","),
                length(unique(votes$PartijNaam))))

# 3. Aggregate to PC4 x party (long format).
pc4_long <- aggregate_votes_to_pc4(votes, drop_missing_pc4 = TRUE)
message(sprintf("Aggregated to %s PC4 areas x %s parties = %s rows.",
                format(length(unique(pc4_long$pc4)), big.mark = ","),
                length(unique(pc4_long$party)),
                format(nrow(pc4_long), big.mark = ",")))

# 4. Report on rows that could not be assigned to a PC4 (no postcode in EML).
missing <- votes[is.na(derive_pc4(votes$Postcode)), ]
if (nrow(missing) > 0) {
  n_missing_stations <- nrow(unique(missing[c("GemeenteCode", "StembureauCode")]))
  message(sprintf("Note: %s rows (%s polling stations) had no postcode and are excluded from PC4 output.",
                  format(nrow(missing), big.mark = ","),
                  format(n_missing_stations, big.mark = ",")))
}

# 5. Write outputs.
out_main <- file.path(processed_dir, "pc4_party_votes_long.csv")
readr::write_csv(pc4_long, out_main)
message("Wrote ", out_main)

out_missing <- file.path(processed_dir, "pc4_missing_postcode.csv")
readr::write_csv(missing, out_missing)
message("Wrote ", out_missing)

message("Done.")
