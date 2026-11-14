import { ApiError, canonical, parse, readJSON, sha256 } from './http';
import { uploadSchema, type ConnectionResponse, type ConnectionRow, type DeviceSession, type Env, type UploadResponse } from './models';

export interface RecordingRow {
  owner_id: string; id: string; fingerprint: string; session_id: string; sequence: number; started_at: number;
  manifest_json: string; transcript_json: string; cloud_metadata_json: string; audio_hash: string;
  content_digest: string; search_text: string; revision: number; cached_at: number; deleted_at: number | null;
}
export function summary(row: RecordingRow) {
  return { ...JSON.parse(row.manifest_json), revision: row.revision, cachedAt: row.cached_at,
    transcriptStatus: 'ready', cloudMetadataVerification: 'client_reported' };
}
export async function upload(request: Request, env: Env, db: D1DatabaseSession, session: DeviceSession, now: number): Promise<UploadResponse> {
  const value = parse(uploadSchema, await readJSON(request));
  const source = value.clientReportedCloudKit;
  if (source.accountFingerprint !== session.cloudKitAccountFingerprint || source.containerIdentifier !== env.CLOUDKIT_CONTAINER)
    throw new ApiError(403, 'scope_mismatch', 'The CloudKit account or container does not match this device session.');
  const manifestJSON = canonical(value.manifest), transcriptJSON = canonical(value.transcript);
  const sourceIdentity = (metadata: typeof source) => canonical({ accountFingerprint: metadata.accountFingerprint, containerIdentifier: metadata.containerIdentifier, environment: metadata.environment, recordName: metadata.recordName });
  const digest = await sha256(canonical({ manifest: value.manifest, transcript: value.transcript, source: sourceIdentity(source) }));
  const prior = await db.prepare('SELECT * FROM recordings WHERE owner_id=? AND id=?').bind(session.ownerID, value.manifest.id).first<RecordingRow>();
  if (prior) {
    if (prior.deleted_at !== null || prior.fingerprint !== session.cloudKitAccountFingerprint || prior.manifest_json !== manifestJSON || sourceIdentity(JSON.parse(prior.cloud_metadata_json)) !== sourceIdentity(source))
      throw new ApiError(409, 'conflict', 'A recording cannot be rebound to different audio, source metadata or an account.');
    if (prior.content_digest === digest) return { recordingID: prior.id, revision: prior.revision, status: 'unchanged', transcriptStatus: 'ready', cachedAt: prior.cached_at, cloudMetadataVerification: 'client_reported' };
    if (value.expectedRevision !== prior.revision) throw new ApiError(409, 'conflict', 'Updating a transcript requires the current expectedRevision.');
    const result = await db.prepare('UPDATE recordings SET transcript_json=?,content_digest=?,search_text=?,revision=revision+1,cached_at=? WHERE owner_id=? AND id=? AND revision=? AND content_digest=? AND deleted_at IS NULL RETURNING revision')
      .bind(transcriptJSON, digest, value.transcript.text.normalize('NFC').toLowerCase(), now, session.ownerID, prior.id, prior.revision, prior.content_digest).first<{ revision: number }>();
    if (!result) throw new ApiError(409, 'conflict', 'The recording changed. Read its current revision before retrying.');
    return { recordingID: prior.id, revision: result.revision, status: 'stored', transcriptStatus: 'ready', cachedAt: now, cloudMetadataVerification: 'client_reported' };
  }
  if (value.expectedRevision !== undefined && value.expectedRevision !== 0) throw new ApiError(409, 'conflict', 'A new recording has revision zero before upload.');
  try {
    await db.prepare('INSERT INTO recordings(owner_id,id,fingerprint,session_id,sequence,started_at,manifest_json,transcript_json,cloud_metadata_json,audio_hash,content_digest,search_text,revision,cached_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1,?)')
      .bind(session.ownerID, value.manifest.id, session.cloudKitAccountFingerprint, value.manifest.sessionID, value.manifest.sequence, value.manifest.startedAt, manifestJSON, transcriptJSON, canonical(source), value.manifest.sha256, digest, value.transcript.text.normalize('NFC').toLowerCase(), now).run();
  } catch (error) {
    // A uniqueness race is a conflict. Infrastructure errors remain server errors.
    if (String(error).includes('UNIQUE constraint')) throw new ApiError(409, 'conflict', 'That recording or session sequence already exists. Retry using the current recording.');
    throw error;
  }
  return { recordingID: value.manifest.id, revision: 1, status: 'stored', transcriptStatus: 'ready', cachedAt: now, cloudMetadataVerification: 'client_reported' };
}
export async function connectionResponse(db: D1DatabaseSession, row: ConnectionRow): Promise<ConnectionResponse> {
  const records = await db.prepare('SELECT recording_id FROM connection_recordings WHERE connection_id=? AND owner_id=? AND revoked_at IS NULL ORDER BY recording_id').bind(row.id, row.owner_id).all<{ recording_id: string }>();
  return { connectionID: row.id, clientID: row.client_id, clientName: row.client_name, recordingIDs: records.results.map(item => item.recording_id), scopes: JSON.parse(row.scope_json), status: row.status as 'active' | 'revoked', createdAt: row.created_at, revokedAt: row.revoked_at };
}
export async function currentConnection(db: D1DatabaseSession, ownerID: string, connectionID: string, clientID?: string): Promise<ConnectionRow> {
  const row = await db.prepare('SELECT * FROM connections WHERE id=? AND owner_id=? AND status=\'active\'').bind(connectionID, ownerID).first<ConnectionRow>();
  if (!row || (clientID !== undefined && row.client_id !== clientID)) throw new ApiError(403, 'authorization_revoked', 'This connection is no longer authorized.');
  return row;
}

export async function deleteRecording(db: D1DatabaseSession, session: DeviceSession, recordingID: string, now: number) {
  const result = await db.prepare('UPDATE recordings SET deleted_at=?,revision=revision+1,transcript_json=\'{}\',search_text=\'\',content_digest=\'\' WHERE owner_id=? AND fingerprint=? AND id=? AND deleted_at IS NULL RETURNING revision')
    .bind(now, session.ownerID, session.cloudKitAccountFingerprint, recordingID).first<{ revision: number }>();
  if (result) return { recordingID, revision: result.revision, status: 'deleted' as const };
  const prior = await db.prepare('SELECT revision FROM recordings WHERE owner_id=? AND fingerprint=? AND id=? AND deleted_at IS NOT NULL').bind(session.ownerID, session.cloudKitAccountFingerprint, recordingID).first<{ revision: number }>();
  if (!prior) throw new ApiError(404, 'not_found', 'The recording does not exist in the current account.');
  return { recordingID, revision: prior.revision, status: 'deleted' as const };
}

export async function recordingRevision(db: D1DatabaseSession, session: DeviceSession, recordingID: string) {
  const row = await db.prepare('SELECT revision,deleted_at FROM recordings WHERE owner_id=? AND fingerprint=? AND id=?').bind(session.ownerID, session.cloudKitAccountFingerprint, recordingID).first<{ revision: number; deleted_at: number | null }>();
  if (!row) throw new ApiError(404, 'not_found', 'The recording does not exist in the current account.');
  return { recordingID, revision: row.revision, deleted: row.deleted_at !== null };
}
