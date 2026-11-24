declare const contextKeys: readonly ["contract_version", "source_id", "release_id", "publication_id", "access_scope_id", "profile_id", "profile_sha256", "profile_revision", "authorization_epoch", "instance_id"];
export type PublicationContext = Readonly<Record<typeof contextKeys[number], string>>;
type Context = PublicationContext;
export interface CatalogueMetric {
    metric_id: string;
    version: string;
    state: string;
    rows: string;
}
export interface CataloguePage {
    context: Context;
    metrics: CatalogueMetric[];
    cursor: string | null;
}
export interface PopulationResult {
    context: Context;
    state: string;
    reason: string | null;
    count: string | null;
}
export declare class PublicationReadError extends Error {
}
export declare class PublicationAccessError extends PublicationReadError {
    readonly code: 'authentication_required' | 'access_denied';
    constructor(code: 'authentication_required' | 'access_denied');
}
export declare function validPublicationContext(value: unknown): value is PublicationContext;
export declare function assertSamePublication(a: Context, b: Context): void;
export declare function readCatalogue(base: URL, cursor: string | null, signal: AbortSignal, fetchImpl?: typeof fetch): Promise<CataloguePage>;
export declare function readPeople(base: URL, signal: AbortSignal, fetchImpl?: typeof fetch): Promise<PopulationResult>;
export type ReportValue = string | boolean | null | readonly ReportValue[] | ReportFields;
export interface ReportFields {
    readonly [key: string]: ReportValue;
}
export interface DenominatorReference {
    measure: string;
    metric_id: string;
    row_key: string;
    field: string;
    value: string;
}
export interface ReportRow {
    row_key: string;
    row_kind: string;
    state: string;
    reason_code: string | null;
    dimensions: ReportFields;
    values: ReportFields | null;
    denominator_refs?: DenominatorReference[];
}
interface ReportDependency {
    metric_id: string;
    metric_version: string;
    row: ReportRow;
}
export type ConceptTag = {
    kind: 'id';
    value: string;
} | {
    kind: 'all' | 'null' | 'schema_absent';
};
export type SavedFilters = Readonly<Record<string, string | ConceptTag>>;
export interface ReportCapability {
    concept: string;
    time: string;
    unit: string;
    operator: string;
    period_kinds: string[];
    period_bounds: {
        full_scope: string;
        calendar: string;
    };
}
export interface ReportPage {
    context: Context;
    metric_id: string;
    version: string;
    grain: string;
    population: string;
    state: string;
    reason: string | null;
    datasetState: string;
    datasetReason: string | null;
    rowKind: string;
    rows: ReportRow[];
    capability?: ReportCapability;
    evidence?: {
        definitionSha256: string;
        dependencies: ReportDependency[];
    };
    cursor: string | null;
}
export declare function readReport(base: URL, metricId: string, cursor: string | null, signal: AbortSignal, fetchImpl?: typeof fetch): Promise<ReportPage>;
export declare function selectReport(base: URL, metricId: string, filters: SavedFilters, cursor: string | null, signal: AbortSignal, fetchImpl?: typeof fetch): Promise<ReportPage>;
export declare function validMetricId(value: unknown): value is string;
export interface SavedConcept {
    id: string;
    label: string | null;
    labelState: string;
    state: string;
    reason: string | null;
}
export interface ConceptPage {
    context: Context;
    state: string;
    reason: string | null;
    cursor: string | null;
    concepts: SavedConcept[];
}
export declare function searchConcepts(base: URL, query: string, cursor: string | null, signal: AbortSignal, fetchImpl?: typeof fetch): Promise<ConceptPage>;
export declare function lookupConcept(base: URL, id: string, signal: AbortSignal, fetchImpl?: typeof fetch): Promise<ConceptPage>;
export declare function readPageEvidence(base: URL, metricId: string, filters: SavedFilters, cursor: string | null, signal: AbortSignal, fetchImpl?: typeof fetch): Promise<unknown>;
export declare function pageEvidenceJson(envelope: unknown, displayed: ReportPage, filters: SavedFilters, number: number): Promise<string>;
export interface PublicationProvider {
    people(signal: AbortSignal): Promise<PopulationResult>;
    catalogue(cursor: string | null, signal: AbortSignal): Promise<CataloguePage>;
    report(metricId: string, cursor: string | null, signal: AbortSignal): Promise<ReportPage>;
    select?(metricId: string, filters: SavedFilters, cursor: string | null, signal: AbortSignal): Promise<ReportPage>;
    search?(query: string, cursor: string | null, signal: AbortSignal): Promise<ConceptPage>;
    exportEvidence?(metricId: string, filters: SavedFilters, cursor: string | null, signal: AbortSignal): Promise<unknown>;
    lookup?(id: string, signal: AbortSignal): Promise<ConceptPage>;
}
export interface PublicationHttpAuthorization {
    readonly getToken: (signal: AbortSignal) => string | null | undefined | Promise<string | null | undefined>;
}
export declare function readPublicationAdmission(base: URL, options: PublicationHttpAuthorization, signal: AbortSignal): Promise<PublicationContext>;
export declare function createPublicationHttpProvider(base: URL, options?: PublicationHttpAuthorization): PublicationProvider;
export {};
