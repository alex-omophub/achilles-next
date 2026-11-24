// Compile the installed ESM's public types as a host with no React imports.
import {createPublicationHttpProvider, mountPublicationWorkspace} from '../../../inst/embed/publication-workspace.mjs';

declare const container: HTMLElement;
declare const context: Parameters<typeof mountPublicationWorkspace>[1]['context'];
const provider = createPublicationHttpProvider(new URL('/results/api/', window.location.origin));
const target = {kind: 'workspace', version: '2'} as const;
const workspace = mountPublicationWorkspace(container, {provider, context, target, styleNonce: 'example', onEvent(event) {
  const id: string = event.payload.concept_id;
  if (event.type === 'navigation_requested') new URL('/concept/' + id, window.location.origin);
}});
await workspace.ready;
await workspace.update({context, target, theme: {accent: '#156075'}, locale: 'pt-PT'});
await workspace.update({context, target: {kind: 'report', version: '2', metric_id: 'core.person.count', metric_version: '1.0.0'}});
await workspace.update({context, target: {kind: 'chart', version: '2', metric_id: 'core.measurement.numeric_summary', metric_version: '1.0.0'}});
workspace.destroy();
