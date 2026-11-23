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
