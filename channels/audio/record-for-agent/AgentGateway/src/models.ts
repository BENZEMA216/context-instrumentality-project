import type { OAuthHelpers } from '@cloudflare/workers-oauth-provider';
import { z } from 'zod';

export interface Env {
  DB: D1Database;
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER: OAuthHelpers;
  PUBLIC_ORIGIN: string;
  APPLE_APP_ID: string;
  CLOUDKIT_CONTAINER: string;
}

export const SCOPES = ['recordings:read', 'transcripts:read'] as const;
export const CHALLENGE_TTL_MS = 5 * 60_000;
export const DEVICE_TTL_MS = 30 * 24 * 60 * 60_000;
export const AUTHORIZATION_TTL_MS = 10 * 60_000;
export const MAX_BODY_BYTES = 1024 * 1024;
export const MAX_TIMESTAMP = 253402300799999;

export const uuid = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i).transform(s => s.toLowerCase());
export const hash = z.string().regex(/^[0-9a-f]{64}$/);
export const timestamp = z.number().int().min(0).max(MAX_TIMESTAMP);
const utf8 = new TextEncoder();
export function validText(value: string, maxBytes: number): boolean {
  return value.trim().length > 0 && !value.includes('\0') && !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)
    && utf8.encode(value).byteLength <= maxBytes;
}
export const text = (maxBytes: number) => z.string().refine(value => validText(value, maxBytes), 'Text is blank, invalid or too long.');

export const manifestSchema = z.object({
  schemaVersion: z.literal(1), id: uuid, sessionID: uuid,
  sequence: z.number().int().min(0).max(2 ** 31 - 1), startedAt: timestamp, endedAt: timestamp,
  sampleRate: z.number().finite().min(1).max(384000), frameCount: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
  fileName: text(100), byteCount: z.number().int().min(1).max(128 * 1024 * 1024), sha256: hash,
}).strict().superRefine((value, ctx) => {
  if (value.endedAt < value.startedAt || value.fileName !== `${value.id}.caf`) ctx.addIssue({ code: 'custom', message: 'Manifest time or file name is invalid.' });
});
export const transcriptSchema = z.object({
  schemaVersion: z.literal(1), segmentID: uuid, audioSHA256: hash, locale: text(128), engine: text(128),
  createdAt: timestamp, text: text(256 * 1024),
  spans: z.array(z.object({ start: z.number().finite().min(0), end: z.number().finite().min(0), text: text(8 * 1024) }).strict()).max(10000),
}).strict();
export const cloudMetadataSchema = z.object({
  accountFingerprint: hash, containerIdentifier: text(255), environment: z.enum(['development', 'production']),
  recordName: text(255), savedAt: timestamp,
}).strict();
export const uploadSchema = z.object({
  manifest: manifestSchema, transcript: transcriptSchema, clientReportedCloudKit: cloudMetadataSchema,
  expectedRevision: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER).optional(),
}).strict().superRefine((value, ctx) => {
  const { manifest, transcript } = value;
  if (manifest.id !== transcript.segmentID || manifest.sha256 !== transcript.audioSHA256) ctx.addIssue({ code: 'custom', message: 'Transcript does not match the recording ID and audio hash.' });
  const duration = manifest.frameCount / manifest.sampleRate;
  if (transcript.spans.some(span => span.start > span.end || span.end > duration)) ctx.addIssue({ code: 'custom', message: 'Transcript span is outside the recording duration.' });
});
export type UploadRequest = z.infer<typeof uploadSchema>;
export type Transcript = z.infer<typeof transcriptSchema>;
export type Manifest = z.infer<typeof manifestSchema>;
export const scopeSchema = z.array(z.enum(SCOPES)).min(1).max(2).refine(values => new Set(values).size === values.length);
export const recordingIDsSchema = z.array(uuid).min(1).max(500).refine(values => new Set(values).size === values.length);
export const appleLoginSchema = z.object({ challengeID: uuid, identityToken: text(16384), cloudKitAccountFingerprint: hash }).strict();
export const approveSchema = z.object({ authorizationID: uuid, recordingIDs: recordingIDsSchema, scopes: scopeSchema }).strict();
export const revokeSchema = z.object({ connectionID: uuid, recordingIDs: recordingIDsSchema.optional() }).strict();
export const emptySchema = z.object({}).strict();
export interface DeviceSession { ownerID: string; tokenHash: string; cloudKitAccountFingerprint: string; expiresAt: number; }
export interface AuthProps { ownerID: string; connectionID: string; }
export interface ConnectionRow {
  id: string; owner_id: string; fingerprint: string; client_id: string; client_name: string;
  scope_json: string; status: string; created_at: number; revoked_at: number | null; cursor_key: string;
}

// All timestamps in the native REST contract are Unix milliseconds.
export interface ChallengeResponse { challengeID: string; nonce: string; expiresAt: number; }
export interface LoginResponse { ownerID: string; deviceToken: string; expiresAt: number; cloudKitAccountFingerprint: string; }
export interface UploadResponse { recordingID: string; revision: number; status: 'stored' | 'unchanged'; transcriptStatus: 'ready'; cachedAt: number; cloudMetadataVerification: 'client_reported'; }
export interface AuthorizationLookupResponse {
  authorizationID: string; clientID: string; clientName: string; clientURI: string | null;
  clientDomain: string | null; redirectHost: string; redirectIsLoopback: boolean;
  requestedScopes: string[]; expiresAt: number;
}
export interface ConnectionResponse {
  connectionID: string; clientID: string; clientName: string; recordingIDs: string[]; scopes: string[];
  status: 'active' | 'revoked'; createdAt: number; revokedAt: number | null;
}
