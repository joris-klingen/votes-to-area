# panel.R
#
# Build a balanced yearly panel from the (irregular) election cross-sections by
# rolling the most recent election forward into the non-election years in
# between (last-observation-carried-forward).
#
# Tweede Kamer elections are held irregularly (2012, 2017, 2021, 2023). For a
# panel with one row per calendar year, each non-election year inherits the
# result of the most recent election on or before it:
#
#   2012 2013 2014 2015 2016 | 2017 2018 2019 2020 | 2021 2022 | 2023
#   \_________ 2012 ________/  \______ 2017 ______/  \_ 2021 _/   2023
#
# The output keeps the same long schema plus:
#   year              the calendar (panel) year
#   source_year       the election the row's values were carried from
#   is_election_year  TRUE when an election was actually held that year

suppressPackageStartupMessages({
  library(dplyr)
})

#' Build a rolled-forward yearly panel from combined election data.
#'
#' @param combined   Long tibble across election years (as produced by the
#'   per-year aggregation and row-bound), with an integer-like `year` column.
#' @param start_year First calendar year of the panel. Default: earliest election.
#' @param end_year   Last calendar year of the panel. Default: latest election.
#'   Set higher (e.g. the current year) to carry the last election forward to
#'   the present.
#' @return Long tibble with one block of rows per calendar year in
#'   `start_year:end_year`, values carried forward from the latest election.
build_panel <- function(combined, start_year = NULL, end_year = NULL) {
  election_years <- sort(unique(as.integer(combined$year)))
  if (length(election_years) == 0) stop("No election years found in input.")

  if (is.null(start_year)) start_year <- min(election_years)
  if (is.null(end_year))   end_year   <- max(election_years)
  if (end_year < start_year) stop("end_year must be >= start_year")

  panel_years <- start_year:end_year
  # For each calendar year, the most recent election on or before it.
  source_year <- vapply(panel_years, function(y) {
    prior <- election_years[election_years <= y]
    if (length(prior) == 0) NA_integer_ else max(prior)
  }, integer(1))

  by_source <- split(combined, as.integer(combined$year))

  blocks <- Map(function(y, sy) {
    if (is.na(sy)) return(NULL)  # year precedes the first available election
    block <- by_source[[as.character(sy)]]
    block$year <- y
    block$source_year <- sy
    block$is_election_year <- y %in% election_years
    block
  }, panel_years, source_year)

  out <- dplyr::bind_rows(blocks)

  # Put the panel bookkeeping columns first, keep the rest of the schema.
  dplyr::select(out, "year", "source_year", "is_election_year",
                dplyr::everything()) %>%
    dplyr::arrange(.data$year, .data$area_code, dplyr::desc(.data$votes))
}
