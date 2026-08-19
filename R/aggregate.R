# aggregate.R
#
# Read the Kiesraad election results and aggregate votes to an area level, long
# (tidy) in the party dimension with each party's vote share within the area.
#
# The preferred area level is the 4-digit postal code (PC4), obtained from the
# polling-station postcode. Older elections did not record station postcodes
# (or only partially), so the pipeline falls back to the municipality
# (gemeente) level for those years. Both levels share one output schema:
#
#   year, level, area_code, area_name, party, votes, valid_votes_area, vote_share
#
#   level             "pc4" or "gemeente"
#   area_code         PC4 code (e.g. "1011") or CBS municipality code
#   area_name         municipality name at gemeente level; NA at PC4 level
#                     (a PC4 can span multiple municipalities)
#   valid_votes_area  total valid list votes in the area (sum over parties)
#   vote_share        votes / valid_votes_area (shares sum to 1 within an area)

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
})

# ---- Readers ---------------------------------------------------------------

#' Read a per-polling-station CSV (all TK years share this schema).
#'
#' Semicolon-separated, UTF-8, CRLF line endings, with some fields quoted. All
#' columns are read as text (preserving leading zeros in codes/postcodes) except
#' the vote count, which is read as integer.
read_stembureau_votes <- function(csv_path) {
  readr::read_delim(
    csv_path, delim = ";", quote = "\"",
    col_types = readr::cols(
      GemeenteCode   = readr::col_character(),
      GemeenteNaam   = readr::col_character(),
      Postcode       = readr::col_character(),
      StembureauNaam = readr::col_character(),
      StembureauCode = readr::col_character(),
      PartijNaam     = readr::col_character(),
      AantalStemmen  = readr::col_integer()
    ),
    locale = readr::locale(encoding = "UTF-8"),
    show_col_types = FALSE
  )
}

#' Read a per-municipality CSV (all TK years share this schema).
read_gemeente_votes <- function(csv_path) {
  readr::read_delim(
    csv_path, delim = ";", quote = "\"",
    col_types = readr::cols(
      GemeenteCode  = readr::col_character(),
      GemeenteNaam  = readr::col_character(),
      PartijNaam    = readr::col_character(),
      AantalStemmen = readr::col_integer()
    ),
    locale = readr::locale(encoding = "UTF-8"),
    show_col_types = FALSE
  )
}

# ---- Helpers ---------------------------------------------------------------

#' Derive the 4-digit postal code (PC4) from a full Dutch postcode ("1234AB").
#' Returns NA where no postcode is recorded (e.g. mobile / postal-vote stations).
derive_pc4 <- function(postcode) {
  str_extract(str_replace_all(postcode, "\\s", ""), "^[0-9]{4}")
}

#' Fraction of polling-station rows that carry a usable PC4 postcode.
postcode_coverage <- function(votes) {
  if (nrow(votes) == 0) return(0)
  mean(!is.na(derive_pc4(votes$Postcode)))
}

#' Add the shared long-format share columns to an aggregated `area_code x party`
#' table (grouping denominator is the total votes within each area).
add_shares <- function(df) {
  df %>%
    group_by(.data$area_code) %>%
    mutate(
      valid_votes_area = sum(.data$votes),
      vote_share = dplyr::if_else(.data$valid_votes_area > 0,
                                  .data$votes / .data$valid_votes_area,
                                  NA_real_)
    ) %>%
    ungroup()
}

# ---- Aggregators -----------------------------------------------------------

#' Aggregate polling-station votes to PC4 x party (long format).
#'
#' Sums the votes of all polling stations within each PC4 area. Rows without a
#' usable postcode are dropped by default (set `drop_missing_pc4 = FALSE` to keep
#' them under `area_code = NA`).
#'
#' @return Long tibble with the shared output schema (`level = "pc4"`).
aggregate_to_pc4 <- function(votes, year, drop_missing_pc4 = TRUE) {
  out <- mutate(votes, area_code = derive_pc4(.data$Postcode))
  if (drop_missing_pc4) out <- filter(out, !is.na(.data$area_code))

  out %>%
    group_by(.data$area_code, party = .data$PartijNaam) %>%
    summarise(votes = sum(.data$AantalStemmen, na.rm = TRUE), .groups = "drop") %>%
    add_shares() %>%
    mutate(year = as.character(year), level = "pc4", area_name = NA_character_) %>%
    select("year", "level", "area_code", "area_name", "party",
           "votes", "valid_votes_area", "vote_share") %>%
    arrange(.data$area_code, dplyr::desc(.data$votes))
}

#' Aggregate polling-station votes to gemeente x party (long format).
#'
#' Groups the per-polling-station file by municipality. Unlike
#' [aggregate_to_gemeente()] this needs no separate per-municipality CSV and no
#' postcodes, so it gives a complete municipal tally for every year (including
#' 2023, whose bundle ships no per-municipality CSV).
#'
#' @return Long tibble with the shared output schema (`level = "gemeente"`).
aggregate_to_gemeente_from_stations <- function(votes, year) {
  votes %>%
    group_by(area_code = .data$GemeenteCode, area_name = .data$GemeenteNaam,
             party = .data$PartijNaam) %>%
    summarise(votes = sum(.data$AantalStemmen, na.rm = TRUE), .groups = "drop") %>%
    add_shares() %>%
    mutate(year = as.character(year), level = "gemeente") %>%
    select("year", "level", "area_code", "area_name", "party",
           "votes", "valid_votes_area", "vote_share") %>%
    arrange(.data$area_code, dplyr::desc(.data$votes))
}

#' Aggregate municipality votes to gemeente x party (long format).
#'
#' Uses the complete per-municipality file (the authoritative municipal tally),
#' so it does not depend on polling-station postcodes.
#'
#' @return Long tibble with the shared output schema (`level = "gemeente"`).
aggregate_to_gemeente <- function(gem_votes, year) {
  gem_votes %>%
    group_by(area_code = .data$GemeenteCode, area_name = .data$GemeenteNaam,
             party = .data$PartijNaam) %>%
    summarise(votes = sum(.data$AantalStemmen, na.rm = TRUE), .groups = "drop") %>%
    add_shares() %>%
    mutate(year = as.character(year), level = "gemeente") %>%
    select("year", "level", "area_code", "area_name", "party",
           "votes", "valid_votes_area", "vote_share") %>%
    arrange(.data$area_code, dplyr::desc(.data$votes))
}

#' Aggregate one election year to the best available area level.
#'
#' Chooses PC4 when the polling-station postcode coverage is at least
#' `pc4_min_coverage`; otherwise falls back to the municipality level. Downloads
#' and reads the source data as needed.
#'
#' @param paths            Result of `download_kiesraad_tk()` for the year.
#' @param pc4_min_coverage Minimum postcode coverage (0-1) to use PC4. Default 0.8.
#' @return A list with `data` (the long tibble) and `meta` (year, level chosen,
#'   coverage, counts) for reporting.
aggregate_year <- function(paths, pc4_min_coverage = 0.8) {
  year <- paths$year
  coverage <- NA_real_

  if (!is.na(paths$stembureau_csv)) {
    votes <- read_stembureau_votes(paths$stembureau_csv)
    coverage <- postcode_coverage(votes)
  }

  use_pc4 <- !is.na(coverage) && coverage >= pc4_min_coverage

  if (use_pc4) {
    data <- aggregate_to_pc4(votes, year)
    level <- "pc4"
  } else {
    if (is.na(paths$gemeente_csv)) {
      stop("Year ", year, ": postcode coverage too low (", round(coverage, 3),
           ") and no per-municipality CSV available to fall back to.")
    }
    data <- aggregate_to_gemeente(read_gemeente_votes(paths$gemeente_csv), year)
    level <- "gemeente"
  }

  meta <- list(
    year = year, level = level, coverage = coverage,
    n_areas = dplyr::n_distinct(data$area_code),
    n_parties = dplyr::n_distinct(data$party),
    n_rows = nrow(data),
    total_votes = sum(data$votes)
  )
  list(data = data, meta = meta)
}
