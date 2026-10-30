#!/usr/bin/env Rscript
# Trusted local R configuration; no credentials or source records are exported.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) stop("Usage: Rscript tools/measurement_report.R <local-config.R> <new-output-directory>", call. = FALSE)
suppressPackageStartupMessages(library(AchillesNext))
envir <- new.env(parent = globalenv()); sys.source(args[[1]], envir)
if (!exists("config", envir = envir, inherits = FALSE) || !is.list(envir$config)) stop("Config must define a config list", call. = FALSE)
do.call(generateMeasurementReport, c(envir$config, list(outputDir = args[[2]])))
cat("Generated partial measurement reference bundle. Validate before viewing.\n")
