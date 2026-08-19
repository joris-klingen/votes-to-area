# aggregate_pc4.R
#
# Read the Kiesraad per-polling-station results and aggregate them to the
# 4-digit postal code (PC4) level, producing a long (tidy) table with one row
# per PC4 x political party, the summed number of votes, and each party's vote
# share within the PC4 area.

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
})

#' Read the raw per-polling-station CSV.
#'
#' The file is semicolon-separated, UTF-8 encoded with CRLF line endings, and
#' quotes some fields (postcode, party name, vote count) inconsistently. All
#' columns are read as text and only the vote count is coerced to integer, so
#' that leading zeros in codes/postcodes are preserved.
#'
#' @param csv_path Path to `TK2023_Stemmen_Per_Lijst_Per_Stembureau.csv`.
#' @return A tibble with the raw columns.
read_stembureau_votes <- function(csv_path) {
  readr::read_delim(
    csv_path,
    delim = ";",
    quote = "\"",
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

#' Derive the 4-digit postal code (PC4) from a full Dutch postcode.
#'
#' Dutch postcodes are formatted "1234AB". Some polling stations (e.g. mobile
#' or postal-vote stations) have no postcode recorded in the EML; those yield
#' NA and can be filtered out downstream.
#'
#' @param postcode Character vector of full postcodes (may contain blanks).
#' @return Character vector of 4-digit PC4 codes, or NA where unavailable.
derive_pc4 <- function(postcode) {
  cleaned <- str_replace_all(postcode, "\\s", "")
  pc4 <- str_extract(cleaned, "^[0-9]{4}")
  pc4
}

#' Aggregate polling-station votes to PC4 x party, in long format.
#'
#' Sums the votes of all polling stations that fall within each PC4 area and
#' computes each party's share of the valid votes in that area. The result is
#' long in the party dimension (one row per PC4 x party), so it can be easily
#' re-aggregated (e.g. to province, or grouped party families) or reshaped.
#'
#' Rows without a usable postcode are dropped from the PC4 output by default;
#' set `drop_missing_pc4 = FALSE` to keep them under `PC4 = NA`.
#'
#' Vote share is computed relative to the total valid list votes within the PC4
#' (the sum of all parties' votes there); blank and invalid votes are not part
#' of this per-list file and are therefore excluded from the denominator.
#'
#' @param votes A tibble as returned by `read_stembureau_votes()`.
#' @param drop_missing_pc4 Drop polling stations without a postcode (default TRUE).
#' @return A tibble with columns: pc4, party, votes, valid_votes_pc4, vote_share.
aggregate_votes_to_pc4 <- function(votes, drop_missing_pc4 = TRUE) {
  out <- votes %>%
    mutate(pc4 = derive_pc4(.data$Postcode))

  if (drop_missing_pc4) {
    out <- filter(out, !is.na(.data$pc4))
  }

  out %>%
    group_by(.data$pc4, party = .data$PartijNaam) %>%
    summarise(votes = sum(.data$AantalStemmen, na.rm = TRUE), .groups = "drop") %>%
    group_by(.data$pc4) %>%
    mutate(
      valid_votes_pc4 = sum(.data$votes),
      vote_share = dplyr::if_else(
        .data$valid_votes_pc4 > 0,
        .data$votes / .data$valid_votes_pc4,
        NA_real_
      )
    ) %>%
    ungroup() %>%
    arrange(.data$pc4, dplyr::desc(.data$votes))
}
