#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = TRUE)
noBrowser <- "--no-browser" %in% args
args <- args[args != "--no-browser"]
if (length(args) != 1L) stop("Usage: Rscript view-results.R <bundle-folder> [--no-browser]", call. = FALSE)
AchillesNext::viewResults(args[[1]], browse = !noBrowser, block = TRUE)
