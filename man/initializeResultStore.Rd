\name{initializeResultStore}
\alias{initializeResultStore}
\title{Initialize an empty PostgreSQL aggregate store}
\usage{initializeResultStore(connectionDetails, resultsSchema, servingSchema, sourceSchemas)}
\arguments{
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details.}
\item{resultsSchema}{New restricted results schema.}
\item{servingSchema}{New approved-page serving schema.}
\item{sourceSchemas}{CDM and vocabulary schema names excluded from installation.}
}
\description{Creates new aggregate storage and serving schemas in one transaction.
Existing schemas are refused. The caller needs schema creation privileges.}
\value{Invisibly, installed storage version and schema names.}
\details{This installs storage only. It does not execute domain analyses, approve
outputs, grant viewer access or replace the existing tracer publication validator.}
