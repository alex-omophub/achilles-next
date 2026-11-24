import { type PublicationContext, type PublicationProvider } from './saved-publication.js';
export { createPublicationHttpProvider, PublicationAccessError } from './saved-publication.js';
export type { PublicationContext, PublicationProvider } from './saved-publication.js';
export interface DirectPublicationTarget {
    readonly kind: 'report' | 'chart';
    readonly version: '2';
    readonly metric_id: string;
    readonly metric_version: string;
}
declare const colorTokens: readonly ["ink", "muted", "rule", "surface", "accent", "focus"];
export type PublicationTheme = Readonly<Partial<Record<typeof colorTokens[number], string>>>;
export interface PublicationMountConfiguration {
    readonly theme?: PublicationTheme;
    readonly locale?: string;
    readonly target: {
        readonly kind: 'workspace';
        readonly version: '2';
    } | DirectPublicationTarget;
    readonly context: PublicationContext;
}
export interface PublicationConceptEvent {
    readonly event_version: '1.0.0';
    readonly type: 'concept_selected' | 'navigation_requested';
    readonly event_id: string;
    readonly correlation_id: string;
    readonly origin: 'user';
    readonly instance_id: string;
    readonly generation: number;
    readonly context: PublicationContext;
    readonly payload: {
        readonly target: 'concept';
        readonly concept_id: string;
        readonly dimension: string;
        readonly metric_id: string;
        readonly metric_version: string;
    };
}
export interface PublicationMountOptions extends PublicationMountConfiguration {
    readonly provider: PublicationProvider;
    readonly styleNonce?: string;
    readonly onEvent?: (event: PublicationConceptEvent) => void;
}
export interface PublicationMountOutcome {
    readonly status: 'applied' | 'superseded' | 'destroyed';
    readonly generation: number;
}
export interface PublicationMountHandle {
    readonly id: string;
    readonly ready: Promise<PublicationMountOutcome>;
    update(options: PublicationMountConfiguration): Promise<PublicationMountOutcome>;
    destroy(): Promise<void>;
}
export declare function mountPublicationWorkspace(container: HTMLElement, options: PublicationMountOptions): PublicationMountHandle;
