# ATLAS3 integration boundary

The verified target is **OHDSI ATLAS3 v3.0.0**, commit `f775da50dfcd8b7fa5c57abc2e2654650d37ee4b`. Its [published release](https://github.com/OHDSI/Atlas3/releases/tag/v3.0.0) is independent of the source package.json version, which remains 0.1.0. Use the release commit and lockfile when reproducing a host integration.

A native browser proof built the released application without application-source changes, loaded a SystemJS parcel in the data-source sidebar and read schema-valid handwritten fixtures through a separate signed-session gateway. It verified source A/B results, explicit access denial, cancellation, host concept navigation, unmount/remount and logout. This proves a bounded fixture path. A production adapter, React/Recharts analytical viewer and real WebAPI/identity-service deployment are not shipped or certified by it.

## Host surface and module format

The released [manifest schema](https://github.com/OHDSI/Atlas3/blob/f775da50dfcd8b7fa5c57abc2e2654650d37ee4b/src/models/PluginModels.ts) supports a `datasource-sidebar` mount point. A registration has an entry point such as `achilles-next/index.system.js`, an empty `menuItems` array and a named sidebar mount. The [released data-source view](https://github.com/OHDSI/Atlas3/blob/f775da50dfcd8b7fa5c57abc2e2654650d37ee4b/src/views/DataSourcesView.vue) supplies the selected host source key.

The [parcel loader](https://github.com/OHDSI/Atlas3/blob/f775da50dfcd8b7fa5c57abc2e2654650d37ee4b/src/plugins/host/parcelLoader.ts) expects SystemJS-compatible exports `bootstrap`, `mount`, `unmount` and optional `update`. Native ESM alone is insufficient for this loader. It supplies a DOM container, live auth context, `getToken`, message bus, locale and host context. Use those capabilities through an adapter around the future framework-neutral viewer; keep React/Recharts implementation details internal.

**Version-specific update constraint:** [PluginParcelOutlet](https://github.com/OHDSI/Atlas3/blob/f775da50dfcd8b7fa5c57abc2e2654650d37ee4b/src/plugins/components/PluginParcelOutlet.vue) calls `handle.update({ hostContext })`. In the locked single-spa 6.0.3 runtime this replaces the original custom props, so subsequent update/unmount props omit the original container and token/message capabilities. Retain mount capabilities per unique runtime parcel identity and replace the full analytical access context when updating. Do not use a single global instance or export a constant parcel name that makes separate instances indistinguishable. The fixture adapter used single-spa's unique parcel name; no host patch was required.

Mount completion and data readiness are separate. Keep asynchronous provider reads cancellable, clear prior source content on a valid context change, discard obsolete generations and release instance-owned content/listeners on unmount. The host owns its loaded module/style cache: this release keeps injected plugin CSS in the document head across remounts. Scope plugin styles to the supplied container; broader portal/style/resource isolation remains a production-viewer acceptance check.

## Source, authorization and result transport

Map host source keys to analytical source/bundle identities explicitly. The fixture proof used different host keys and source IDs; identifier equality was not assumed. Resolve the expected manifest digest and full [access context](../contracts/v1.md) through an authorized host/service binding. Opaque scope/epoch IDs do not authorize a request.

The released [message bus](https://github.com/OHDSI/Atlas3/blob/f775da50dfcd8b7fa5c57abc2e2654650d37ee4b/src/plugins/messaging/HostMessageBus.ts) still returns a placeholder for `data:request`; it does not serve AchillesNext bundles. Configure an institutional result gateway or another approved provider. The browser proof used a real loopback HTTP gateway with signed sessions and source ACLs, plus a narrow WebAPI-shaped fixture subset for host login/source/vocabulary screens. It did not deploy WebAPI or connect an institutional database.

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

Rotate access context on login, logout and permission/identity changes. The fixture proof checked logout and replay denial. Token-only refresh or same-permission identity changes without a host context update were not verified; production integration needs an explicit invalidation path from its host/identity service. A current-token getter by itself does not notify an already-rendered view that its scope changed.

## Navigation and deployment limits

Map concept events through the host's `navigation:request` message and released `/concept/{sourceKey}/{conceptId}` route. The host owns routing/history. Keep tokens out of URLs, bundles, cache identities and analytical events.

The proof served a production build at `/atlas3/` with hash routing, same-origin plugin assets and a loopback fixture gateway. It ran in Chrome 156 with `script-src 'self'`, same-origin connections, inline styles allowed for the host UI and frames disabled; no CSP violation or uncaught page exception was observed. This was an imposed fixture-server policy, not an upstream Caddy default or certification of every institutional CSP. The source release's Caddy example uses `/atlas/`; base-path changes must be tested explicitly.

Production acceptance still requires a generated native bundle, prebuilt React viewer, packaged adapter installation, real authentication/result-service policy, browser and deployment coverage, source/identity invalidation, disclosure/asset controls and UI/resource/accessibility checks. No iframe replacement or unreviewed host fork is implied by the fixture result.
