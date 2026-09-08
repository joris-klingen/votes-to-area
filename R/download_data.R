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
  ),
  # The 2025 bundle has no hard-coded resource URL here: its dataset page is
  # scraped for the "CSV formaat" ZIP at download time (see resolve_zip_url()),
  # so the pipeline picks it up without this file needing an edit. If the page
  # layout ever changes, download the ZIP by hand and drop it in
  # data/raw/TK2025_CSV.zip -- the pipeline reuses a cached ZIP.
  "2025" = list(
    dataset_url = "https://data.overheid.nl/dataset/verkiezingsuitslag-tweede-kamer-2025"
  )
)

# Election years available in this project, oldest first.
TK_YEARS <- names(TK_DATASETS)

# The two CSVs of interest inside a bundle, matched on the stable part of their
# name rather than the exact file name, so a year that spells it slightly
# differently still resolves.
CSV_PATTERNS <- c(stembureau = "Stemmen[_ ]?Per[_ ]?Lijst[_ ]?Per[_ ]?Stembureau",
                  gemeente   = "Stemmen[_ ]?Per[_ ]?Lijst[_ ]?Per[_ ]?Gemeente")

#' Pick the member of a ZIP holding one of the two results CSVs.
#'
#' @param contents File names inside the ZIP.
#' @param key      "stembureau" or "gemeente".
#' @return The matching member name, or NA when the bundle has none.
match_csv_member <- function(contents, key) {
  hits <- grep(paste0(CSV_PATTERNS[[key]], ".*\\.csv$"), contents,
               ignore.case = TRUE, value = TRUE)
  if (!length(hits)) return(NA_character_)
  # Prefer a top-level member, then the shortest name (avoids "..._toelichting").
  hits[order(lengths(strsplit(hits, "/")), nchar(hits))][1]
}

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

#' Find the "CSV formaat" ZIP on a data.overheid.nl dataset page.
#'
#' Newer datasets are added to the portal with a fresh resource UUID, so rather
#' than hard-coding a URL that has to be looked up by hand, the dataset page is
#' read and the ZIP resource whose link mentions "CSV" is taken.
#'
#' @param dataset_url The dataset landing page.
#' @return The absolute ZIP URL.
resolve_zip_url <- function(dataset_url) {
  message("Looking up the CSV bundle on ", dataset_url, " ...")
  html <- tryCatch(
    {
      con <- url(dataset_url, headers = c("User-Agent" = DOWNLOAD_USER_AGENT))
      on.exit(close(con), add = TRUE)
      paste(readLines(con, warn = FALSE), collapse = "\n")
    },
    error = function(e) stop("Could not read ", dataset_url, ": ", conditionMessage(e),
                             "\nDownload the CSV bundle by hand and save it as the ",
                             "cached ZIP instead.", call. = FALSE)
  )

  hrefs <- unlist(regmatches(html, gregexpr('"https?://[^"]+?\\.zip"', html)))
  hrefs <- gsub('"', "", hrefs)
  if (!length(hrefs)) stop("No ZIP resource found on ", dataset_url, call. = FALSE)
  csv_hrefs <- grep("csv", hrefs, ignore.case = TRUE, value = TRUE)
  if (length(csv_hrefs)) hrefs <- csv_hrefs
  hrefs[1]
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
    zip_url <- cfg$zip_url
    if (is.null(zip_url)) zip_url <- resolve_zip_url(cfg$dataset_url)
    message("Downloading Kiesraad TK", year, " CSV bundle ...")
    robust_download(zip_url, zip_path)
  } else {
    message("Using cached ZIP: ", zip_path)
  }

  # Extract whatever of the two expected CSVs the bundle actually contains.
  contents <- utils::unzip(zip_path, list = TRUE)$Name
  want <- vapply(names(CSV_PATTERNS), function(k) match_csv_member(contents, k),
                 character(1))
  present <- want[!is.na(want)]
  if (length(present) > 0) {
    utils::unzip(zip_path, files = unname(present), exdir = raw_dir, overwrite = TRUE)
  }

  path_for <- function(key) {
    if (is.na(want[[key]])) return(NA_character_)
    normalizePath(file.path(raw_dir, want[[key]]))
  }
  list(year = year, stembureau_csv = path_for("stembureau"), gemeente_csv = path_for("gemeente"))
}
