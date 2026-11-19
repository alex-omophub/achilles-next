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

With the default `transferStrategy = "spool"`, the function checks the store without writing, executes the source program and
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

## PostgreSQL binary COPY

Set `transferStrategy = "postgresql_copy"` to transfer registered count reports
to a temporary table on the result-store session. This requires TEMPORARY
privilege on the store database in addition to the usual producer privileges.
The source still requires read access and TEMPORARY. Other reports use the
existing local capture. Source and store may run on separate PostgreSQL hosts.

The transaction writes to permanent result tables after the source has rolled
back and disconnected. Ordered checksums cover both canonical rows and complete
transferred tuples, including metric IDs, row keys and original byte charges.
Import reconciles saved dataset, cell, denominator edge and release revision
totals before commit. A failed attempt leaves the previous publication usable.

COPY uses at most `min(fetchSize, 128)` rows per page and a 512 KiB binary
buffer. Stage and scratch limits include the measured temporary table, indexes
and sequence, checked after each page. Either limit may be exceeded briefly
during an allocation. PostgreSQL sorts may process a complete metric before
the first page and their work files are outside these relation measurements.
The driver checks for cancellation between pages and applies the remaining
statement and individual socket-read timeouts during a blocking COPY call.
Actual engine runtime depends on its query plan and available resources.

The source receipt reports transferred rows, bytes, pages and ordered digests.
The result reports separate write totals for each transport, store verification
time and temporary space. Store persistence wall time covers post-source work.
The entire store transaction overlaps source generation.

The maintained fixture uses restricted source and producer principals. It
checks numerical results and denominator links, interrupts a real transfer,
and alters a staged key before verification. Run it from a package checkout
with the marked PostgreSQL fixture configured and the current package installed.

```sh
python3 tools/test_characterization_candidate_sql.py --copy-only \
  --state .local/postgresql --config tools/tracer_fixture_config.R \
  --output-dir .local/compiled-candidate-copy
```

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
