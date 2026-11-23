import { type PublicationContext, type PublicationProvider } from './saved-publication.js';
export { createPublicationHttpProvider } from './saved-publication.js';
export type { PublicationContext, PublicationProvider } from './saved-publication.js';
export interface DirectPublicationTarget {
    readonly kind: 'report' | 'chart';
    readonly version: '2';
    readonly metric_id: string;
    readonly metric_version: string;
}
export interface PublicationMountConfiguration {
    readonly target: {
        readonly kind: 'workspace';
        readonly version: '2';
    } | DirectPublicationTarget;
    readonly context: PublicationContext;
}
export interface PublicationMountOptions extends PublicationMountConfiguration {
    readonly provider: PublicationProvider;
    readonly styleNonce?: string;
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
