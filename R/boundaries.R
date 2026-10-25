# boundaries.R
#
# Re-express municipality (gemeente) results on one fixed set of boundaries, so
# the same area can be followed across elections despite municipal
# reorganisations (herindelingen). Each election's gemeente table uses the
# municipalities that existed on that election day; this maps them onto the
# municipalities of 29 October 2025 (the TK2025 election, which are also the
# 2026 municipalities, as CBS reports no mergers for 2026).
#
# Both mappings are data, built from CBS StatLine 70739ned by
# scripts/build_gemeente_crosswalk.R and kept under reference/:
#
#   reference/gemeente_crosswalk.csv  from_code -> to_code (2025) + weight
#   reference/gemeente_periods.csv    each code's validity period
#
# Merged municipalities are summed into their 2025 successor. A municipality
# split over several successors (e.g. Haaren in 2021) is allocated by the share
# of its inhabitants each received, assuming its party shares were uniform
# across the parts, so allocated vote counts can be fractional.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

# Default locations, relative to the project root.
GEMEENTE_CROSSWALK_CSV <- file.path("reference", "gemeente_crosswalk.csv")
GEMEENTE_PERIODS_CSV   <- file.path("reference", "gemeente_periods.csv")

# Level label of the fixed-boundary tables.
GEMEENTE_TARGET_LEVEL <- "gemeente2025"

#' Load the municipality crosswalk (from_code -> 2025 to_code, weight).
load_gemeente_crosswalk <- function(path = GEMEENTE_CROSSWALK_CSV) {
  readr::read_csv(path, col_types = readr::cols(
    from_code = readr::col_character(), from_name = readr::col_character(),
    to_code = readr::col_character(), to_name = readr::col_character(),
    weight = readr::col_double()
  ))
}

#' Load the municipality validity periods (end_date NA = still exists).
load_gemeente_periods <- function(path = GEMEENTE_PERIODS_CSV) {
  readr::read_csv(path, col_types = readr::cols(
    code = readr::col_character(), cbs_code = readr::col_character(),
    name = readr::col_character(),
    begin_date = readr::col_date(), end_date = readr::col_date()
  ))
}

#' Codes of the municipalities that existed on `date`.
gemeente_codes_on <- function(periods, date) {
  date <- as.Date(date)
  alive <- (is.na(periods$begin_date) | periods$begin_date <= date) &
           (is.na(periods$end_date) | periods$end_date > date)
  periods$code[alive]
}

#' Map one election's gemeente table onto the 2025 municipal boundaries.
#'
#' Votes of every source municipality are summed into (or, for a split,
#' allocated by population weight across) its 2025 successor(s), and shares are
#' recomputed. Codes not in the crosswalk -- the Caribbean public bodies
#' (9001-9003) and the postal votes from abroad (9010) -- pass through as-is.
#'
#' A 2025 municipality is `complete` when every municipality that made it up on
#' election day is present in the source table. It is FALSE where the source
#' lacks some of them (above all in 2017, whose machine-readable data covers
#' only 279 of 388 municipalities); its shares then reflect only the observed
#' parts. 2025 municipalities with no observed part at all have no rows.
#'
#' @param gem_long      Harmonized gemeente long table for one election year
#'   (vintage codes in `area_code`).
#' @param crosswalk     [load_gemeente_crosswalk()].
#' @param periods       [load_gemeente_periods()].
#' @param election_date Election day (Date or "YYYY-MM-DD").
#' @return Long tibble with the gemeente schema at `level = "gemeente2025"`,
#'   plus a logical `complete` column.
to_gemeente2025 <- function(gem_long, crosswalk, periods, election_date) {
  cw <- select(crosswalk, "from_code", "to_code", "to_name", "weight")

  mapped <- gem_long %>%
    left_join(cw, by = c("area_code" = "from_code"), relationship = "many-to-many") %>%
    mutate(
      to_code = dplyr::coalesce(.data$to_code, .data$area_code),
      to_name = dplyr::coalesce(.data$to_name, .data$area_name),
      weight  = dplyr::coalesce(.data$weight, 1)
    )

  # Municipalities that existed on election day, by their 2025 successor; a
  # successor is complete when all of its election-day parts were observed.
  expected <- cw %>%
    filter(.data$from_code %in% gemeente_codes_on(periods, election_date))
  missing_parts <- expected %>%
    filter(!(.data$from_code %in% unique(gem_long$area_code))) %>%
    distinct(.data$to_code)

  mapped %>%
    group_by(.data$year, area_code = .data$to_code, area_name = .data$to_name,
             .data$party, .data$party_short, .data$party_label, .data$green) %>%
    summarise(votes = sum(.data$votes * .data$weight), .groups = "drop") %>%
    add_shares() %>%
    mutate(level = GEMEENTE_TARGET_LEVEL, imputed = FALSE,
           complete = !(.data$area_code %in% missing_parts$to_code)) %>%
    select("year", "level", "area_code", "area_name", "party",
           "votes", "valid_votes_area", "vote_share",
           "party_short", "party_label", "green", "imputed", "complete") %>%
    arrange(.data$area_code, dplyr::desc(.data$votes))
}
