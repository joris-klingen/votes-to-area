# harmonize.R
#
# Harmonize raw Kiesraad party names into consistent party identities across
# election years, and flag green / environmental parties. Both mappings are
# data, kept as editable reference tables under reference/:
#
#   reference/party_harmonization.csv  source_party -> party, party_label
#   reference/green_classification.csv party -> green ("green"/"partly"), ...
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
load_green_classification <- function(path = GREEN_CLASSIFICATION_CSV) {
  readr::read_csv(path, col_types = readr::cols(
    party = readr::col_character(), party_label = readr::col_character(),
    green = readr::col_character(), environmental_core = readr::col_logical(),
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
#' @return `long` with added columns: `party_harmonized`, `party_label`,
#'   `green` ("green"/"partly"/NA), `is_green` (logical, green or partly),
#'   `green_core` (logical, green only).
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

  hmap <- harmonization %>% select("source_party", "party_harmonized" = "party", "party_label")
  gmap <- green %>% select("party_harmonized" = "party", "green", "environmental_core")

  long %>%
    left_join(hmap, by = c("party" = "source_party")) %>%
    mutate(
      party_harmonized = dplyr::coalesce(.data$party_harmonized, .data$party),
      party_label      = dplyr::coalesce(.data$party_label, .data$party)
    ) %>%
    left_join(gmap, by = "party_harmonized") %>%
    mutate(
      is_green   = !is.na(.data$green),
      green_core = identical_true(.data$green == "green")
    )
}

# vapply-free helper: TRUE where x is TRUE, FALSE where FALSE or NA.
identical_true <- function(x) !is.na(x) & x
