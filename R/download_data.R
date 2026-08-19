# download_data.R
#
# Download the official Kiesraad open dataset for the 2023 Dutch general
# election (Tweede Kamer, 22 November 2023) and extract the per-polling-station
# results CSV.
#
# Source: data.overheid.nl, dataset "Verkiezingsuitslag Tweede Kamer 2023",
# published by the Kiesraad (Dutch Electoral Council). The "CSV formaat" bundle
# contains `TK2023_Stemmen_Per_Lijst_Per_Stembureau.csv`, a tidy processing of
# the underlying EML files with one row per party per polling station, including
# the polling station postcode where it was recorded in the EML.

# Direct download URL for the CSV bundle (a ZIP archive).
KIESRAAD_TK2023_CSV_ZIP_URL <- paste0(
  "https://data.overheid.nl/sites/default/files/dataset/",
  "e3fe6e42-06ab-4559-a466-a32b04247f68/resources/",
  "Verkiezingsuitslag%20Tweede%20Kamer%202023%20%28CSV%20formaat%29.zip"
)

# Name of the per-polling-station file inside the ZIP.
KIESRAAD_TK2023_STEMBUREAU_CSV <- "TK2023_Stemmen_Per_Lijst_Per_Stembureau.csv"

#' Download and extract the Kiesraad TK2023 per-polling-station results.
#'
#' Downloads the CSV ZIP bundle to `raw_dir` (skipping the download if the file
#' already exists and `force = FALSE`) and unzips it. Returns the path to the
#' extracted per-polling-station CSV.
#'
#' @param raw_dir Directory to store the downloaded ZIP and extracted files.
#' @param force   If TRUE, re-download even when the ZIP is already present.
#' @return Absolute path to `TK2023_Stemmen_Per_Lijst_Per_Stembureau.csv`.
download_kiesraad_tk2023 <- function(raw_dir = file.path("data", "raw"),
                                     force = FALSE) {
  dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

  zip_path <- file.path(raw_dir, "TK2023_CSV.zip")
  csv_path <- file.path(raw_dir, KIESRAAD_TK2023_STEMBUREAU_CSV)

  if (force || !file.exists(zip_path)) {
    message("Downloading Kiesraad TK2023 CSV bundle ...")
    # Large-ish binary download; use a generous timeout.
    old_timeout <- getOption("timeout")
    on.exit(options(timeout = old_timeout), add = TRUE)
    options(timeout = max(600, old_timeout))
    utils::download.file(
      url = KIESRAAD_TK2023_CSV_ZIP_URL,
      destfile = zip_path,
      mode = "wb",
      quiet = FALSE
    )
  } else {
    message("Using cached ZIP: ", zip_path)
  }

  if (force || !file.exists(csv_path)) {
    message("Extracting ", KIESRAAD_TK2023_STEMBUREAU_CSV, " ...")
    utils::unzip(
      zip_path,
      files = KIESRAAD_TK2023_STEMBUREAU_CSV,
      exdir = raw_dir,
      overwrite = TRUE
    )
  }

  if (!file.exists(csv_path)) {
    stop("Expected file not found after extraction: ", csv_path)
  }

  normalizePath(csv_path)
}
