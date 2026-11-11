PRAGMA foreign_keys = ON;
CREATE TABLE owners (
  id TEXT PRIMARY KEY, apple_subject_hash TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL
);
CREATE TABLE auth_challenges (
  id TEXT PRIMARY KEY, nonce_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, consumed_at INTEGER
);
CREATE INDEX challenge_expiry ON auth_challenges(expires_at);
CREATE TABLE device_sessions (
  token_hash TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES owners(id), fingerprint TEXT NOT NULL,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, revoked_at INTEGER
);
CREATE INDEX device_owner ON device_sessions(owner_id);
CREATE TABLE recordings (
  owner_id TEXT NOT NULL REFERENCES owners(id), id TEXT NOT NULL, fingerprint TEXT NOT NULL,
  session_id TEXT NOT NULL, sequence INTEGER NOT NULL, started_at INTEGER NOT NULL,
  manifest_json TEXT NOT NULL, transcript_json TEXT NOT NULL, cloud_metadata_json TEXT NOT NULL,
  audio_hash TEXT NOT NULL, content_digest TEXT NOT NULL, search_text TEXT NOT NULL,
  revision INTEGER NOT NULL, cached_at INTEGER NOT NULL, deleted_at INTEGER,
  PRIMARY KEY(owner_id,id), UNIQUE(owner_id,fingerprint,session_id,sequence)
);
CREATE INDEX recordings_order ON recordings(owner_id,fingerprint,started_at,id);
CREATE TABLE connections (
  id TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES owners(id), fingerprint TEXT NOT NULL,
  client_id TEXT NOT NULL, client_name TEXT NOT NULL, scope_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('active','revoked')), created_at INTEGER NOT NULL, revoked_at INTEGER,
  cursor_key TEXT NOT NULL
);
CREATE INDEX connection_owner ON connections(owner_id,fingerprint,created_at);
CREATE TABLE connection_recordings (
  connection_id TEXT NOT NULL REFERENCES connections(id), owner_id TEXT NOT NULL, recording_id TEXT NOT NULL,
  revoked_at INTEGER, PRIMARY KEY(connection_id,recording_id),
  FOREIGN KEY(owner_id,recording_id) REFERENCES recordings(owner_id,id)
);
CREATE TABLE authorization_requests (
  id TEXT PRIMARY KEY, code_hash TEXT NOT NULL UNIQUE, browser_hash TEXT NOT NULL, consent_handle TEXT NOT NULL,
  details_json TEXT NOT NULL, requested_scope_json TEXT NOT NULL, client_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending','approved','completing','complete','denied','failed')),
  expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL,
  connection_id TEXT REFERENCES connections(id), owner_id TEXT REFERENCES owners(id), approved_scope_json TEXT
);
CREATE INDEX authorization_expiry ON authorization_requests(expires_at);
CREATE TABLE recording_changes (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT, owner_id TEXT NOT NULL, recording_id TEXT NOT NULL,
  revision INTEGER NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('created','updated','deleted','revoked')),
  connection_id TEXT, changed_at INTEGER NOT NULL
);
CREATE INDEX changes_owner ON recording_changes(owner_id,sequence);
CREATE TABLE rate_limits (id TEXT PRIMARY KEY,count INTEGER NOT NULL,expires_at INTEGER NOT NULL);
CREATE INDEX rate_expiry ON rate_limits(expires_at);
CREATE TRIGGER recording_created AFTER INSERT ON recordings BEGIN
  INSERT INTO recording_changes(owner_id,recording_id,revision,kind,changed_at)
  VALUES (NEW.owner_id,NEW.id,NEW.revision,'created',NEW.cached_at);
END;
CREATE TRIGGER recording_updated AFTER UPDATE OF revision ON recordings WHEN NEW.deleted_at IS NULL BEGIN
  INSERT INTO recording_changes(owner_id,recording_id,revision,kind,changed_at)
  VALUES (NEW.owner_id,NEW.id,NEW.revision,'updated',NEW.cached_at);
END;
CREATE TRIGGER recording_deleted AFTER UPDATE OF deleted_at ON recordings WHEN OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL BEGIN
  INSERT INTO recording_changes(owner_id,recording_id,revision,kind,changed_at)
  VALUES (NEW.owner_id,NEW.id,NEW.revision,'deleted',NEW.deleted_at);
END;
CREATE TRIGGER recording_revoked AFTER UPDATE OF revoked_at ON connection_recordings WHEN OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL BEGIN
  INSERT INTO recording_changes(owner_id,recording_id,revision,kind,connection_id,changed_at)
  SELECT NEW.owner_id,NEW.recording_id,revision,'revoked',NEW.connection_id,NEW.revoked_at
  FROM recordings WHERE owner_id=NEW.owner_id AND id=NEW.recording_id;
END;
