# Mount an approved publication in a host application

A host application can mount the AchillesNext publication workspace inside an
empty DOM element. The workspace uses the host’s approved aggregate-result
provider. The host owns the URL, login, authorization policy and source picker.

## Serve the module

Locate the distribution in the installed R package.

```r
system.file("embed", package = "AchillesNext", mustWork = TRUE)
```

Serve that directory, including its dependency notices and relative JavaScript
chunks, from the host’s static asset server. The example below serves it at
`/assets/achillesnext/`. Use a JavaScript MIME type for ES modules. The host
does not need to supply React to the module. Serve the host over HTTPS or
loopback and use a browser with Shadow DOM, Web Crypto and
`AbortSignal.any()` support.

## Mount and update

The example uses a same-origin results API that serves the saved publication
endpoints. A host with its own transport can pass a provider directly. The
host must already have the trusted context for the approved publication and
its current authorization epoch. A folder name or source ID alone is
insufficient to establish that context.

```js
import {
  createPublicationHttpProvider,
  mountPublicationWorkspace,
} from '/assets/achillesnext/publication-workspace.mjs';

const provider = createPublicationHttpProvider(
  new URL('/results/approved/api/', window.location.origin)
);
const target = { kind: 'workspace', version: '2' };
const instance = mountPublicationWorkspace(container, {
  provider, context: approvedContext, target
});

await instance.ready;
// After the same provider has been bound to the new authorized context:
await instance.update({ context: nextApprovedContext, target });
// During host teardown:
await instance.destroy();
```

For a bearer-authenticated gateway, import `readPublicationAdmission` from the same module and pass a current-token callback to both helpers. The base URL names the source gateway directory. Each read obtains a fresh token and honors the supplied abort signal.

```js
const authorization = {getToken: signal => host.getToken(signal)};
const context = await readPublicationAdmission(base, authorization, signal);
const provider = createPublicationHttpProvider(new URL('api/', base), authorization);
```

The admission endpoint returns `{"context": ...}`. The bearer transport restricts requests to the configured same-origin directory, omits cookies and rejects redirects. The [ATLAS3 installation guide](../integration/atlas3.md) includes the gateway routes and host lifecycle.

Use the ten string fields from the trusted admission when constructing the context.

| Identity | Fields |
| --- | --- |
| Publication and scope | `source_id`, `release_id`, `publication_id`, `access_scope_id` |
| Contract and profile | `contract_version`, `profile_id`, `profile_revision`, `profile_sha256` |
| Session | `authorization_epoch`, `instance_id` |

Scope every provider
read to the host's current permissions and honor its abort signal. When the
host replaces the provider itself, destroy the instance and mount a new one.

The initial handle is synchronous. Await `ready` or `update()` to find out
whether the requested generation rendered, was superseded, or was destroyed.
Handle rejected promises in the host's error UI. A mounted workspace can open
saved report tables and charts, filter them and download page evidence when
the corresponding optional provider methods are available.

This entry point targets approved v2 publications. The
[legacy bundle and embed contracts](../contracts/v1.md) describe the v1
byte-provider interface. The [source React component](local-viewer.md#embed-the-report-in-a-react-host)
is also available to applications that build the viewer sources themselves.

## Choose a viewer for the saved result

| Saved result | Installed R viewer | Installed JavaScript mount |
| --- | --- | --- |
| v1.0 tracer bundle | Open the bundle directory with `viewResults()`. | Use the standalone viewer for this format. |
| v1.1 complete measurement bundle | Open the approved restricted or distributable release directory with `viewResults()`. | Use the standalone viewer for this format. |
| v2.0 or v2.1 publication | Supply the approved publication and its authorization callback. | Mount a workspace, report or chart with the admitted publication context. React and Vue hosts use the same entry point. |

The JavaScript mount validates the context before reading. Passing a legacy
bundle identity returns `invalid_context`. The host can keep displaying its
current authorized publication after an invalid update.
[Installed R viewer examples](local-viewer.md)

## Handle expired sessions and denied access

The HTTP provider reports `authentication_required` for HTTP 401 and
`access_denied` for HTTP 403. A custom provider can throw the exported
`PublicationAccessError` with either code. Failed initial reads reject
`ready` or `update()`; failures during later interaction clear the current
data and show an alert. Other transport failures use `read_failed` in the mount.

After the host renews access, bind its provider to the approved result route
and call `update()` with the new complete context, including its authorization
epoch and provider instance ID. A logout or permission change must trigger
an update or destroy even when the source and publication IDs stay the same.
Keep credentials in the host transport.

## Open a report or chart directly

Use the same mount handle to open a specific metric from a host route. Supply
the metric ID and its definition version from the approved publication.

```js
await instance.update({
  context: approvedContext,
  target: {
    kind: 'chart', version: '2',
    metric_id: 'core.measurement.numeric_summary', metric_version: '1.0.0'
  }
});
```

Both `report` and `chart` targets open with a single bounded report-page read.
The host can also supply either target on the initial mount. A report exposes the
same table, filters, chart and evidence as its workspace selection. A chart
keeps the exact saved rows in an expandable table. Metrics without a chart
show a message and retain the table. Paging reads the next saved page on demand.
A mismatched publication, access scope or metric version rejects the mount’s
`ready` promise or the corresponding `update()` and clears the failed view.

## Handle concept selection and navigation

Pass an optional `onEvent(event)` callback when mounting to enable concept
actions in saved row tables. Selecting a positive concept ID emits
`concept_selected`. Choosing **Open concept in host** emits
`navigation_requested`. The host decides whether and where to navigate.
Zero, null, aggregate tags, and non-concept dimensions remain plain values.

Each v2 publication event carries `event_version: '1.0.0'`, a unique
`event_id`, `origin: 'user'`, the mount’s `instance_id`, its current
`generation`, and the pinned publication `context`. The two actions share
a `correlation_id`. The payload identifies the metric, definition version,
dimension and exact decimal-string `concept_id`, with `target: 'concept'`.
Keep the ID as a string when constructing a route. Bind the callback to the
mount’s host and verify the current context before acting asynchronously.

## Host lifecycle and styling

Keep the handle while the host component owns its DOM node. In React, create
the handle in a layout effect and call `destroy()` in cleanup. In Vue, use
`onMounted` and `onBeforeUnmount`. A second mount on an occupied container
fails. Each instance owns a shadow root, and its stylesheet applies inside
that root. Hosts with a nonce-based style policy can provide their current
`styleNonce` in the mount options.

An update supplies a complete context and target. The workspace clears
superseded content while it verifies the replacement context. If a host
tears down the instance during a read, the pending operation resolves with
status `destroyed`. Further update calls reject. Calling `destroy()` again is
safe. Host code keeps control of navigation and cleanup of its own provider.

## Set colors and numeric locale

Pass `theme` and `locale` on the initial mount or with a complete update.

```js
await instance.update({
  context: approvedContext,
  target,
  theme: { ink: '#182b36', surface: '#fff', accent: '#145b70', focus: '#974700' },
  locale: 'pt-PT'
});
```

The six optional color tokens are `ink`, `muted`, `rule`, `surface`,
`accent` and `focus`. Each accepts an opaque three- or six-digit hex color.
Overrides apply inside the current instance’s shadow root using its style nonce.
Omitting a token on update restores its built-in color, including the browser’s
dark-mode defaults.

The locale controls grouping and digits in the population summary and numeric
chart-axis labels. Interface text is English. Table cells, concept IDs, chart
tooltips and downloadable evidence retain the exact published strings.
Omitting `locale` restores English number formatting. Supply a language tag
supported by the browser’s `Intl.NumberFormat`. Invalid colors, unknown
tokens and unsupported locales return `invalid_configuration` before the
current view changes.

## Verify the installed artifact

Install the contributor dependencies, rebuild and install AchillesNext as
described in the [viewer build instructions](local-viewer.md#contributor-builds-and-checks).
The browser fixture runs separate React and Vue hosts that load the installed
ES module from a nested URL.

```sh
npm install --prefix .local/browser-test playwright@1.62.1 vue@3.5.39
.local/browser-test/node_modules/.bin/playwright install chromium
NODE_PATH="$PWD/.local/browser-test/node_modules" \
  ACHILLES_NEXT_EMBED_TEST=1 \
  ACHILLES_NEXT_VIEWER_TEST_LIBRARY="$PWD/.local/R-library" \
  python3 -m unittest discover -s tests -p test_installed_embed.py -v
```

To use an existing Chrome installation, set `ACHILLES_NEXT_TEST_CHROME` to the
executable path.
