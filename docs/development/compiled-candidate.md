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

Set `maxAggregateRows` to the total allowed across the run, including
metadata. It defaults to 1,000,000 and accepts up to 2,147,483,647. Larger
totals use the same JDBC fetch size. Capture writes length-prefixed rows in
batches of up to 128 frames and 1 MiB. Every emitted row, including an
explicit zero-count cell, counts toward the row budget. Aggregate payload
bytes and scratch storage have separate budgets.

Failures return sanitized reason codes and, once allocated, attempt/run/source/
release IDs. A lost COMMIT acknowledgement reports `candidate.commit_unknown` with
`outcome="unknown"`; a complete unpublished candidate may already exist. Inspect
that attempt in the restricted store before manual recovery. Cleanup uncertainty
is not a rollback guarantee. Generation and import are not automatically retried;
cleanup may retry unconfirmed rollback and disconnect operations. Publication
remains a separate explicit step.
The source-only executor's timeout, cancellation and concurrent-DDL limitations
continue to apply. This path does not establish large-source performance results
or support for a second SQL engine.

## Publish and open saved results

Use the existing result-store lifecycle with the returned release ID. These
steps read saved aggregates; they do not reconnect to the CDM. Store-operator
credentials and institutional approval are separate from source credentials.

```r
sealResultRelease(storeOperatorDetails, resultsSchema, candidate$release_id)
validateResultRelease(storeOperatorDetails, resultsSchema, candidate$release_id)

# policy and institutionalPolicy come from institution-controlled approval rules.
# NULL prepares approved bytes without changing the database current pointer.
approved <- publishResultRelease(
  storeOperatorDetails, resultsSchema, candidate$release_id,
  newExportDirectory, audienceId, approvalId, policy, institutionalPolicy,
  expectedRevision = NULL
)
```

A full allowlist retains all registered outputs. A projection physically omits
other rows and omits outputs whose required denominators were not retained; its
catalogue records those omissions explicitly. Neither choice grants approval
automatically. See [the publication lifecycle](result-store.md#validate--project--export--select)
for policy, validation and compare-and-swap selection.

The host can open the approved directory with `openArtifactResultProvider()` or
the same approved bytes through `openDatabaseResultProvider()` using separate
serving credentials. Both require a trusted publication context and authorization
callback. Saved reads never trigger generation and remain pinned to their chosen
publication, even if a later candidate is cancelled or a new current publication
is selected. See [semantic saved results](semantic-results.md) for bounded metric
and concept discovery, row selection and denominator access.

The capture scratch budget does not cover export-page staging or the optional
terminology snapshot copy. This lifecycle example is not a full-source performance
or end-to-end temporary-storage qualification.
