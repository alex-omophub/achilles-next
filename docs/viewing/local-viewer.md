# Open generated results locally

The installed R package contains a prebuilt React viewer for partial synthetic
count, observation and measurement bundles. Opening a bundle requires R, the installed package and a
modern browser. It does not invoke Node, npm or Shiny, contact an external account,
or build frontend assets. Installing R dependencies may require network access;
this is not yet a verified offline distribution.

## Generation → View

Generate a bundle using the [count-tracer guide](../development/count-tracer.md),
then open it in R:

```r
AchillesNext::viewResults(".local/count-bundle")
```

The helper selects a loopback port and opens the selected results automatically.
The URL includes `/achilles-next/`; selecting the folder again is unnecessary.
Count-only bundles implement `person.count` and the passport, leaving 13 outputs
unsupported. The [observation tracer](../development/observation-tracer.md) adds
three observation metrics with a Recharts monthly view and exact table, leaving
ten outputs unsupported. The [measurement reference report](../development/measurement-reference.md)
adds seven measurement outputs and local terminology, leaving three unsupported.
The [explicit weighted option](../development/weighted-quantiles.md) opens through the same viewer and preserves the reference metric semantics.
Publication stays partial, and no
disclosure policy or institutional authorization is inferred.

For interactive R, keep the session alive and its event loop available:

```r
viewer <- AchillesNext::viewResults(".local/count-bundle", browse = FALSE)
viewer$url                     # Open this URL in a browser
viewer$status                  # Initial server snapshot state
viewer$stop()                  # Safe to call more than once
```

In noninteractive R, `block` defaults to `TRUE` and services requests until
interrupted. Use Ctrl+C to stop. A process started with `block = FALSE` must stay
alive and service the httpuv event loop; exiting R stops the viewer. The browser
performs additional validation before displaying analytical values, so server status
`ready` alone does not establish that a bundle is valid.

To run from a shell without a source checkout or frontend tools:

```sh
Rscript -e 'AchillesNext::viewResults("path/to/bundle")'
```

The installed `exec/view-results.R` script also accepts a bundle folder and an
optional `--no-browser` flag. A custom `basePath = "/tools/results/"` and an
unprivileged port can be supplied to the R helper. Root `/` also works. Custom
prefixes must start and end with `/` and use simple path segments.

## Data access and failure states

The R server binds only to `127.0.0.1`. It snapshots the manifest and declared
aggregate/terminology files into memory after path, size, identity and hash
checks. Unrelated files, symbolic links, path traversal, foreign Host/Origin
headers and write methods are refused. The browser uses the frozen schemas and
the same partial-tracer semantic verifier as local folder selection. No analytical value is
shown until those checks pass. Limits are 10 MiB per file and 64 MiB per bundle.

The viewer distinguishes missing files, invalid results, incompatible versions
and an unavailable local server, with recovery instructions. Failure never
becomes a zero count. Fix or regenerate the selected files and reopen the R
helper to load a new snapshot; changing files on disk does not alter a running
viewer's results.

This is a single-user local viewer. It has no institutional authentication,
authorization or publication service. Other local processes can access its
loopback endpoint. The standalone page disallows framing; future host embedding
uses the [separate component/provider contract](../contracts/v1.md).

## Contributor builds and checks

Frontend changes require a contributor build before R installation:

```sh
npm ci --prefix packages/tracer --ignore-scripts --no-audit --no-fund
npm run package-viewer --prefix packages/tracer
python3 tools/check_viewer_assets.py
R CMD INSTALL --library=.local/R-library .
```

Create the library directory first. Commit the generated `inst/viewer` assets,
their dependency notices and `viewer-lock.json` with the corresponding sources.
The lock records asset and source SHA-256 values without timestamps or local
paths. The Node-free checker detects changed or missing bytes. CI rebuilds once
using the npm lockfile and requires the packaged assets to match before R
installation. Ajv schemas compile during this build; the installed browser code
requires neither runtime schema compilation nor `unsafe-eval`.

After creating the [real synthetic integration bundles](../development/count-tracer.md#verification),
run the installed-viewer tests:

```sh
ACHILLES_NEXT_VIEWER_TEST_LIBRARY="$PWD/.local/R-library" \
TRACER_TEST_BUNDLES="$PWD/.local/tracer-integration" \
python3 -m unittest discover -s tests -p test_local_viewer.py -v
```

These tests start temporary R-only servers on a nested URL prefix with Node/npm
unavailable. They exercise served assets, exact counts, immutable snapshots,
missing/tampered/incompatible bundles, symlink and route boundaries, allowed
methods, Host/Origin checks and shutdown. Tests need permission to bind loopback
sockets. Without both environment variables they explicitly skip.

## Approved complete bundles

The same installed viewer opens contract 1.1 restricted or distributable complete
measurement releases. Generate and approve them using the
[publication API](../development/publication.md), then pass the returned release
directory to `viewResults()`. Publication/current resolution uses Node.js; opening
the release in the installed viewer does not. Suppressed partitions show their
explicit state and have no values to fetch or infer. The view pins one manifest
and does not follow pointer updates during a session.
