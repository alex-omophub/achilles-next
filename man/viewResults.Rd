\name{viewResults}
\alias{viewResults}
\title{Open Generated Results with the Installed Local Viewer}
\usage{
viewResults(bundleDir, browse = TRUE, port = 0L,
            basePath = "/achilles-next/", block = !interactive(), authorize = NULL)
}
\arguments{
\item{bundleDir}{A tracer bundle directory, an approved v2 core export directory, or the trusted result returned by \code{publishResultRelease()}.}
\item{authorize}{For a v2 directory, a trusted function of the pinned publication context returning exactly TRUE when the local user may read that admitted root and scope. With a trusted publication result, an optional additional access check.}
\item{browse}{Open the URL using the configured browser.}
\item{port}{Zero chooses a random available loopback port; otherwise an integer from 1024 to 65535.}
\item{basePath}{Root or a slash-delimited prefix with a trailing slash.}
\item{block}{Service HTTP requests until interrupted. Defaults to true outside interactive R.}
}
\description{Uses prebuilt installed React assets and an R httpuv server bound only to 127.0.0.1. No Node, npm, Shiny, frontend build or external account is needed for viewing after installation.}
\value{Invisibly, a list containing \code{url}, \code{status}, and an idempotent \code{stop()} function. For nonblocking use the R session must remain alive and service its event loop.}
\details{Pass the value returned by \code{publishResultRelease()} to open its approved core publication. The viewer uses the native artifact provider to browse reports by domain, page through saved rows and read the exact population count. Each report shows its population, grain and default row kind. Supported birth-year, domain capture and measurement reports visualize the current saved page alongside its exact table. When passing an export directory, authorize the publication against an independent approval record. The server binds to the local loopback interface. V1 count, observation and measurement bundles use the existing manifest snapshot and tracer validation path.}
