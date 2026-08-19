# harmonize.R
#
# Harmonize raw Kiesraad party names into consistent party identities across
# election years, and flag green / environmental parties. Both mappings are
# data, kept as editable reference tables under reference/:
#
#   reference/party_harmonization.csv  source_party -> party, party_label
#   reference/green_classification.csv list of green/environmental parties
#
# See reference/README.md for the rationale behind each mapping.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

# Default locations, relative to the project root.
PARTY_HARMONIZATION_CSV <- file.path("reference", "party_harmonization.csv")
GREEN_CLASSIFICATION_CSV <- file.path("reference", "green_classification.csv")

#' Load the party-name harmonization table.
load_party_harmonization <- function(path = PARTY_HARMONIZATION_CSV) {
  readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()))
}

#' Load the green / environmental party classification table.
#'
#' A flat list of the harmonized parties treated as green/environmental. This is
#' a deliberately rough binary proxy: a party is either on the list (green) or
#' not. Edit reference/green_classification.csv to change it.
load_green_classification <- function(path = GREEN_CLASSIFICATION_CSV) {
  readr::read_csv(path, col_types = readr::cols(
    party = readr::col_character(), party_label = readr::col_character(),
    note = readr::col_character()
  ))
}

#' Add harmonized party identity and green flags to a long votes table.
#'
#' Joins the harmonization table on the raw `party` column and the green
#' classification on the harmonized party. Raw names not present in the
#' harmonization table keep their own name as the harmonized identity (and warn).
#'
#' @param long A long tibble with a raw `party` column (e.g. the aggregated
#'   PC4/gemeente output).
#' @return `long` with added columns: `party_short` (regular party abbreviation,
#'   e.g. `PvdA`, `GL`, `VVD`, stable across years), `party_label` (readable
#'   name), and `green` (logical — TRUE for the parties in the green table).
harmonize_parties <- function(long,
                              harmonization = load_party_harmonization(),
                              green = load_green_classification()) {
  unmatched <- setdiff(unique(long$party), harmonization$source_party)
  if (length(unmatched)) {
    warning("harmonize_parties(): ", length(unmatched),
            " raw party name(s) not in the harmonization table; keeping their ",
            "own name (", paste(utils::head(unmatched, 3), collapse = ", "),
            if (length(unmatched) > 3) ", ..." else "", ").", call. = FALSE)
  }

  hmap <- harmonization %>% select("source_party", "party_short" = "party", "party_label")

  long %>%
    left_join(hmap, by = c("party" = "source_party")) %>%
    mutate(
      party_short = dplyr::coalesce(.data$party_short, .data$party),
      party_label = dplyr::coalesce(.data$party_label, .data$party),
      green       = .data$party_short %in% green$party
    )
}
