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
#' Dutch PC4 codes run 1000-9999, so the leading digit must be 1-9; anything
#' else (blanks, "0000" placeholders on mobile / postal-vote stations) -> NA.
derive_pc4 <- function(postcode) {
  str_extract(str_replace_all(postcode, "\\s", ""), "^[1-9][0-9]{3}")
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

#' Build a PC4 -> municipality crosswalk from observed polling-station data.
#'
#' Each polling station with a postcode ties a PC4 to a municipality. Pooling
#' these observations across all available years gives a fairly complete PC4 ->
#' gemeente map (a PC4 seen in any election is placed), needed to impute PC4s
#' that a given year did not observe. Where a PC4's municipality differs between
#' years (municipal reorganizations), the most recent observation wins.
#'
#' @param votes_by_year Named list of per-polling-station tibbles (names = years).
#' @return A tibble: `area_code` (PC4), `gem_code`, `gem_name`.
build_pc4_gemeente_crosswalk <- function(votes_by_year) {
  pairs <- dplyr::bind_rows(lapply(names(votes_by_year), function(y) {
    v <- votes_by_year[[y]]
    tibble::tibble(
      year = as.integer(y),
      area_code = derive_pc4(v$Postcode),
      gem_code = v$GemeenteCode,
      gem_name = v$GemeenteNaam
    )
  }))
  pairs %>%
    filter(!is.na(.data$area_code)) %>%
    distinct(.data$year, .data$area_code, .data$gem_code, .data$gem_name) %>%
    arrange(dplyr::desc(.data$year)) %>%
    group_by(.data$area_code) %>%
    summarise(gem_code = dplyr::first(.data$gem_code),
              gem_name = dplyr::first(.data$gem_name), .groups = "drop")
}

#' Impute PC4 party shares from the municipality level, for unobserved PC4s.
#'
#' For every PC4 in the crosswalk that a year's polling stations did *not*
#' record (its municipality reported no postcodes there), assign that PC4 the
#' vote *shares* of its municipality, uniformly (each party's PC4 share = its
#' municipal share). Vote counts are left `NA` — only shares are inferred — and
#' the rows are flagged `imputed = TRUE`. PC4s whose municipality is absent from
#' the year (e.g. abolished by reorganization) cannot be imputed and are skipped.
#'
#' @param observed_pc4 Observed PC4 long table for the year (`aggregate_to_pc4`).
#' @param gem_long     Gemeente long table for the year
#'   (`aggregate_to_gemeente_from_stations`), keyed by CBS code in `area_code`.
#' @param crosswalk    PC4 -> gemeente crosswalk (`build_pc4_gemeente_crosswalk`).
#' @param year         Election year.
#' @return Long tibble of imputed PC4 rows (shared schema + `imputed = TRUE`).
impute_pc4_from_gemeente <- function(observed_pc4, gem_long, crosswalk, year) {
  targets <- filter(crosswalk, !(.data$area_code %in% unique(observed_pc4$area_code)))
  targets %>%
    inner_join(gem_long, by = c("gem_code" = "area_code"),
               relationship = "many-to-many") %>%   # many PC4s x many parties
    transmute(
      year = as.character(year), level = "pc4",
      area_code = .data$area_code, area_name = NA_character_,
      party = .data$party, votes = NA_integer_, valid_votes_area = NA_integer_,
      vote_share = .data$vote_share, imputed = TRUE
    ) %>%
    arrange(.data$area_code, dplyr::desc(.data$vote_share))
}

#' Combine observed and municipality-imputed PC4 rows into one long table.
#'
#' Observed rows are flagged `imputed = FALSE`; imputed rows (from
#' [impute_pc4_from_gemeente()]) `imputed = TRUE`. The result is a fuller PC4
#' table where every crosswalk PC4 has a value each year, observed where the
#' postcode was recorded and inferred from the municipality otherwise.
add_pc4_imputation <- function(observed_pc4, gem_long, crosswalk, year) {
  observed <- mutate(observed_pc4, imputed = FALSE)
  imputed  <- impute_pc4_from_gemeente(observed_pc4, gem_long, crosswalk, year)
  dplyr::bind_rows(observed, imputed)
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
