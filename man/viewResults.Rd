\name{viewResults}
\alias{viewResults}
\title{Open Generated Results with the Installed Local Viewer}
\usage{
viewResults(bundleDir, browse = TRUE, port = 0L,
            basePath = "/achilles-next/", block = !interactive())
}
\arguments{
\item{bundleDir}{Selected result bundle folder. Missing, invalid and incompatible results are shown as explicit viewer states.}
\item{browse}{Open the URL using the configured browser.}
\item{port}{Zero chooses a random available loopback port; otherwise an integer from 1024 to 65535.}
\item{basePath}{Root or a slash-delimited prefix with a trailing slash.}
\item{block}{Service HTTP requests until interrupted. Defaults to true outside interactive R.}
}
\description{Uses prebuilt installed React assets and an R httpuv server bound only to 127.0.0.1. No Node, npm, Shiny, frontend build or external account is needed for viewing after installation.}
\value{Invisibly, a list containing \code{url}, \code{status}, and an idempotent \code{stop()} function. For nonblocking use the R session must remain alive and service its event loop.}
\details{The server keeps an in-memory snapshot of only declared result files and packaged assets. File paths, size, identity and hashes are checked before serving; symbolic-link escapes, unrelated files, foreign Host/Origin values and write methods are refused. The browser performs frozen-schema and count-tracer semantic checks. Only partial synthetic count/observation-tracer bundles are currently supported. This is not an institutional authentication or production publication service.}
