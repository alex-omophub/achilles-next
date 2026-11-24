# Install the AchillesNext viewer in ATLAS3

The AchillesNext R package includes a SystemJS parcel for the **OHDSI ATLAS3 v3.0.0** data-source sidebar. It opens a precomputed v2.0.0 or v2.1.0 publication in the installed React workspace. Users can browse domains, page through saved results and open a selected concept in ATLAS. The integration requires a same-origin result gateway that your deployment operates. [Pinned ATLAS3 release](https://github.com/OHDSI/Atlas3/releases/tag/v3.0.0)

## Install the assets

Copy the parcel and matching embed directory from **one installed version** of AchillesNext. The example prepares a new directory for deployment.

```r
plugin <- "achilles-next"
stopifnot(!file.exists(plugin), dir.create(plugin))
parcel <- system.file("atlas3", package = "AchillesNext", mustWork = TRUE)
embed <- system.file("embed", package = "AchillesNext", mustWork = TRUE)
stopifnot(all(file.copy(file.path(parcel, c("index.system.js", "style.css")), plugin)))
stopifnot(file.copy(embed, plugin, recursive = TRUE))
stopifnot(file.exists(file.path(plugin, "embed", "publication-workspace.mjs")))
```

Serve that directory under the host's `plugins/` directory. Keep the relative names, asset chunks and license notices. Serve `.js` and `.mjs` as JavaScript. Deploy each matching set together and revalidate the unversioned entries when upgrading.

Add this object to the existing `plugins` array in the host's `config/plugins.json`. Preserve the host's other registrations and settings. [Released manifest schema](https://github.com/OHDSI/Atlas3/blob/f775da50dfcd8b7fa5c57abc2e2654650d37ee4b/src/models/PluginModels.ts)

```json
{
  "id": "achilles-next",
  "name": "AchillesNext",
  "version": "0.0.0",
  "entryPoint": "achilles-next/index.system.js",
  "menuItems": [],
  "mountPoints": [{
    "id": "publication",
    "surface": "datasource-sidebar",
    "name": "AchillesNext",
    "group": "Reports"
  }]
}
```

Open **Data Sources**, select an authorized source and choose **AchillesNext** in its sidebar. To uninstall, remove this registration, reload ATLAS, then remove the plugin directory. The source data and published results are managed independently.

## Connect an authorized result gateway

The parcel resolves `achilles-results/v2/` relative to the host document's base URL. For a deployment at `/atlas3/`, the gateway directory for host source key `HOSPITAL_A` is `/atlas3/achilles-results/v2/HOSPITAL_A/`. Configure your reverse proxy accordingly. A source key occupies one URL segment, starts with a letter or digit, and may also contain periods, underscores, colons and hyphens. The gateway must explicitly map the host key to an approved analytical source, release, publication and disclosure scope. The released ATLAS message bus does not implement this result service.

| Relative request | Gateway responsibility |
|---|---|
| `GET admission` | Authenticate the current ATLAS bearer, authorize the source and return a JSON object with exactly one `context` field. |
| `GET api/people.json` and `api/catalogue.json` | Return the authorized population summary and bounded catalogue page. |
| `GET api/reports/{metric_id}.json` | Return the bounded saved row page. Preserve the optional `filters` and `cursor` query parameters. |
| `GET api/concepts/search.json` and `api/concepts/lookup.json` | Search saved labels by `q` and optional `cursor`, or look up an exact string `id`. |
| `GET api/evidence/{metric_id}.json` | Return authorized evidence for exactly the displayed filters and cursor. |

The admission context has ten nonempty string fields: `contract_version`, `source_id`, `release_id`, `publication_id`, `access_scope_id`, `profile_id`, `profile_revision`, `profile_sha256`, `authorization_epoch` and `instance_id`. Obtain them from the authorized result-serving session. Return the matching context in catalogue, population, report and concept responses. Serve evidence using the export envelope for the same approved page. Bind it to the authenticated principal on the server, rotate the epoch or instance when authorization changes, and reject revoked or unauthorized requests. Authenticate and authorize **every** read, including evidence exports. Use HTTP 401 for a missing/expired login and 403 for denied access. Serve only verified, disclosure-approved aggregate outputs. [Installed provider contract](../viewing/embedded-workspace.md)

The client requests the host's current token separately for admission and each API request. It sends a bearer header to the same-origin gateway with redirects rejected, cookies omitted and caching disabled. It bounds JSON reads to 1 MiB. TLS is required for a deployed host. The native loopback R viewer is suitable as a private, authorized upstream for a fixture gateway; exposing its local routes directly would omit the ATLAS identity and source mapping.

## Host lifecycle and presentation

The parcel retains mount capabilities per single-spa instance. It hides the prior display on a source or permission update and rechecks admission. A routine update preserves the selected report when the source, permissions, presentation and all ten context fields still match. Context changes retire the prior viewer. Teardown cancels outstanding work and disconnects the instance. The host receives exact string concept IDs through its `navigation:request` message. [Released parcel loader](https://github.com/OHDSI/Atlas3/blob/f775da50dfcd8b7fa5c57abc2e2654650d37ee4b/src/plugins/host/parcelLoader.ts)

If your identity service can change or revoke access **without an ATLAS parcel update**, have its trusted notification handler dispatch `window.dispatchEvent(new Event("achillesnext:access-changed"))`. Each mounted parcel immediately retires its display and obtains fresh admission. Enforce revocation on the gateway even when the browser is idle. A token getter alone cannot clear an idle page.

The viewer takes its numeric locale from the host. To set colors, define `--achillesnext-ink`, `--achillesnext-muted`, `--achillesnext-rule`, `--achillesnext-surface`, `--achillesnext-accent` or `--achillesnext-focus` in the host stylesheet. Each accepts an opaque three- or six-digit hex color. The parcel samples these values on mount and host updates. For example:

```css
.achillesnext-atlas3 { --achillesnext-accent: #397456; }
```

## Deployment coverage

| Component | Verified configuration |
|---|---|
| Host | Released ATLAS3 v3.0.0, commit `f775da50dfcd8b7fa5c57abc2e2654650d37ee4b`, data-source sidebar and hash routing under `/atlas3/` |
| Plugin | The installed AchillesNext SystemJS parcel, matching ES module and relative chart assets |
| Data | Generated synthetic v2.0.0 publications served with source database access disabled |
| Access and browser | Chrome 158, synthetic sign-in and a same-origin fixture gateway that checks the bearer on every operation |
| CSP | Same-origin scripts and connections, inline styles for the host and viewer, frames disabled |

The installed workspace also accepts v2.1.0 publications. The released-host trial used v2.0.0. Verify the target institution's identity provider, gateway authorization, browser policy and deployment base path before rollout.

## Earlier v1 research transport

The experimental byte transport is available from the development contract module:

```js
import {createFetchResultProvider} from './packages/contracts/src/index.mjs';

const provider = createFetchResultProvider({
  baseUrl: new URL('/achilles-results/v1/', location.origin).href,
  getHeaders: async () => ({Authorization: `Bearer ${await hostProps.getToken()}`}),
});
```

This helper defines an example gateway URL layout:

| Operation | GET path relative to the gateway base |
|---|---|
| Manifest | `sources/{source_id}/bundles/{bundle_id}/manifest.json` |
| Metric | `sources/{source_id}/bundles/{bundle_id}/results/{metric_id}.json` |
| Local terms | `sources/{source_id}/bundles/{bundle_id}/terminology.json` |

IDs are URL-encoded. Empty/dot-segment source and bundle IDs are rejected by this transport. Base URLs cannot carry credentials, query strings or fragments. The gateway must authenticate and authorize each operation independently and expose only declared artifacts. This layout is not a new WebAPI endpoint or a server implementation included with the package.

The provider returns exact bytes with cancellation, fresh host-supplied headers, `cache: no-store`, same-origin cookie policy and redirect rejection. Consumers must verify expected manifest/partition hashes, schema, source/bundle/run/request provenance and availability states before rendering. Classified access failures remain explicit; they never become zero/empty clinical data. Resource/asset limits and disclosure approval must also be enforced by the publishing/serving implementation.
