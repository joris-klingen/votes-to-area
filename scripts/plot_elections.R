#!/usr/bin/env Rscript
# plot_elections.R
#
# Figures for the 2012-2023 Tweede Kamer elections in the CPB house style
# (`ggcpb`), for research on the political demand side of green technologies:
#
#   1. Per-municipality choropleths of the combined GroenLinks-PvdA vote share,
#      one map per election (2012, 2017, 2021, 2023).
#   2. Time series of the national vote share of green / environmental parties.
#
# This script ASSUMES the data is already downloaded and processed: it reads the
# Parquet panel/combined tables written by `run.R` and does no downloading. Run
# `Rscript run.R` first if data/processed/ is empty.
#
# Note: `ggcpb` currently ships only municipality/COROP/province boundaries, so
# these maps are at the gemeente level. PC4 maps will follow once ggcpb can plot
# postcode areas. The bundled boundaries are a single (recent) vintage, so
# municipalities that were merged away before then show as grey (NA) on the
# earlier-year maps.
#
# Usage:
#   Rscript scripts/plot_elections.R
#
# Outputs (PNG, CPB half-page width) under figures/.

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(ggcpb)
  library(nanoparquet)
})

# ---- Locate project root ---------------------------------------------------
this_file <- tryCatch(normalizePath(sys.frame(1)$ofile), error = function(e) NULL)
if (is.null(this_file)) {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  this_file <- if (length(file_arg)) normalizePath(file_arg) else "scripts/plot_elections.R"
}
project_root  <- dirname(dirname(this_file))
processed_dir <- file.path(project_root, "data", "processed")
figures_dir   <- file.path(project_root, "figures")
dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

# ---- Configuration ---------------------------------------------------------
# Harmonized keys that make up the "GroenLinks-PvdA bloc": the two separate
# parties before 2023 and the combined list in 2023.
GL_PVDA_BLOC <- c("GL", "PvdA", "GL-PvdA")
BREAKS       <- c(0, 10, 20, 30, 40, 50, Inf)   # share (%) classes

read_processed <- function(name) {
  path <- file.path(processed_dir, name)
  if (!file.exists(path)) {
    stop("Missing ", path, "\nRun `Rscript run.R` first to build the ",
         "processed Parquet tables.", call. = FALSE)
  }
  nanoparquet::read_parquet(path)
}

gem <- read_processed("tk_gemeente_all_years_long.parquet")
years <- sort(unique(gem$year))

# ---- 1. GroenLinks-PvdA bloc, per municipality, per election ---------------
for (yr in years) {
  bloc <- gem %>%
    filter(.data$year == yr) %>%
    group_by(area_code = .data$area_code) %>%
    summarise(share = 100 * sum(.data$votes[.data$party_harmonized %in% GL_PVDA_BLOC]) /
                        sum(.data$votes), .groups = "drop") %>%
    mutate(klasse   = cpb_cut(.data$share, breaks = BREAKS, labeller = label_pct_nl()),
           statcode = sprintf("GM%04d", as.integer(.data$area_code)))

  p <- cpb_map(
    bloc, region = statcode, value = klasse, level = "gemeente",
    palette = "blues", border_colour = "white",
    title   = sprintf("GroenLinks-PvdA in %s\nper gemeente", yr),
    filllab = "stemaandeel"
  )
  save_cpb(file.path(figures_dir, sprintf("gl_pvda_%s_gemeente.png", yr)),
           plot = p, page = "half", height = 3.9)
}

# ---- 2. National vote share of green / environmental parties ---------------
# National share per election year, from the complete municipal tally.
green_year <- gem %>%
  group_by(year_int = as.integer(.data$year)) %>%
  summarise(
    `groen (kern)`        = 100 * sum(.data$votes[.data$green_core]) / sum(.data$votes),
    `groen (incl. deels)` = 100 * sum(.data$votes[.data$is_green])   / sum(.data$votes),
    .groups = "drop"
  )

green_long <- dplyr::bind_rows(
  data.frame(year_int = green_year$year_int, reeks = "groen (incl. deels)",
             aandeel = green_year$`groen (incl. deels)`),
  data.frame(year_int = green_year$year_int, reeks = "groen (kern)",
             aandeel = green_year$`groen (kern)`)
) %>%
  mutate(reeks = factor(.data$reeks, levels = c("groen (incl. deels)", "groen (kern)")))

election_years <- sort(unique(as.integer(gem$year)))

p_green <- cpb_line(
  green_long, x = year_int, y = aandeel, colour = reeks,
  points = TRUE, pct_axis = TRUE, index = c(3, 1),
  value_limits = c(0, 22),
  title    = "Stemaandeel groene partijen",
  subtitle = "aandeel van de geldige stemmen, Tweede Kamer",
  colourlab = NULL
) + ggplot2::scale_x_continuous(breaks = election_years)
save_cpb(file.path(figures_dir, "green_share_timeseries.png"),
         plot = p_green, page = "half")

# Per-party lines: each green / partly-green party's national share over time.
green_party <- gem %>%
  group_by(year_int = as.integer(.data$year)) %>%
  mutate(total = sum(.data$votes)) %>%
  filter(.data$is_green) %>%
  group_by(year_int, party = .data$party_label) %>%
  summarise(aandeel = 100 * sum(.data$votes) / dplyr::first(.data$total), .groups = "drop")

p_green_party <- cpb_line(
  green_party, x = year_int, y = aandeel, colour = party,
  points = TRUE, pct_axis = TRUE, value_limits = c(0, 22),
  title    = "Stemaandeel per groene partij",
  subtitle = "aandeel van de geldige stemmen, Tweede Kamer"
) + ggplot2::scale_x_continuous(breaks = election_years)
save_cpb(file.path(figures_dir, "green_parties_share_timeseries.png"),
         plot = p_green_party, page = "half")

message("Wrote figures to ", figures_dir)
