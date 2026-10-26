export type Format = 'json' | 'cbor';
export type Input = string | Uint8Array;
export interface Diagnostic {
  readonly code: string;
  readonly message: string;
  readonly record_index?: number;
  readonly field?: string;
  readonly line?: number;
  readonly column?: number;
}
export class SenWeaveError extends Error {
  readonly code: string;
  readonly diagnostic: Diagnostic;
  constructor(diagnostic: Diagnostic);
}
export interface CheckOptions {
  from?: Format;
  referenceTime?: number | string;
  rejectExtensions?: boolean;
}
export interface CheckResult {
  valid: true;
  stage: 'resolved';
  rawRecords: number;
  measurements: number;
  ignoredExtensions: number;
}
export interface ResolveOptions<F extends Format = Format> extends CheckOptions {
  to?: F;
  name?: string;
}
export interface ResolveResult<F extends Format> {
  format: F;
  data: F extends 'json' ? string : Uint8Array;
  ignoredExtensions: number;
}
export function check(input: Input, options?: CheckOptions): CheckResult;
export function resolve(input: Input, options: ResolveOptions<'cbor'> & { to: 'cbor' }): ResolveResult<'cbor'>;
export function resolve(input: Input, options?: ResolveOptions<'json'>): ResolveResult<'json'>;
export function resolve(input: Input, options: ResolveOptions): ResolveResult<'json'> | ResolveResult<'cbor'>;
