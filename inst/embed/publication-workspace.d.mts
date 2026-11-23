import { type PublicationContext, type PublicationProvider } from './saved-publication.js';
export { createPublicationHttpProvider } from './saved-publication.js';
export type { PublicationContext, PublicationProvider } from './saved-publication.js';
export interface PublicationMountConfiguration {
    readonly target: {
        readonly kind: 'workspace';
        readonly version: '2';
    };
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
