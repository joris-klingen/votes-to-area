#!/usr/bin/env Rscript
# build_gemeente_crosswalk.R
#
# (Re)build the municipality boundary reference tables from CBS StatLine table
# 70739ned ("Gebieden; overzicht vanaf 1830"), which records every Dutch
# municipality code with its start/end date and, for each abolished
# municipality, the municipalities it was merged into with the number of
# inhabitants transferred to each.
#
# Writes (committed, so the pipeline itself needs no CBS access):
#   reference/gemeente_periods.csv    every municipality code valid at some point
#                                     since GEMEENTE_PERIODS_FROM, with its
#                                     validity period
#   reference/gemeente_crosswalk.csv  every such code -> the municipality/ies it
#                                     belongs to on GEMEENTE_TARGET_DATE, with a
#                                     population weight (splits sum to 1)
#
# Multi-step reorganisations are chained (e.g. Graafstroom -> Molenwaard (2013)
# -> Molenlanden (2019)); split weights multiply along the chain. Weights are
# the share of the abolished municipality's inhabitants transferred to each
# successor (by hectares if CBS reports no inhabitants). Small boundary
# corrections between surviving municipalities ("Grenswijziging") are ignored.
#
# Usage:
#   Rscript scripts/build_gemeente_crosswalk.R
#
# Requires: jsonlite, dplyr, readr.

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(readr)
})

this_file <- tryCatch(normalizePath(sys.frame(1)$ofile), error = function(e) NULL)
if (is.null(this_file)) {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  this_file <- if (length(file_arg)) normalizePath(file_arg) else "scripts/build_gemeente_crosswalk.R"
}
project_root <- dirname(dirname(this_file))

# ---- Configuration ---------------------------------------------------------
GEMEENTE_TARGET_DATE  <- as.Date("2025-10-29")  # TK2025 election day
GEMEENTE_PERIODS_FROM <- as.Date("2010-01-01")  # keep codes valid on/after this
CBS_ODATA <- "https://opendata.cbs.nl/ODataApi/odata/70739ned"

#' Fetch all rows of a CBS OData collection, following `odata.nextLink`.
fetch_odata <- function(url) {
  rows <- list()
  while (!is.null(url)) {
    page <- jsonlite::fromJSON(url)
    rows[[length(rows) + 1]] <- page$value
    url <- page[["odata.nextLink"]]
  }
  dplyr::bind_rows(rows)
}

filter_gm <- "?$filter=startswith(%s,'GM')"
regios <- fetch_odata(paste0(CBS_ODATA, "/RegioS", sprintf(filter_gm, "Key")))
dates  <- fetch_odata(paste0(CBS_ODATA, "/TypedDataSet", sprintf(filter_gm, "RegioS")))

#' "GM0017" -> "17" (the Kiesraad files use the CBS number without leading zeros).
kiesraad_code <- function(cbs_code) as.character(as.integer(sub("^GM", "", trimws(cbs_code))))

parse_ymd <- function(x) as.Date(trimws(x), format = "%Y%m%d")

periods <- regios %>%
  # CBS disambiguates a few names ("Groningen (gemeente)"); the suffix is noise here.
  transmute(cbs_code = trimws(.data$Key),
            name = sub(" \\(gemeente\\)$", "", trimws(.data$Title)),
            description = .data$Description) %>%
  filter(.data$cbs_code != "GM0998") %>%   # "Buitenland": a CBS pseudo-code, not a municipality
  inner_join(dates %>% transmute(cbs_code = trimws(.data$RegioS),
                                 begin_date = parse_ymd(.data$BegindatumSorteerveld_6),
                                 end_date   = parse_ymd(.data$EinddatumSorteerveld_7)),
             by = "cbs_code") %>%
  mutate(code = kiesraad_code(.data$cbs_code)) %>%
  filter(is.na(.data$end_date) | .data$end_date > GEMEENTE_PERIODS_FROM)

alive_on <- function(p, date) {
  (is.na(p$begin_date) | p$begin_date <= date) & (is.na(p$end_date) | p$end_date > date)
}

#' Parse the direct successors of an abolished / renamed municipality from the
#' first block of its CBS description: the header line plus the "- ..." /
#' "... ..." lines directly below it (older history follows, not always after a
#' blank line). Returns a tibble (to_cbs, weight).
parse_successors <- function(description) {
  lines <- strsplit(description, "\r\n", fixed = TRUE)[[1]]
  body  <- lines[-1]
  n_body <- match(FALSE, grepl("^(- |\\.\\.\\. |nieuwe naam)", body), nomatch = length(body) + 1) - 1
  lines <- c(lines[1], body[seq_len(n_body)])

  if (grepl("^Naamswijziging", lines[1])) {
    first <- paste(lines, collapse = "\n")
    to <- regmatches(first, regexpr("GM[0-9]{4}", first))
    return(tibble::tibble(to_cbs = to, weight = 1))
  }
  if (!grepl("^Opgeheven per", lines[1])) {
    stop("Unrecognised CBS description: ", lines[1])
  }

  idx <- grep("^- .*\\(GM[0-9]{4}\\)", lines)
  to  <- regmatches(lines[idx], regexpr("GM[0-9]{4}", lines[idx]))
  detail <- lines[idx + 1]
  num <- function(pattern) {
    m <- regmatches(detail, regexec(pattern, detail))
    vapply(m, function(x) if (length(x) > 1) as.numeric(x[2]) else 0, numeric(1))
  }
  inhabitants <- num("([0-9]+) inwoner")
  hectares    <- num("([0-9]+) hectare")
  w <- if (sum(inhabitants) > 0) inhabitants else if (sum(hectares) > 0) hectares else rep(1, length(to))
  # Uninhabited transfers (e.g. Muiden's Pampus island to Amsterdam) get weight 0; drop them.
  tibble::tibble(to_cbs = to, weight = w / sum(w)) %>%
    group_by(.data$to_cbs) %>% summarise(weight = sum(.data$weight), .groups = "drop") %>%
    filter(.data$weight > 0)
}

target_alive <- alive_on(periods, GEMEENTE_TARGET_DATE)
by_cbs <- split(periods, periods$cbs_code)

#' Resolve one code to the municipalities valid on the target date.
resolve <- function(cbs, depth = 0) {
  if (depth > 10) stop("Crosswalk chain too deep at ", cbs)
  p <- by_cbs[[cbs]]
  if (is.null(p)) stop("Successor ", cbs, " not in CBS periods table")
  if (alive_on(p, GEMEENTE_TARGET_DATE)) return(tibble::tibble(to_cbs = cbs, weight = 1))
  succ <- parse_successors(p$description)
  dplyr::bind_rows(lapply(seq_len(nrow(succ)), function(i) {
    r <- resolve(succ$to_cbs[i], depth + 1)
    r$weight <- r$weight * succ$weight[i]
    r
  })) %>%
    group_by(.data$to_cbs) %>% summarise(weight = sum(.data$weight), .groups = "drop")
}

target_names <- periods %>% filter(target_alive) %>% select("to_cbs" = "cbs_code", "to_name" = "name")

crosswalk <- dplyr::bind_rows(lapply(periods$cbs_code, function(cbs) {
  r <- resolve(cbs)
  r$from_cbs <- cbs
  r
})) %>%
  left_join(periods %>% select("from_cbs" = "cbs_code", "from_code" = "code", "from_name" = "name"),
            by = "from_cbs") %>%
  left_join(target_names, by = "to_cbs") %>%
  mutate(to_code = kiesraad_code(.data$to_cbs), weight = round(.data$weight, 6)) %>%
  select("from_code", "from_name", "to_code", "to_name", "weight") %>%
  arrange(as.integer(.data$from_code), dplyr::desc(.data$weight))

stopifnot(!anyNA(crosswalk$to_name))
sums <- crosswalk %>% group_by(.data$from_code) %>% summarise(w = sum(.data$weight))
stopifnot(all(abs(sums$w - 1) < 1e-4))

periods_out <- periods %>%
  select("code", "cbs_code", "name", "begin_date", "end_date") %>%
  arrange(as.integer(.data$code))

ref_dir <- file.path(project_root, "reference")
readr::write_csv(periods_out, file.path(ref_dir, "gemeente_periods.csv"), na = "")
readr::write_csv(crosswalk, file.path(ref_dir, "gemeente_crosswalk.csv"), na = "")

message(sprintf(
  "Wrote %d municipality periods and %d crosswalk rows (%d codes -> %d municipalities on %s; %d split).",
  nrow(periods_out), nrow(crosswalk), dplyr::n_distinct(crosswalk$from_code),
  dplyr::n_distinct(crosswalk$to_code), format(GEMEENTE_TARGET_DATE),
  sum(table(crosswalk$from_code) > 1)))
