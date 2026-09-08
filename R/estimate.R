# estimate.R
#
# Best-estimate PC4 vote shares for a group of parties (here: the green /
# environmental parties), for every PC4 in every election year -- including the
# PC4-years the source data does not observe.
#
# Why this is not just "observed share, else municipal share":
#
#   * Coverage of the polling-station postcode is partial in the older
#     elections (2012: ~69%, 2017: ~64%), so a third of the PC4-years have to be
#     inferred from somewhere.
#   * The naive fill -- give an unobserved PC4 its municipality's share -- throws
#     away the single most informative fact we have about that PC4: how it votes
#     relative to its municipality in the years it *is* observed. Within-
#     municipality differences between postcode areas are large and highly
#     persistent (a leafy PC4 is greener than its city in every election), so the
#     municipal fill is badly biased for exactly the areas that are interesting.
#   * Observed shares in small PC4s (a few dozen votes) are noisy; taking them at
#     face value adds sampling variance to the panel.
#
# The estimator therefore models each PC4's share on the log-odds scale as its
# municipality's share in that year plus a persistent PC4 effect:
#
#   logit(p_it) = logit(m_it) + d_i + e_it
#
#     m_it  the (weighted) share of the municipalit(y/ies) the PC4 lies in,
#           taken from the *complete* municipal tally, which is observed for
#           every municipality in the source in every year;
#     d_i   a PC4 fixed effect -- how much greener/less green the area votes
#           than its municipality -- estimated by precision-weighted pooling
#           over the years the PC4 is observed, and shrunk towards 0 with an
#           empirical-Bayes (DerSimonian-Laird) factor so that thinly observed
#           PC4s do not get an over-fitted effect;
#     e_it  a year-specific deviation with variance psi^2, the part that is not
#           predictable from the municipality and the PC4 effect.
#
# Every PC4-year estimate is then the precision-weighted combination of what was
# observed (if anything) and what the model predicts:
#
#   observed   -> posterior mean of logit(share): heavily observation-driven for
#                 a normal PC4 with thousands of votes, shrunk towards the model
#                 when the observed cell is thin;
#   unobserved -> the model prediction expit(logit(m_it) + d_i).
#
# Both cases carry a standard error, and `estimate_method` says which applies.
# `scripts/validate_estimator.R` cross-validates the gain over the municipal
# fill by holding out observed PC4-years.

suppressPackageStartupMessages({
  library(dplyr)
})

# ---- Small numeric helpers -------------------------------------------------

#' Log-odds, guarding against 0/1 (which would give +/-Inf).
logit <- function(p, eps = 1e-6) {
  p <- pmin(pmax(p, eps), 1 - eps)
  log(p / (1 - p))
}

#' Inverse of [logit()].
expit <- function(x) 1 / (1 + exp(-x))

#' Variance of a logit-transformed binomial proportion (delta method).
#' Uses a reference share `p` rather than the noisy observed one.
logit_var <- function(n, p, eps = 1e-6) {
  p <- pmin(pmax(p, eps), 1 - eps)
  1 / pmax(n * p * (1 - p), 1e-8)
}

# ---- PC4 -> gemeente weights -----------------------------------------------

#' Build weighted PC4 -> municipality links from the observed polling stations.
#'
#' A PC4 area can straddle municipal borders, and municipalities are merged and
#' renamed between elections. Rather than assigning each PC4 to a single
#' municipality, this records *every* municipality a PC4 was ever seen in,
#' weighted by the votes cast there (pooled over all years), so a PC4's
#' municipal reference share is a properly weighted mixture. Weights are
#' renormalised later over the municipalities actually present in a given year,
#' which is what makes the crosswalk robust to municipal reorganizations.
#'
#' @param votes_by_year Named list of per-polling-station tibbles (names = years).
#' @return Tibble `area_code`, `gem_code`, `gem_name`, `weight` (sums to 1 per
#'   PC4), ordered with the dominant municipality first.
build_pc4_gemeente_weights <- function(votes_by_year) {
  pairs <- dplyr::bind_rows(lapply(names(votes_by_year), function(y) {
    v <- votes_by_year[[y]]
    tibble::tibble(
      area_code = derive_pc4(v$Postcode),
      gem_code  = v$GemeenteCode,
      gem_name  = v$GemeenteNaam,
      votes     = v$AantalStemmen
    )
  }))

  pairs %>%
    filter(!is.na(.data$area_code), !is.na(.data$gem_code)) %>%
    group_by(.data$area_code, .data$gem_code, .data$gem_name) %>%
    summarise(votes = sum(.data$votes, na.rm = TRUE), .groups = "drop") %>%
    group_by(.data$area_code) %>%
    mutate(weight = .data$votes / sum(.data$votes)) %>%
    arrange(.data$area_code, dplyr::desc(.data$weight), .by_group = FALSE) %>%
    ungroup() %>%
    select("area_code", "gem_code", "gem_name", "weight")
}

# ---- Party groups ----------------------------------------------------------

#' Collapse a harmonized long table to one row per area x year x party group.
#'
#' @param long   Harmonized long table (needs `year`, `area_code`, `party_short`,
#'   `votes`); only rows with observed vote counts are used.
#' @param members Character vector of `party_short` values in the group.
#' @return Tibble `year`, `area_code`, `group_votes`, `valid_votes`.
group_totals <- function(long, members) {
  long %>%
    filter(!is.na(.data$votes)) %>%
    group_by(.data$year, .data$area_code) %>%
    summarise(
      group_votes = sum(.data$votes[.data$party_short %in% members], na.rm = TRUE),
      valid_votes = sum(.data$votes, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    filter(.data$valid_votes > 0)
}

# ---- The estimator ---------------------------------------------------------

#' Municipal reference share for every PC4 x year.
#'
#' Weighted mixture of the shares of the municipalities the PC4 lies in,
#' renormalised over those present in that year. PC4s whose municipalities are
#' all missing from a year (2017 has ~110 municipalities that filed paper-only
#' counts, so they exist in no machine-readable file) fall back to the national
#' share of that year, flagged `ref_level = "national"`.
#'
#' @param gem_group  Municipal group totals (`group_totals()` on the gemeente table).
#' @param weights    PC4 -> gemeente weights (`build_pc4_gemeente_weights()`).
#' @param pc4_universe Character vector of PC4 codes to produce a row for.
#' @param years      Character vector of election years.
#' @return Tibble `year`, `area_code`, `ref_share`, `ref_level`, `nat_share`.
municipal_reference <- function(gem_group, weights, pc4_universe, years) {
  national <- gem_group %>%
    group_by(.data$year) %>%
    summarise(nat_share = sum(.data$group_votes) / sum(.data$valid_votes),
              .groups = "drop")

  gem_share <- gem_group %>%
    transmute(.data$year, gem_code = .data$area_code,
              gem_share = .data$group_votes / .data$valid_votes)

  grid <- tidyr_expand(pc4_universe, years)

  mixed <- grid %>%
    inner_join(weights, by = "area_code", relationship = "many-to-many") %>%
    inner_join(gem_share, by = c("year", "gem_code")) %>%
    group_by(.data$year, .data$area_code) %>%
    summarise(ref_share = sum(.data$weight * .data$gem_share) / sum(.data$weight),
              .groups = "drop") %>%
    mutate(ref_level = "gemeente")

  grid %>%
    left_join(mixed, by = c("year", "area_code")) %>%
    left_join(national, by = "year") %>%
    mutate(
      ref_level = dplyr::if_else(is.na(.data$ref_share), "national", .data$ref_level),
      ref_share = dplyr::coalesce(.data$ref_share, .data$nat_share)
    ) %>%
    select("year", "area_code", "ref_share", "ref_level", "nat_share")
}

#' Full PC4 x year grid (avoids a tidyr dependency).
tidyr_expand <- function(pc4_universe, years) {
  tibble::tibble(
    area_code = rep(pc4_universe, times = length(years)),
    year      = rep(as.character(years), each = length(pc4_universe))
  )
}

#' DerSimonian-Laird estimate of the between-PC4 variance of the PC4 effect.
#'
#' @param d Per-PC4 pooled effects.
#' @param W Per-PC4 summed precisions (so 1/W is the sampling variance of `d`).
#' @return Non-negative scalar tau^2.
dl_tau2 <- function(d, W) {
  keep <- is.finite(d) & is.finite(W) & W > 0
  d <- d[keep]; W <- W[keep]
  if (length(d) < 2) return(0)
  dbar <- sum(W * d) / sum(W)
  Q    <- sum(W * (d - dbar)^2)
  denom <- sum(W) - sum(W^2) / sum(W)
  if (denom <= 0) return(0)
  max(0, (Q - (length(d) - 1)) / denom)
}

#' Estimate PC4 shares of a party group for every PC4 x election year.
#'
#' Implements the model documented at the top of this file.
#'
#' @param pc4_group  Observed PC4 group totals (`group_totals()` on the observed
#'   PC4 table -- imputed rows must be excluded, they carry no vote counts).
#' @param gem_group  Municipal group totals (complete tally).
#' @param weights    PC4 -> gemeente weights.
#' @param pc4_universe PC4 codes to estimate (default: every observed PC4).
#' @return Tibble with one row per PC4 x election year:
#'   `year`, `area_code`, `share` (the estimate), `share_observed`, `share_model`,
#'   `share_municipal` (the naive fill, for comparison), `group_votes`,
#'   `valid_votes`, `observed`, `estimate_method`, `share_se`, `pc4_effect`,
#'   `ref_level`.
estimate_pc4_shares <- function(pc4_group, gem_group, weights,
                                pc4_universe = NULL) {
  years <- sort(unique(c(pc4_group$year, gem_group$year)))
  if (is.null(pc4_universe)) pc4_universe <- sort(unique(pc4_group$area_code))

  ref <- municipal_reference(gem_group, weights, pc4_universe, years)

  # Observed cells, joined to their municipal reference.
  obs <- pc4_group %>%
    filter(.data$area_code %in% pc4_universe) %>%
    inner_join(ref, by = c("year", "area_code")) %>%
    mutate(
      share_observed = .data$group_votes / .data$valid_votes,
      # Continuity-corrected logit: keeps 0-vote and all-vote cells finite.
      logit_obs = logit((.data$group_votes + 0.5) / (.data$valid_votes + 1)),
      var_obs   = logit_var(.data$valid_votes, .data$ref_share),
      resid     = .data$logit_obs - logit(.data$ref_share),
      prec      = 1 / .data$var_obs
    )

  # PC4 effect and the two variance components, estimated jointly by a short
  # fixed-point iteration: a PC4-year residual carries both binomial sampling
  # noise (var_obs) and the unpredictable year deviation (psi^2), so pooling the
  # years of one PC4 must weight by 1/(var_obs + psi^2), which needs psi^2, which
  # needs the effects. Two rounds from psi^2 = 0 are plenty in practice.
  psi2 <- 0
  for (iter in 1:3) {
    obs$prec <- 1 / (obs$var_obs + psi2)

    eff <- obs %>%
      group_by(.data$area_code) %>%
      summarise(d_raw = sum(.data$prec * .data$resid) / sum(.data$prec),
                W = sum(.data$prec), n_years_obs = dplyr::n(), .groups = "drop")

    tau2 <- dl_tau2(eff$d_raw, eff$W)
    eff <- mutate(eff,
                  shrink = if (tau2 > 0) tau2 / (tau2 + 1 / .data$W) else 0,
                  pc4_effect = .data$d_raw * .data$shrink,
                  # Posterior variance of the shrunken effect.
                  effect_var = if (tau2 > 0) tau2 * (1 / .data$W) / (tau2 + 1 / .data$W) else 0)

    # psi^2: the year-specific deviation the model cannot predict -- the spread
    # of the residuals around the PC4 effect, net of sampling noise.
    idx <- match(obs$area_code, eff$area_code)
    dev <- obs$resid - eff$pc4_effect[idx]
    # Effective parameters used up by the (shrunken) PC4 effects, so the
    # residual spread is not deflated by the fit itself.
    df_used <- sum(eff$shrink)
    df_resid <- max(1, nrow(obs) - df_used)
    psi2 <- max(1e-4, sum(dev^2, na.rm = TRUE) / df_resid -
                  mean(obs$var_obs, na.rm = TRUE))
  }

  out <- ref %>%
    left_join(select(eff, "area_code", "pc4_effect", "effect_var", "n_years_obs"),
              by = "area_code") %>%
    left_join(select(obs, "year", "area_code", "group_votes", "valid_votes",
                     "share_observed", "logit_obs", "var_obs"),
              by = c("year", "area_code")) %>%
    mutate(
      pc4_effect = dplyr::coalesce(.data$pc4_effect, 0),
      effect_var = dplyr::coalesce(.data$effect_var, 0),
      n_years_obs = dplyr::coalesce(.data$n_years_obs, 0L),
      observed   = !is.na(.data$valid_votes),
      logit_pred = logit(.data$ref_share) + .data$pc4_effect,
      var_pred   = psi2 + .data$effect_var,
      # Posterior on the logit scale: observation and model prediction combined
      # by precision. Unobserved cells are the prediction alone.
      logit_hat = dplyr::if_else(
        .data$observed,
        (.data$logit_obs / .data$var_obs + .data$logit_pred / .data$var_pred) /
          (1 / .data$var_obs + 1 / .data$var_pred),
        .data$logit_pred),
      var_hat = dplyr::if_else(
        .data$observed,
        1 / (1 / .data$var_obs + 1 / .data$var_pred),
        .data$var_pred),
      share = expit(.data$logit_hat),
      # Delta-method SE on the share scale.
      share_se = sqrt(.data$var_hat) * .data$share * (1 - .data$share),
      share_model = expit(.data$logit_pred),
      share_municipal = .data$ref_share,
      # A group that stood nowhere in a year (Volt before 2021, the 2023-only
      # joint lists) has a share of exactly zero, not the logit floor.
      on_ballot = .data$nat_share > 0,
      share           = dplyr::if_else(.data$on_ballot, .data$share, 0),
      share_se        = dplyr::if_else(.data$on_ballot, .data$share_se, 0),
      share_model     = dplyr::if_else(.data$on_ballot, .data$share_model, 0),
      share_municipal = dplyr::if_else(.data$on_ballot, .data$share_municipal, 0),
      estimate_method = dplyr::case_when(
        .data$nat_share <= 0                 ~ "not_on_ballot",
        .data$observed                       ~ "observed",
        .data$n_years_obs > 0                ~ "modelled_pc4_effect",
        .data$ref_level == "gemeente"        ~ "modelled_municipal",
        TRUE                                 ~ "modelled_national"
      )
    ) %>%
    select("year", "area_code", "share", "share_se", "share_observed",
           "share_model", "share_municipal", "group_votes", "valid_votes",
           "observed", "estimate_method", "pc4_effect", "n_years_obs",
           "ref_level", "on_ballot") %>%
    arrange(.data$year, .data$area_code)

  attr(out, "tau2") <- tau2
  attr(out, "psi2") <- psi2
  out
}
