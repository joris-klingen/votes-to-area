#!/usr/bin/env Rscript
# setup.R
#
# Install the R packages required by this project.
#
# Uses the Posit Public Package Manager (rspm) binary repository, which serves
# pre-compiled Linux binaries and is much faster than compiling from source on
# CRAN. Adjust the release codename in the URL if you are not on Ubuntu 24.04
# ("noble"); see https://packagemanager.posit.co for the correct snapshot URL.

repo <- Sys.getenv(
  "RSPM_REPO",
  unset = "https://rspm-sync.rstudio.com/all/__linux__/noble/latest"
)

options(repos = c(RSPM = repo, CRAN = "https://cloud.r-project.org"))

required <- c("readr", "dplyr", "stringr", "nanoparquet")
missing  <- required[!required %in% rownames(installed.packages())]

if (length(missing) == 0) {
  message("All required packages already installed: ", paste(required, collapse = ", "))
} else {
  message("Installing: ", paste(missing, collapse = ", "))
  install.packages(missing)
}
