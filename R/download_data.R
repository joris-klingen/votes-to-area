# download_data.R
#
# Download the official Kiesraad open datasets for the Dutch general elections
# (Tweede Kamer) and extract their per-polling-station and per-municipality
# results CSVs.
#
# Source: data.overheid.nl, datasets "Verkiezingsuitslag(en) Tweede Kamer
# <year>", published by the Kiesraad (Dutch Electoral Council). Each year's
# "CSV formaat" bundle contains, since it was reprocessed by the Kiesraad, a
# tidy long CSV per party per polling station (with the station postcode where
# recorded in the EML) and a matching CSV per party per municipality.

# Per-year download configuration. Each entry gives the CSV ZIP bundle URL and
# the names of the two CSVs inside it. All years share the same column schema.
TK_DATASETS <- list(
  "2010" = list(
    zip_url = "https://data.overheid.nl/sites/default/files/dataset/fbf2c39e-b3c8-40c1-b52a-ba5c6b26cf1a/resources/Verkiezingsuitslagen%20Tweede%20Kamer%202010%20%28CSV%20formaat%29.zip"
  ),
  "2012" = list(
    zip_url = "https://data.overheid.nl/sites/default/files/dataset/31362154-3866-407d-97fd-96c9dc2639bc/resources/Verkiezingsuitslagen%20Tweede%20Kamer%202012%20%28CSV%20formaat%29.zip"
  ),
  "2017" = list(
    zip_url = "https://data.overheid.nl/sites/default/files/dataset/5f636036-1634-4c7b-8ac9-8c0b4995ff4d/resources/Verkiezingsuitslagen%20Tweede%20Kamer%202017%20%28CSV%20formaat%29.zip"
  ),
  "2021" = list(
    zip_url = "https://data.overheid.nl/sites/default/files/dataset/39e9bad4-4667-453f-ba6a-4733a956f6f8/resources/Verkiezingsuitslagen%20Tweede%20Kamer%202021%20%28CSV%20formaat%29.zip"
  ),
  "2023" = list(
    zip_url = "https://data.overheid.nl/sites/default/files/dataset/e3fe6e42-06ab-4559-a466-a32b04247f68/resources/Verkiezingsuitslag%20Tweede%20Kamer%202023%20%28CSV%20formaat%29.zip"
  )
)

# Election years available in this project, oldest first.
TK_YEARS <- names(TK_DATASETS)

#' File name of the per-polling-station CSV for a given year.
stembureau_csv_name <- function(year) sprintf("TK%s_Stemmen_Per_Lijst_Per_Stembureau.csv", year)

#' File name of the per-municipality CSV for a given year.
gemeente_csv_name <- function(year) sprintf("TK%s_Stemmen_Per_Lijst_Per_Gemeente.csv", year)

#' Download a URL to a file robustly.
#'
#' Uses the "libcurl" method explicitly (some R builds default to a method that
#' cannot negotiate TLS, which surfaces as an "SSL connection" / "unsupported
#' URL scheme" error), retries with exponential backoff, and falls back to the
#' `curl` package if it is installed. On persistent failure it errors with a
#' hint to download the file manually to `destfile`.
# Browser-like User-Agent. data.overheid.nl returns 403 Forbidden to requests
# with R's / curl's default agent string, so we present a common browser UA.
DOWNLOAD_USER_AGENT <- paste0(
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ",
  "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

robust_download <- function(url, destfile, tries = 4) {
  old_timeout <- getOption("timeout")
  old_ua      <- getOption("HTTPUserAgent")
  on.exit(options(timeout = old_timeout, HTTPUserAgent = old_ua), add = TRUE)
  options(timeout = max(600, old_timeout))
  # download.file(method = "libcurl") sends this as the User-Agent header.
  options(HTTPUserAgent = DOWNLOAD_USER_AGENT)

  attempt <- function(fn) tryCatch({ fn(); file.exists(destfile) && file.info(destfile)$size > 0 },
                                   error = function(e) { message("  download attempt failed: ", conditionMessage(e)); FALSE })

  for (i in seq_len(tries)) {
    ok <- attempt(function() {
      utils::download.file(url, destfile = destfile, mode = "wb",
                           quiet = FALSE, method = "libcurl")
    })
    if (ok) return(invisible(destfile))

    # Fall back to the curl package (independent TLS stack) if available,
    # passing the same browser User-Agent header.
    if (requireNamespace("curl", quietly = TRUE)) {
      ok <- attempt(function() {
        h <- curl::new_handle()
        curl::handle_setheaders(h, "User-Agent" = DOWNLOAD_USER_AGENT)
        curl::curl_download(url, destfile, mode = "wb", handle = h)
      })
      if (ok) return(invisible(destfile))
    }

    if (i < tries) {
      wait <- 2^i
      message("  retrying in ", wait, "s (attempt ", i + 1, "/", tries, ") ...")
      Sys.sleep(wait)
    }
  }

  stop("Failed to download after ", tries, " attempts:\n  ", url,
       "\nIf your network blocks this or R cannot negotiate TLS, download the ",
       "file manually in a browser and save it as:\n  ", normalizePath(destfile, mustWork = FALSE),
       "\nthen re-run (the pipeline reuses the cached ZIP).")
}

#' Download and extract one year's Kiesraad TK results.
#'
#' Downloads the year's CSV ZIP bundle to `raw_dir` (skipping the download when
#' the ZIP already exists and `force = FALSE`) and extracts the per-polling
#' station and per-municipality CSVs.
#'
#' @param year    Election year as a string or number (must be in `TK_YEARS`).
#' @param raw_dir Directory to store downloaded and extracted files.
#' @param force   If TRUE, re-download even when the ZIP is already present.
#' @return A list with elements `year`, `stembureau_csv`, `gemeente_csv`
#'   (absolute paths). A path is NA if that CSV is not present in the bundle.
download_kiesraad_tk <- function(year, raw_dir = file.path("data", "raw"),
                                 force = FALSE) {
  year <- as.character(year)
  if (!year %in% TK_YEARS) {
    stop("Unknown year '", year, "'. Available: ", paste(TK_YEARS, collapse = ", "))
  }
  cfg <- TK_DATASETS[[year]]
  dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

  zip_path <- file.path(raw_dir, sprintf("TK%s_CSV.zip", year))

  if (force || !file.exists(zip_path)) {
    message("Downloading Kiesraad TK", year, " CSV bundle ...")
    robust_download(cfg$zip_url, zip_path)
  } else {
    message("Using cached ZIP: ", zip_path)
  }

  # Extract whatever of the two expected CSVs the bundle actually contains.
  contents <- utils::unzip(zip_path, list = TRUE)$Name
  want <- c(stembureau = stembureau_csv_name(year),
            gemeente   = gemeente_csv_name(year))
  present <- want[want %in% contents]
  if (length(present) > 0) {
    utils::unzip(zip_path, files = unname(present), exdir = raw_dir, overwrite = TRUE)
  }

  path_for <- function(key) {
    if (want[[key]] %in% contents) normalizePath(file.path(raw_dir, want[[key]])) else NA_character_
  }
  list(year = year, stembureau_csv = path_for("stembureau"), gemeente_csv = path_for("gemeente"))
}
