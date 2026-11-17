# Checked source execution to a complete building candidate

`generateCharacterizationCandidateFromSql()` is an optional PostgreSQL path with
separate source and aggregate-store credentials. The source worker needs
SELECT-only CDM access plus TEMPORARY. The store producer needs the initialized
aggregate store and no CDM access. The two endpoints may be different databases.
The existing generator and refresh functions keep their existing orchestration.

```r
program <- renderCharacterizationSql(
  cdmSchema, sourceId, declaredCdmVersion, declaredColumns
)
candidate <- generateCharacterizationCandidateFromSql(
  sourceConnectionDetails, program, storeConnectionDetails, resultsSchema,
  maxScratchBytes = 1024^3
)
```

The function checks the store without writing, executes the source program and
captures its restricted output privately. Only after the source executor returns
its successful cleanup receipt does a separate store transaction begin importing
rows. Canonical identities and denominator references come from the installed
analysis definitions. A disk index resolves targets, and metrics replay in
registered dependency order with a bounded writer flush at each boundary.
Independent source audit totals support the existing exact conservation checks.

The result is a complete **building** candidate. Sealing, validation, institutional
approval and publication remain separate explicit operations. No current
publication or approved output is read, replaced or deleted by this function.
Source metadata preserves actual source-capture identities and timings; import
telemetry describes the later store transaction. Source release identities remain
unknown and cannot authorize reuse.

One logical scratch budget covers canonical row frames, the duplicate/target
index, old plus replacement indexes and completion controls. Per-record and
fixed-metadata caps also apply. Files are attempt-owned and removed before the
candidate COMMIT. This does not reserve physical disk blocks or bound SQL-engine
memory, R/JVM RSS or filesystem buffers. No public retained-capture or resume
format is introduced, and no per-row remote denominator query is used.

Failures return sanitized reason codes and, once allocated, attempt/run/source/
release IDs. A lost COMMIT acknowledgement reports `candidate.commit_unknown` with
`outcome="unknown"`; a complete unpublished candidate may already exist. Inspect
that attempt in the restricted store before manual recovery. Cleanup uncertainty
is not a rollback guarantee, and no automatic retry or publication occurs.
The source-only executor's timeout, cancellation and concurrent-DDL limitations
continue to apply. This path does not establish large-source performance results
or support for a second SQL engine.
