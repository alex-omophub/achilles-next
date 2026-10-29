#!/usr/bin/env Rscript
# Trusted local configuration, as for tools/count_tracer.R; never publish it.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) stop("Usage: Rscript tools/observation_tracer.R <local-config.R> <new-output-directory>", call. = FALSE)
suppressPackageStartupMessages(library(AchillesNext))
envir <- new.env(parent = globalenv()); sys.source(args[[1]], envir)
if (!exists("config", envir = envir, inherits = FALSE) || !is.list(envir$config)) stop("Config must define a config list", call. = FALSE)
do.call(generateObservationTracer, c(envir$config, list(outputDir = args[[2]])))
cat("Generated partial observation bundle. Validate it, then open with AchillesNext::viewResults().\n")
