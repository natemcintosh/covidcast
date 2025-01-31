#' Wrapper around `covidcast::covidcast_signal()` with additional logging and caching.
#' @param data_source a data source in covidcast.
#' @param signal a signal in covidcast.
#' @param start_day a date in the format "YYYY-MM-DD". First day of data to pull.
#' @param end_day a date in the format "YYYY-MM-DD". Last day of data to pull.
#' @param geo_type a geo type. One of "county", "state", "hrr", "msa", "nation", "hhs", "zip".
#' @param geo_values a geo value. If "*" all geo values returned, otherwise it should be a list of the geo values to query
#' e.g. c("ak", "ca") for states.
#' @param as_of a date in the format "YYYY-MM-DD". Pulls the latest issue of the data available in covidcast on this date.
#' @param time_type a string. For most signals this is "day", but for a select few this is "week". Check Epidata docs for info.
#' @param offline_signal_dir the directory that stores the cached data for each (signal, forecast day) pair. If this is
#' null, no caching is done and the data is downloaded from covidcast. The data is stored in a csv file with the format
#' 'offline_signal_dir/data-source_signal_geo-type_as-of.csv`. Warning: no intelligent fetching is done, so if you request
#' the same signal, geo type, and as of, but vary the other parameters (non-empty symmetric difference geo_value subsets or
#' non-empty symmetric difference start_day and end_day arguments), then the cache will return the result of the first call
#' for later calls. To avoid this and use caching, make sure to make a call that fetches all the data you anticipate to use
#' first and then request subsets. You can use populate_cache() below to fetch all the needed data.
#' @param ... other arguments to be passed to `covidcast::covidcast_signal()`.
#' @return `covidcast_signal` data frame.
#'
#' @importFrom stringr str_glue
#' @importFrom rlang inform warn .data
#' @importFrom magrittr %>%
#'
#' @export
download_signal <- function(data_source, signal, start_day = NULL, end_day = NULL, geo_type = "county", geo_values = "*", as_of = NULL, time_type = "day", offline_signal_dir = NULL, ...) {
  if (is.null(geo_type)) geo_type <- "county"
  if (is.null(geo_values)) geo_values <- "*"
  if (is.null(as_of)) as_of <- Sys.Date()
  if (is.null(end_day)) end_day <- max(as_of)
  if (!is.null(start_day)) assertthat::assert_that(as.Date(start_day) <= as.Date(end_day))
  if (!is.null(offline_signal_dir) && "issues" %in% names(list(...))) rlang::abort("issues argument is not supported with caching", "evalcast::download_signals")
  if (!is.null(offline_signal_dir) && "lag" %in% names(list(...))) rlang::abort("lag is not supported with caching", "evalcast::download_signals")

  if (is.null(offline_signal_dir)) {
    msg <- str_glue("Downloading {signal} from covidcast from ", signal = signal, .sep = " ")

    if (is.null(start_day)) msg <- str_glue("{msg} the earliest date possible to", msg = msg)
    else msg <- str_glue("{msg} {start_day} to", msg = msg, start_day = start_day)

    if (is.null(end_day)) msg <- str_glue("{msg} the latest date possible.", msg = msg)
    else msg <- str_glue("{msg} {end_day}", msg = msg, end_day = end_day)

    message(msg)
    df <- suppressMessages(covidcast_signal_wrapper(data_source = data_source, signal = signal, start_day = start_day, end_day = end_day, geo_type = geo_type, geo_values = geo_values, as_of = as_of, time_type = time_type, ...))
  } else {
    signal_fpath <- file.path(offline_signal_dir, sprintf("%s_%s_%s_%s_%s.RDS", data_source, signal, geo_type, time_type, as_of))
    inform("Using API data caching mechanism. Be warned that a stale cache could cause issues.", "evalcast::download_signals:cache_info_announce")

    if (file.exists(signal_fpath)) {
      inform(sprintf("Reading signal from disk: %s", signal_fpath), "evalcast::download_signals:cache_info_read")
      df <- readRDS(signal_fpath)
    } else {
      inform(sprintf("Downloading signal from API and storing in: %s", signal_fpath), "evalcast::download_signals:cache_info_write")
      df <- suppressMessages(covidcast_signal_wrapper(data_source = data_source, signal = signal, start_day = start_day, end_day = end_day, geo_type = geo_type, geo_values = "*", as_of = as_of, time_type = time_type, ...))
      fs::dir_create(dirname(signal_fpath), recurse = TRUE)
      saveRDS(df, signal_fpath)
    }

    if (!plyr::empty(df)) {
      if (max(df[["time_value"]]) < end_day) warn("Data in cache ends earlier than `end_day`.", "evalcast::download_signals:cache_warning_end_day")

      if (!is.null(start_day)) {
        if (min(df[["time_value"]]) > start_day) warn("Data in cache starts later than `start_day`.", "evalcast::download_signals:cache_warning_start_day")
        df <- df %>% filter(start_day <= .data$time_value)
      }
      if (!is.null(end_day)) df <- df %>% filter(.data$time_value <= end_day)
      if (!"*" %in% geo_values) df <- df %>% filter(.data$geo_value %in% geo_values)
    }
  }

  return(df)
}

#' A function to download and cache signals from the Covidcast API for future use. It is recommended that you use
#' this function to download more data than you expect than you will need, since the local data cache can be easily
#' filtered, but updating a local cache with more remote values requires complicated logic we have not implemented.
#' @param source_signals a tibble with the following columns: `data_source`, `signal`, `start_day`, `as_of`,
# ' `geo_type`. E.g. tibble(
# '    data_source = c('hhs', 'jhu-csse'),
# '    signal = c('confirmed_admissions_covid_1d', 'confirmed_incidence_num'),
# '    start_day = c('2020-08-01', '2020-08-01'),
# '    as_of = c('2022-01-01', '2022-01-01'),
# '    geo_type = c('state', 'state')
# ' )
#' @param offline_signal_dir the directory that stores the cached data for each
#' (signal, forecast day) pair.
#' @return no returns.
#'
#' @importFrom purrr pmap
#' @importFrom magrittr %>%
#'
#' @export
populate_cache <- function(source_signals, offline_signal_dir) {
  source_signals %>% pmap(download_signal, offline_signal_dir = offline_signal_dir)
}

#' The thinnest wrapper possible. For mock testing, see:
#' https://krlmlr.github.io/mockr/articles/mockr.html#write-wrapper-functions
#'
#' @param ... same arguments as covidcast_signal
#'
#' @importFrom covidcast covidcast_signal
covidcast_signal_wrapper <- function(...) {
  return(covidcast_signal(...))
}
