#!/usr/bin/env Rscript
# Developer entry point. Configuration is trusted local R code, never bundled.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) stop("Usage: Rscript tools/count_tracer.R <local-config.R> <new-output-directory>", call. = FALSE)
suppressPackageStartupMessages(library(AchillesNext))
envir <- new.env(parent = globalenv())
sys.source(args[[1]], envir)
if (!exists("config", envir = envir, inherits = FALSE) || !is.list(envir$config)) stop("Config must define a config list", call. = FALSE)
do.call(generateCountTracer, c(envir$config, list(outputDir = args[[2]])))
cat("Generated partial development bundle. Run the contract validator before viewing.\n")
