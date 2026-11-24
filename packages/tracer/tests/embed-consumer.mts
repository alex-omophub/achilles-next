// Compile the installed ESM's public types as a host with no React imports.
import {PublicationAccessError, createPublicationHttpProvider, mountPublicationWorkspace, readPublicationAdmission, type PublicationHttpAuthorization} from '../../../inst/embed/publication-workspace.mjs';

declare const container: HTMLElement;
declare const context: Parameters<typeof mountPublicationWorkspace>[1]['context'];
declare const getToken: PublicationHttpAuthorization['getToken'];
const gateway = new URL('/results/', window.location.origin);
const provider = createPublicationHttpProvider(new URL('api/', gateway), {getToken});
await readPublicationAdmission(gateway, {getToken}, new AbortController().signal);
const target = {kind: 'workspace', version: '2'} as const;
const workspace = mountPublicationWorkspace(container, {provider, context, target, styleNonce: 'example', onEvent(event) {
  const id: string = event.payload.concept_id;
  if (event.type === 'navigation_requested') new URL('/concept/' + id, window.location.origin);
}});
try { await workspace.ready; }
catch (error) {
  if (!(error instanceof PublicationAccessError && error.code === 'authentication_required')) throw error;
}
await workspace.update({context, target, theme: {accent: '#156075'}, locale: 'pt-PT'});
await workspace.update({context, target: {kind: 'report', version: '2', metric_id: 'core.person.count', metric_version: '1.0.0'}});
await workspace.update({context, target: {kind: 'chart', version: '2', metric_id: 'core.measurement.numeric_summary', metric_version: '1.0.0'}});
workspace.destroy();
