# Trusted local configuration for the marked fixtures created by
# tools/postgresql_fixtures.py. No passwords are embedded or printed.
fixtureState <- normalizePath(Sys.getenv("ACHILLES_NEXT_FIXTURE_STATE", unset = ".local/postgresql"), mustWork = TRUE)
fixtureConnection <- function(role = "runner") {
  if (!role %in% c("runner", "owner")) stop("Unknown fixture role")
  fields <- strsplit(readLines(file.path(fixtureState, "pgpass"), warn = FALSE), ":", fixed = TRUE)
  selected <- Filter(function(x) length(x) == 5L && x[3] == "achilles_next_fixtures" && x[4] == paste0("achilles_next_", if (role == "owner") "fixture_owner" else "runner"), fields)
  if (length(selected) != 1L) stop("Missing fixture role entry")
  entry <- selected[[1]]
  DatabaseConnector::createConnectionDetails(dbms = "postgresql", server = "127.0.0.1/achilles_next_fixtures",
    port = as.integer(entry[2]), user = entry[4], password = entry[5])
}
config <- list(connectionDetails = fixtureConnection(), cdmSchema = "cdm_tiny_a_55",
  sourceId = "fixture:tiny_a", declaredCdmVersion = "5.5",
  request = list(profile_id = "alpha-measurement-v1", source_id = "fixture:tiny_a",
    window = list(start = "2020-01-01", end = "2020-12-31"), measurement_concept_ids = list(900000001L),
    output_scope = "restricted", disclosure_policy_id = "synthetic-unsuppressed-v1"))
