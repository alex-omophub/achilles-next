// Compile the installed ESM's public types as a host with no React imports.
import {createPublicationHttpProvider, mountPublicationWorkspace} from '../../../inst/embed/publication-workspace.mjs';

declare const container: HTMLElement;
declare const context: Parameters<typeof mountPublicationWorkspace>[1]['context'];
const provider = createPublicationHttpProvider(new URL('/results/api/', window.location.origin));
const target = {kind: 'workspace', version: '2'} as const;
const workspace = mountPublicationWorkspace(container, {provider, context, target, styleNonce: 'example'});
await workspace.ready;
await workspace.update({context, target});
workspace.destroy();
