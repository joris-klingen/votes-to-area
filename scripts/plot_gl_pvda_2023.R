#!/usr/bin/env Rscript
# plot_gl_pvda_2023.R
#
# Map the share of votes for the combined GROENLINKS / PvdA list in the 2023
# Tweede Kamer election, at two area levels, using the CPB house style from the
# `ggcpb` package:
#
#   * per municipality (gemeente) -> ggcpb::cpb_map(level = "gemeente")
#   * per 4-digit postcode (PC4)  -> a cpb_map-style choropleth on the cartomap
#     PC4 boundaries, drawn with ggcpb's own scales/theme/tokens (ggcpb bundles
#     gemeente/COROP/province boundaries only, not PC4)
#
# In 2023 GroenLinks and the PvdA stood as a single combined list, so their
# joint share is simply that list's vote share.
#
# Usage:
#   Rscript scripts/plot_gl_pvda_2023.R
#
# Outputs (PNG, CPB half-page width) under figures/:
#   gl_pvda_2023_gemeente.png
#   gl_pvda_2023_pc4.png
#
# Requires: ggcpb (https://github.com/joris-klingen/ggcpb) and its dependencies,
# plus dplyr, ggplot2, jsonlite, and the project's own readr/nanoparquet stack.

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(ggcpb)
})

# ---- Locate project root (works under `Rscript` and `source()`) ------------
this_file <- tryCatch(normalizePath(sys.frame(1)$ofile), error = function(e) NULL)
if (is.null(this_file)) {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  this_file <- if (length(file_arg)) normalizePath(file_arg) else "scripts/plot_gl_pvda_2023.R"
}
project_root <- dirname(dirname(this_file))

source(file.path(project_root, "R", "download_data.R"))  # download_kiesraad_tk, robust_download
source(file.path(project_root, "R", "aggregate.R"))       # read_stembureau_votes, aggregate_to_pc4

# ---- Configuration ---------------------------------------------------------
YEAR        <- "2023"
GL_PVDA     <- "GROENLINKS / Partij van de Arbeid (PvdA)"  # combined list name in 2023
PC4_GEO_URL <- "https://cartomap.github.io/nl/rd/postcode4_2023.geojson"
# Class breaks for the share (%), house-style light-to-dark blue ramp.
BREAKS      <- c(0, 10, 20, 30, 40, 50, Inf)

raw_dir     <- file.path(project_root, "data", "raw")
figures_dir <- file.path(project_root, "figures")
dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

# ---- Read the 2023 per-polling-station votes -------------------------------
paths <- download_kiesraad_tk(YEAR, raw_dir = raw_dir)
votes <- read_stembureau_votes(paths$stembureau_csv)

#' Share (%) of a party within each area, as an ordered CPB class factor.
share_class <- function(long, area_code, party_name) {
  long %>%
    group_by({{ area_code }}) %>%
    summarise(share = 100 * sum(votes[party == party_name]) / sum(votes),
              .groups = "drop") %>%
    mutate(klasse = cpb_cut(.data$share, breaks = BREAKS, labeller = label_pct_nl()))
}

# ---- Municipality level ----------------------------------------------------
# Aggregate polling stations to gemeente (complete: no postcode needed), then
# the GL/PvdA share per municipality. cpb_map joins on the CBS statcode "GMxxxx".
gem_long <- votes %>%
  group_by(area_code = .data$GemeenteCode, party = .data$PartijNaam) %>%
  summarise(votes = sum(.data$AantalStemmen, na.rm = TRUE), .groups = "drop")

gem <- share_class(gem_long, area_code, GL_PVDA) %>%
  mutate(statcode = sprintf("GM%04d", as.integer(.data$area_code)))

p_gem <- cpb_map(
  gem, region = statcode, value = klasse, level = "gemeente",
  palette = "blues", border_colour = "white",
  title   = "GroenLinks-PvdA in 2023\nper gemeente",
  filllab = "stemaandeel"
)
save_cpb(file.path(figures_dir, "gl_pvda_2023_gemeente.png"),
         plot = p_gem, page = "half", height = 3.9)

# ---- PC4 (postcode) level --------------------------------------------------
pc4_long <- aggregate_to_pc4(votes, YEAR)           # long PC4 x party (project fn)
pc4 <- share_class(pc4_long, area_code, GL_PVDA) %>%
  rename(pc4 = area_code)

# ggcpb has no PC4 boundaries, so fetch the cartomap PC4 GeoJSON (same source and
# RD/EPSG:28992 projection as ggcpb's own boundaries) and flatten it to the
# vertex table cpb_map/cpb_nl_geo use: code, part (group), ring (subgroup), x, y.
geo_path <- file.path(raw_dir, "postcode4_2023.geojson")
if (!file.exists(geo_path)) robust_download(PC4_GEO_URL, geo_path)

flatten_pc4 <- function(path) {
  g <- jsonlite::read_json(path)
  rows <- lapply(g$features, function(f) {
    code  <- sprintf("%04d", as.integer(f$properties$postcode))
    polys <- if (f$geometry$type == "Polygon") list(f$geometry$coordinates)
             else f$geometry$coordinates  # MultiPolygon
    do.call(rbind, lapply(seq_along(polys), function(pi) {
      do.call(rbind, lapply(seq_along(polys[[pi]]), function(ri) {
        m <- do.call(rbind, lapply(polys[[pi]][[ri]],
                                   function(xy) c(as.numeric(xy[[1]]), as.numeric(xy[[2]]))))
        data.frame(code = code,
                   part = sprintf("%s.%d", code, pi),
                   ring = sprintf("%s.%d.%d", code, pi, ri),
                   x = m[, 1], y = m[, 2])
      }))
    }))
  })
  out <- do.call(rbind, rows); rownames(out) <- NULL; out
}

geo <- flatten_pc4(geo_path)
geo$klasse <- pc4$klasse[match(geo$code, pc4$pc4)]

# Build the choropleth the way cpb_map does, reusing ggcpb's scale, theme and
# background token so the PC4 map matches the house style exactly.
tokens <- cpb_tokens()
p_pc4 <- ggplot(geo, aes(x = .data$x, y = .data$y,
                         group = .data$part, subgroup = .data$ring, fill = .data$klasse)) +
  geom_polygon(colour = tokens$bg, linewidth = 0.05) +   # thin seams, PC4s are small
  coord_fixed(1) +
  scale_fill_cpb_d(palette = "blues", na.value = tokens$na) +
  labs(title = "GroenLinks-PvdA in 2023\nper postcodegebied (PC4)", fill = "stemaandeel") +
  theme_cpb(grid = "none", ticks = FALSE, legend = "bottom", flush_legend = FALSE) +
  theme(axis.text = element_blank(), axis.title = element_blank(),
        axis.line = element_blank(), axis.ticks = element_blank(),
        legend.position = "inside", legend.position.inside = c(0, 0.98),
        legend.justification = c(0, 1), legend.direction = "vertical")

save_cpb(file.path(figures_dir, "gl_pvda_2023_pc4.png"),
         plot = p_pc4, page = "half", height = 3.9)

message("Wrote figures to ", figures_dir)
