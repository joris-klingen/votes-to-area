# green_panel.R
#
# The project's headline product: a balanced PC4 x calendar-year panel of the
# estimated green vote share, rolled forward from the elections into the
# non-election years.
#
# It applies the empirical-Bayes estimator in R/estimate.R to a handful of party
# groups (the broad green definition, its ecological core, and the components),
# joins them into one wide row per PC4 x election year, and then carries each
# election forward until the next one.
#
# The party groups (all defined on harmonized `party_short` keys):
#
#   green            the full green_classification.csv list -- the headline
#                    measure. Includes PvdA, because from 2023 GroenLinks and
#                    PvdA stand as one combined list that cannot be split.
#   green_core       the ecological core: PvdD, Volt, De Groenen, Piratenpartij-
#                    De Groenen. Well defined and comparable in *every* year,
#                    which the PvdA-inclusive measure only is by construction.
#   gl_pvda_family   GroenLinks + PvdA + the 2023 GroenLinks-PvdA list, pooled so
#                    the series is continuous across the 2023 merger.
#   pvdd, volt, groenen_family  the individual components.
#
# green = gl_pvda_family + green_core by construction of the groups; the three
# *estimates* are produced independently (each with its own shrinkage), so they
# only add up approximately -- use `green_share` for the headline number.

suppressPackageStartupMessages({
  library(dplyr)
})

# Dutch general elections and their polling days. Used to date the panel rows;
# note 2023 was held on 22 November, so calendar year 2023 reflects a result
# that only came in at the very end of the year (`election_date` is there so a
# user can shift the panel by a year if their design needs that).
TK_ELECTION_DATES <- c(
  "2010" = "2010-06-09", "2012" = "2012-09-12", "2017" = "2017-03-15",
  "2021" = "2021-03-17", "2023" = "2023-11-22", "2025" = "2025-10-29"
)

#' Party-group definitions, derived from the reference tables.
#'
#' @param green_class The green classification table (`load_green_classification()`).
#' @return Named list of `party_short` vectors.
green_party_groups <- function(green_class) {
  green_all <- green_class$party
  gl_pvda   <- intersect(c("GL", "PvdA", "GL-PvdA"), green_all)
  groenen   <- intersect(c("Groenen", "PP-Groenen"), green_all)
  list(
    green          = green_all,
    green_core     = setdiff(green_all, gl_pvda),
    gl_pvda_family = gl_pvda,
    pvdd           = intersect("PvdD", green_all),
    volt           = intersect("Volt", green_all),
    groenen_family = groenen
  )
}

#' Estimate every party group's PC4 share for all election years.
#'
#' @param pc4_long_obs Observed PC4 long rows (harmonized, `imputed == FALSE`),
#'   bound over years.
#' @param gem_long     Gemeente long rows (harmonized, complete tally), bound
#'   over years.
#' @param weights      PC4 -> gemeente weights (`build_pc4_gemeente_weights()`).
#' @param groups       Named list of party groups (`green_party_groups()`).
#' @return List with `wide` (one row per PC4 x election year, one `<group>_share`
#'   column per group plus the headline diagnostics) and `detail` (the full
#'   estimator output for the headline `green` group).
estimate_group_panel <- function(pc4_long_obs, gem_long, weights, groups) {
  pc4_universe <- sort(unique(pc4_long_obs$area_code))

  estimates <- lapply(names(groups), function(g) {
    members <- groups[[g]]
    est <- estimate_pc4_shares(
      pc4_group    = group_totals(pc4_long_obs, members),
      gem_group    = group_totals(gem_long, members),
      weights      = weights,
      pc4_universe = pc4_universe
    )
    message(sprintf("  group %-15s tau^2 = %.4f  psi^2 = %.4f  (%s PC4-year cells, %.1f%% observed)",
                    g, attr(est, "tau2"), attr(est, "psi2"),
                    format(nrow(est), big.mark = ","), 100 * mean(est$observed)))
    est
  })
  names(estimates) <- names(groups)

  headline <- estimates[["green"]]

  wide <- headline %>%
    transmute(
      .data$year, pc4 = .data$area_code,
      green_share          = .data$share,
      green_share_se       = .data$share_se,
      green_share_observed = .data$share_observed,
      green_share_municipal = .data$share_municipal,
      green_votes  = .data$group_votes,
      valid_votes  = .data$valid_votes,
      observed     = .data$observed,
      estimate_method = .data$estimate_method,
      pc4_effect   = .data$pc4_effect,
      n_years_observed = .data$n_years_obs,
      reference_level  = .data$ref_level
    )

  for (g in setdiff(names(groups), "green")) {
    add <- estimates[[g]] %>%
      transmute(.data$year, pc4 = .data$area_code, !!paste0(g, "_share") := .data$share)
    wide <- left_join(wide, add, by = c("year", "pc4"))
  }

  list(wide = wide, detail = headline, estimates = estimates)
}

#' Roll the election-year estimates forward into a balanced calendar-year panel.
#'
#' Every calendar year takes the most recent election on or before it
#' (last observation carried forward) -- the standard convention for a variable
#' that is only measured at elections, and the one the panel is asked for.
#'
#' @param wide       Election-year estimates (`estimate_group_panel()$wide`).
#' @param weights    PC4 -> gemeente weights, for the dominant-municipality labels.
#' @param start_year First calendar year (default: earliest election).
#' @param end_year   Last calendar year (default: the current year, so the panel
#'   runs up to today).
#' @return Long tibble, one row per PC4 x calendar year.
build_green_panel <- function(wide, weights, start_year = NULL, end_year = NULL) {
  election_years <- sort(unique(as.integer(wide$year)))
  if (is.null(start_year)) start_year <- min(election_years)
  if (is.null(end_year))   end_year   <- as.integer(format(Sys.Date(), "%Y"))
  if (end_year < start_year) stop("end_year must be >= start_year")

  by_source <- split(wide, as.integer(wide$year))

  blocks <- lapply(start_year:end_year, function(y) {
    prior <- election_years[election_years <= y]
    if (!length(prior)) return(NULL)
    sy <- max(prior)
    block <- by_source[[as.character(sy)]]
    block$year <- y
    block$source_year <- sy
    block$is_election_year <- y %in% election_years
    block$election_date <- as.Date(TK_ELECTION_DATES[[as.character(sy)]])
    block
  })

  # Dominant municipality of each PC4, as a label (weights are ordered).
  gem_label <- weights %>%
    group_by(pc4 = .data$area_code) %>%
    slice_max(.data$weight, n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    transmute(.data$pc4, gem_code = .data$gem_code, gem_name = .data$gem_name,
              gem_weight = .data$weight)

  dplyr::bind_rows(blocks) %>%
    left_join(gem_label, by = "pc4") %>%
    select("year", "pc4", "green_share", "green_share_se",
           dplyr::ends_with("_share"), "green_share_observed",
           "green_share_municipal", "green_votes", "valid_votes", "observed",
           "estimate_method", "pc4_effect", "n_years_observed",
           "reference_level", "gem_code", "gem_name", "gem_weight",
           "source_year", "election_date", "is_election_year") %>%
    arrange(.data$year, .data$pc4)
}
