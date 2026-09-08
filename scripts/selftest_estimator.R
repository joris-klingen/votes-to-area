#!/usr/bin/env Rscript
# selftest_estimator.R
#
# Self-contained check of the PC4 share estimator (R/estimate.R) on simulated
# data: no download, no processed tables, no network. It generates a synthetic
# country whose PC4s have persistent, known deviations from their municipality,
# hides part of the PC4-year cells the way the real source data does, and checks
# that the estimator recovers the hidden truth better than the municipal fill.
#
# Usage: Rscript scripts/selftest_estimator.R

suppressPackageStartupMessages(library(dplyr))

project_root <- dirname(dirname(normalizePath(sub("^--file=", "",
  commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))]))))
source(file.path(project_root, "R", "estimate.R"))

set.seed(20260908)

n_gem <- 60; per_gem <- 8
years <- c("2012", "2017", "2021", "2023")
# National green share drifts between elections, as it does in reality.
nat <- c("2012" = 0.09, "2017" = 0.13, "2021" = 0.16, "2023" = 0.22)
# Postcode coverage of the real source, by year.
coverage <- c("2012" = 0.69, "2017" = 0.64, "2021" = 0.86, "2023" = 0.92)

gem <- tibble(gem_code = sprintf("GM%04d", seq_len(n_gem)),
              gem_effect = rnorm(n_gem, 0, 0.45))
pc4 <- tibble(
  area_code = sprintf("%04d", 1000 + seq_len(n_gem * per_gem)),
  gem_code  = rep(gem$gem_code, each = per_gem),
  pc4_effect_true = rnorm(n_gem * per_gem, 0, 0.40),   # persistent within-gemeente
  size = round(exp(rnorm(n_gem * per_gem, log(2500), 0.8)))
)

cells <- tidyr_expand(pc4$area_code, years) %>%
  left_join(pc4, by = "area_code") %>%
  left_join(gem, by = "gem_code") %>%
  mutate(
    logit_gem  = logit(nat[.data$year]) + .data$gem_effect,
    logit_true = .data$logit_gem + .data$pc4_effect_true + rnorm(dplyr::n(), 0, 0.12),
    p_true     = expit(.data$logit_true),
    votes_pc4  = pmax(30, round(.data$size * runif(dplyr::n(), 0.85, 1.15))),
    green_pc4  = rbinom(dplyr::n(), .data$votes_pc4, .data$p_true),
    seen       = runif(dplyr::n()) < coverage[.data$year]
  )

# Municipal tallies are complete in every year (as in the real source).
gem_group <- cells %>%
  group_by(year = .data$year, area_code = .data$gem_code) %>%
  summarise(group_votes = sum(.data$green_pc4), valid_votes = sum(.data$votes_pc4),
            .groups = "drop")

# PC4 observations exist only where the postcode was recorded.
pc4_group <- cells %>%
  filter(.data$seen) %>%
  transmute(.data$year, .data$area_code, group_votes = .data$green_pc4,
            valid_votes = .data$votes_pc4)

weights <- transmute(pc4, .data$area_code, .data$gem_code, gem_name = .data$gem_code,
                     weight = 1)

est <- estimate_pc4_shares(pc4_group, gem_group, weights,
                           pc4_universe = sort(pc4$area_code))

check <- est %>%
  inner_join(select(cells, "year", "area_code", "p_true", "seen"),
             by = c("year", "area_code")) %>%
  filter(!.data$seen)   # score only the cells the estimator could not observe

rmse <- function(x, y) sqrt(mean((x - y)^2))
r_mun <- rmse(check$share_municipal, check$p_true)
r_mod <- rmse(check$share, check$p_true)

cat(sprintf("\nSimulated: %s PC4s in %s municipalities, %s elections\n",
            nrow(pc4), n_gem, length(years)))
cat(sprintf("Estimated tau^2 = %.3f (true 0.160), psi^2 = %.4f (true 0.0144)\n",
            attr(est, "tau2"), attr(est, "psi2")))
cat(sprintf("Held-out (unobserved) cells: %s\n", format(nrow(check), big.mark = ",")))
cat(sprintf("  RMSE municipal fill : %.4f (%.2f pp)\n", r_mun, 100 * r_mun))
cat(sprintf("  RMSE model          : %.4f (%.2f pp)\n", r_mod, 100 * r_mod))
cat(sprintf("  reduction           : %.1f%%\n", 100 * (1 - r_mod / r_mun)))

stopifnot(
  "model must beat the municipal fill on unobserved cells" = r_mod < r_mun,
  "shares must be valid probabilities" = all(est$share > 0 & est$share < 1),
  "every PC4-year must get an estimate" = !any(is.na(est$share)),
  "observed cells must be flagged" = sum(est$observed) == nrow(pc4_group)
)
cat("\nAll self-test checks passed.\n")
