# Test-only guard: inspect credential values, including escaped JSON substrings.
assertNoCredentials <- function(text, credentials) {
  for (value in credentials) {
    if (!is.character(value) || length(value) != 1L || is.na(value) || !nzchar(value))
      stop("Known fixture credentials are required for this check", call. = FALSE)
    encoded <- as.character(jsonlite::toJSON(value, auto_unbox = TRUE))
    patterns <- unique(c(value, substr(encoded, 2L, nchar(encoded) - 1L)))
    if (any(vapply(patterns, function(pattern) any(grepl(pattern, text, fixed = TRUE)), TRUE)))
      stop("Credential value found in serialized artifacts", call. = FALSE)
  }
  invisible(TRUE)
}
