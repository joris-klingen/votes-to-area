#!/usr/bin/env Rscript
# validate_estimator.R
#
# Leave-one-election-out cross-validation of the PC4 green-share estimator.
#
# For each election year in turn, the PC4 effects are re-estimated *without*
# that year, the year is then predicted out of sample, and the prediction is
# compared with what was actually observed in the PC4s that year does observe.
# Two predictors are scored:
#
#   municipal   the naive fill -- the PC4 gets its municipality's share
#               (what the all-party tables' `imputed` rows use);
#   model       the estimator in R/estimate.R -- municipality plus the PC4's own
#               persistent, shrunken deviation, estimated from the other years.
#
# This is the honest test of the modelling choice: the held-out year's votes are
# not used at any point in producing its prediction.
#
# Usage: Rscript scripts/validate_estimator.R   (run `Rscript run.R` first)

suppressPackageStartupMessages({
  library(dplyr)
  library(nanoparquet)
})

project_root <- dirname(dirname(normalizePath(sub("^--file=", "",
  commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))]))))

source(file.path(project_root, "R", "harmonize.R"))
source(file.path(project_root, "R", "estimate.R"))
source(file.path(project_root, "R", "green_panel.R"))

processed_dir <- file.path(project_root, "data", "processed")
pc4_path <- file.path(processed_dir, "tk_pc4_all_years_long.parquet")
gem_path <- file.path(processed_dir, "tk_gemeente_all_years_long.parquet")
if (!file.exists(pc4_path)) stop("Run `Rscript run.R` first: ", pc4_path, " not found.")

pc4_long <- as_tibble(read_parquet(pc4_path)) %>% filter(!.data$imputed)
gem_long <- as_tibble(read_parquet(gem_path))

green_class <- load_green_classification(file.path(project_root, GREEN_CLASSIFICATION_CSV))
groups <- green_party_groups(green_class)

# The processed long tables carry no municipality column at the PC4 level, so
# the PC4 -> gemeente weights cannot be rebuilt from them; `run.R` writes the
# crosswalk out for exactly this purpose.
weights_path <- file.path(processed_dir, "pc4_gemeente_weights.parquet")
if (!file.exists(weights_path)) stop("Run `Rscript run.R` first: ", weights_path, " not found.")
weights <- as_tibble(read_parquet(weights_path))

# Minimum size of a held-out cell to score: below this the "truth" is itself
# mostly sampling noise and the comparison says little.
MIN_VOTES <- 100

score <- function(actual, predicted) {
  ok <- is.finite(actual) & is.finite(predicted)
  a <- actual[ok]; p <- predicted[ok]
  c(n = length(a), rmse = sqrt(mean((p - a)^2)), mae = mean(abs(p - a)),
    bias = mean(p - a), cor = stats::cor(p, a))
}

results <- list()
for (g in c("green", "green_core", "gl_pvda_family")) {
  members  <- groups[[g]]
  pc4_grp  <- group_totals(pc4_long, members)
  gem_grp  <- group_totals(gem_long, members)
  universe <- sort(unique(pc4_grp$area_code))

  for (holdout in sort(unique(pc4_grp$year))) {
    train <- filter(pc4_grp, .data$year != holdout)
    est <- estimate_pc4_shares(train, gem_grp, weights, pc4_universe = universe)

    truth <- pc4_grp %>%
      filter(.data$year == holdout, .data$valid_votes >= MIN_VOTES) %>%
      transmute(.data$area_code, actual = .data$group_votes / .data$valid_votes)

    cmp <- est %>%
      filter(.data$year == holdout) %>%
      inner_join(truth, by = "area_code")

    results[[length(results) + 1]] <- bind_rows(
      data.frame(group = g, holdout_year = holdout, predictor = "municipal",
                 t(score(cmp$actual, cmp$share_municipal))),
      data.frame(group = g, holdout_year = holdout, predictor = "model",
                 t(score(cmp$actual, cmp$share_model)))
    )
  }
}

res <- bind_rows(results)
res$rmse_pp <- 100 * res$rmse
res$mae_pp  <- 100 * res$mae

cat("\nLeave-one-election-out prediction of observed PC4 shares",
    sprintf("(cells with >= %d valid votes)\n\n", MIN_VOTES))
print(res %>%
        select("group", "holdout_year", "predictor", "n", "rmse_pp", "mae_pp", "cor") %>%
        as.data.frame(), row.names = FALSE, digits = 3)

gain <- res %>%
  select("group", "holdout_year", "predictor", "rmse") %>%
  arrange(.data$group, .data$holdout_year, .data$predictor) %>%
  group_by(.data$group, .data$holdout_year) %>%
  summarise(rmse_municipal_pp = 100 * .data$rmse[.data$predictor == "municipal"],
            rmse_model_pp     = 100 * .data$rmse[.data$predictor == "model"],
            reduction_pct = 100 * (1 - .data$rmse[.data$predictor == "model"] /
                                     .data$rmse[.data$predictor == "municipal"]),
            .groups = "drop")

cat("\nRMSE reduction of the model over the municipal fill:\n\n")
print(as.data.frame(gain), row.names = FALSE, digits = 3)

out <- file.path(processed_dir, "estimator_validation.csv")
utils::write.csv(res, out, row.names = FALSE)
cat("\nWrote ", out, "\n", sep = "")
