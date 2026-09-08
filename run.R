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
#   green_share_pc4_panel.parquet     HEADLINE: estimated green vote share per
#                                     PC4 per calendar year (see R/estimate.R)
#   green_share_pc4_elections.parquet the same, election years only
#   pc4_gemeente_weights.parquet      PC4 -> municipality crosswalk with weights
#   summary.csv                       per-year PC4 postcode coverage & counts
#
# Long schema: year, level, area_code, area_name, party, votes,
#   valid_votes_area, vote_share, party_short, party_label, green, imputed
#   (+ source_year, is_election_year in the panels). At the PC4 level, PC4s a
#   year did not observe are imputed uniformly from their municipality's shares
#   and flagged imputed = TRUE (votes/valid_votes_area are NA there).
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
source(file.path(project_root, "R", "estimate.R"))
source(file.path(project_root, "R", "green_panel.R"))

#' Write a data frame to Parquet with snappy compression.
write_output <- function(df, path) {
  nanoparquet::write_parquet(df, path, compression = "snappy")
  invisible(path)
}

# ---- Configuration ---------------------------------------------------------
DEFAULT_YEARS <- c("2012", "2017", "2021", "2023", "2025")
IMPUTE_PC4    <- TRUE   # impute unobserved PC4s from their municipality's shares
# Last calendar year of the rolled-forward panels; the last election is carried
# forward to here. Defaults to the current year.
PANEL_END_YEAR <- as.integer(format(Sys.Date(), "%Y"))

cli_years <- commandArgs(trailingOnly = TRUE)
years <- if (length(cli_years)) cli_years else DEFAULT_YEARS

raw_dir       <- file.path(project_root, "data", "raw")
processed_dir <- file.path(project_root, "data", "processed")
dir.create(processed_dir, recursive = TRUE, showWarnings = FALSE)

# Reference tables (loaded once) drive the harmonization + green flags.
harmonization <- load_party_harmonization(file.path(project_root, PARTY_HARMONIZATION_CSV))
green_class   <- load_green_classification(file.path(project_root, GREEN_CLASSIFICATION_CSV))
harmonize <- function(long) harmonize_parties(long, harmonization, green_class)

# ---- Pass 1: read votes and aggregate observed levels ----------------------
votes_by_year <- list()
pc4_observed  <- list()
gem_raw       <- list()   # pre-harmonization gemeente long (for imputation join)
coverage_by_year <- c()

failed_years <- character()

for (year in years) {
  message("\n=== Tweede Kamer ", year, " (reading) ===")
  # A year whose bundle cannot be fetched is skipped rather than aborting the
  # whole run; the years actually used are reported at the end.
  paths <- tryCatch(download_kiesraad_tk(year, raw_dir = raw_dir),
                    error = function(e) {
                      message("  !! TK", year, " unavailable: ", conditionMessage(e))
                      NULL
                    })
  if (is.null(paths) || is.na(paths$stembureau_csv)) {
    if (!is.null(paths)) message("  !! TK", year, ": bundle has no per-polling-station CSV.")
    failed_years <- c(failed_years, year)
    next
  }
  votes <- read_stembureau_votes(paths$stembureau_csv)

  votes_by_year[[year]] <- votes
  pc4_observed[[year]]  <- aggregate_to_pc4(votes, year)
  # Gemeente level: prefer the complete per-municipality CSV where the bundle
  # ships one (2012/2017/2021); the 2017 stembureau file covers only part of the
  # municipalities, so aggregating stations would understate it. Fall back to the
  # station aggregate when there is no per-municipality CSV (2023).
  gem_raw[[year]] <- if (!is.na(paths$gemeente_csv)) {
    aggregate_to_gemeente(read_gemeente_votes(paths$gemeente_csv), year)
  } else {
    aggregate_to_gemeente_from_stations(votes, year)
  }
  coverage_by_year[year] <- postcode_coverage(votes)
}

years <- setdiff(years, failed_years)
if (!length(years)) stop("No election year could be read; nothing to do.")
if (length(failed_years)) {
  warning("Skipped election year(s) ", paste(failed_years, collapse = ", "),
          ": source bundle unavailable. The panel below does NOT include them.",
          call. = FALSE, immediate. = TRUE)
}

# Raw party names the harmonization table does not know keep their own name and
# are therefore *not* flagged green -- a silent measurement error if a new
# election brings a new spelling of a green list. Report them with their weight.
report_unmatched_parties <- function(votes_by_year, harmonization) {
  rows <- lapply(names(votes_by_year), function(y) {
    v <- votes_by_year[[y]]
    tot <- sum(v$AantalStemmen, na.rm = TRUE)
    d <- stats::aggregate(list(votes = v$AantalStemmen),
                          by = list(party = v$PartijNaam), FUN = sum, na.rm = TRUE)
    d <- d[!d$party %in% harmonization$source_party, , drop = FALSE]
    if (!nrow(d)) return(NULL)
    data.frame(year = y, party = d$party, national_share = d$votes / tot,
               stringsAsFactors = FALSE)
  })
  out <- dplyr::bind_rows(rows)
  if (nrow(out)) {
    out <- out[order(-out$national_share), ]
    message("\n!! ", nrow(out), " raw party name(s) are missing from ",
            PARTY_HARMONIZATION_CSV, ". They keep their raw name and are NOT ",
            "flagged green -- add any green list among them:")
    print(utils::head(transform(out, national_share = round(100 * out$national_share, 3)), 20),
          row.names = FALSE)
    utils::write.csv(out, file.path(processed_dir, "unmatched_parties.csv"),
                     row.names = FALSE)
  }
  invisible(out)
}
report_unmatched_parties(votes_by_year, harmonization)

# PC4 -> municipality crosswalk pooled over all years, for the imputation.
crosswalk <- build_pc4_gemeente_crosswalk(votes_by_year)
message(sprintf("\nPC4 -> gemeente crosswalk: %s PC4s pooled over %s years.",
                format(nrow(crosswalk), big.mark = ","), length(years)))

# ---- Pass 2: impute PC4s, harmonize, write both levels ---------------------
levels_data <- list(pc4 = list(), gemeente = list())
summary_rows <- list()

for (year in years) {
  # PC4: observed rows + municipality-imputed rows (flagged `imputed`).
  pc4_full <- if (IMPUTE_PC4) {
    add_pc4_imputation(pc4_observed[[year]], gem_raw[[year]], crosswalk, year)
  } else {
    dplyr::mutate(pc4_observed[[year]], imputed = FALSE)
  }
  pc4_long <- harmonize(pc4_full)
  gem_long <- dplyr::mutate(harmonize(gem_raw[[year]]), imputed = FALSE)

  n_obs <- sum(!pc4_long$imputed)
  n_imp <- sum(pc4_long$imputed)
  message(sprintf("Tweede Kamer %s: coverage %.1f%% | PC4 %s obs + %s imputed rows across %s PC4s | gemeente %s areas",
                  year, 100 * coverage_by_year[year],
                  format(n_obs, big.mark = ","), format(n_imp, big.mark = ","),
                  format(dplyr::n_distinct(pc4_long$area_code), big.mark = ","),
                  format(dplyr::n_distinct(gem_long$area_code), big.mark = ",")))

  for (lv in c("pc4", "gemeente")) {
    d <- if (lv == "pc4") pc4_long else gem_long
    write_output(d, file.path(processed_dir, sprintf("tk%s_%s_long.parquet", year, lv)))
    levels_data[[lv]][[year]] <- d
  }

  summary_rows[[year]] <- data.frame(
    year = year, postcode_coverage = round(coverage_by_year[year], 4),
    pc4_areas_observed = dplyr::n_distinct(pc4_observed[[year]]$area_code),
    pc4_areas_total = dplyr::n_distinct(pc4_long$area_code),
    pc4_areas_imputed = dplyr::n_distinct(pc4_long$area_code[pc4_long$imputed]),
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

# ---- Headline product: estimated green vote share per PC4 x year -----------
#
# The all-party tables above fill an unobserved PC4 with its municipality's
# shares. For the green measure we do better: an empirical-Bayes model that adds
# each PC4's own persistent deviation from its municipality (estimated from the
# years it *is* observed) and shrinks thin observed cells towards it. See
# R/estimate.R for the model and scripts/validate_estimator.R for the
# cross-validated gain over the municipal fill.

message("\n=== Green vote share per PC4 (empirical-Bayes estimates) ===")

weights <- build_pc4_gemeente_weights(votes_by_year)
message(sprintf("PC4 -> gemeente weights: %s PC4s, %s PC4-municipality links.",
                format(dplyr::n_distinct(weights$area_code), big.mark = ","),
                format(nrow(weights), big.mark = ",")))
write_output(weights, file.path(processed_dir, "pc4_gemeente_weights.parquet"))

pc4_observed_long <- dplyr::bind_rows(lapply(levels_data$pc4, function(d) {
  dplyr::filter(d, !.data$imputed)
}))
gem_long_all <- dplyr::bind_rows(levels_data$gemeente)

groups <- green_party_groups(green_class)
green_est <- estimate_group_panel(pc4_observed_long, gem_long_all, weights, groups)

write_output(green_est$wide,
             file.path(processed_dir, "green_share_pc4_elections.parquet"))
message(sprintf("Wrote green_share_pc4_elections.parquet (%s rows, %s PC4s x %s elections)",
                format(nrow(green_est$wide), big.mark = ","),
                format(dplyr::n_distinct(green_est$wide$pc4), big.mark = ","),
                dplyr::n_distinct(green_est$wide$year)))

green_panel <- build_green_panel(green_est$wide, weights, end_year = PANEL_END_YEAR)
write_output(green_panel, file.path(processed_dir, "green_share_pc4_panel.parquet"))
message(sprintf("Wrote green_share_pc4_panel.parquet (%s rows, %s PC4s x %d calendar years %d-%d)",
                format(nrow(green_panel), big.mark = ","),
                format(dplyr::n_distinct(green_panel$pc4), big.mark = ","),
                dplyr::n_distinct(green_panel$year),
                min(green_panel$year), max(green_panel$year)))

green_by_year <- green_panel %>%
  dplyr::filter(.data$is_election_year) %>%
  dplyr::group_by(.data$year) %>%
  dplyr::summarise(
    pc4 = dplyr::n(),
    observed = mean(.data$observed),
    green_share_mean = mean(.data$green_share),
    green_share_p10 = stats::quantile(.data$green_share, 0.1),
    green_share_p90 = stats::quantile(.data$green_share, 0.9),
    .groups = "drop"
  )
message("")
print(as.data.frame(green_by_year), row.names = FALSE, digits = 3)

# ---- Summary ---------------------------------------------------------------
summary_df <- dplyr::bind_rows(summary_rows)
readr::write_csv(summary_df, file.path(processed_dir, "summary.csv"))
message("")
print(summary_df, row.names = FALSE)
message("\nDone.")
