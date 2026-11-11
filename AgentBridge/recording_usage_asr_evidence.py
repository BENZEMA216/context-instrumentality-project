#!/usr/bin/env python3
"""Read-only metadata evidence for local worker no_speech; never run ASR.

reconcile --inventory ORIGINAL --library MAC_LIBRARY --receiver-state RECEIVER
          --asr-state RECEIVER/transcription --output-dir NEW_PRIVATE_DIRECTORY

The original closed-source inventory is immutable and must require transcripts.
Only exact source identities authorized by a durable paired receipt AND its
export_members selection qualify. Phone archive exportID equals deliveryID;
legacy/unbound imports are deliberately ineligible. A current transcript row
supersedes no_speech; its body is never selected. Missing/retry/failed/pending
states never mean no speech. This does not prove physical silence.

Three independent readonly SQLite snapshots are observed twice. Matching reads
reduce races, but cannot create a cross-database atomic snapshot or prevent a
later state change. Reconcile again immediately before resealing. Each run starts
from ORIGINAL, so reverted/missing evidence revokes the candidate's no_speech.
Only new private evidence/candidate files and a last-written latest.json pointer
are written. Source databases, audio, text, inventories and services are untouched.
"""

import argparse
import contextlib
import copy
from datetime import date, datetime, time as daytime, timedelta
import hashlib
import os
from pathlib import Path
import sqlite3
import sys
import time
from zoneinfo import ZoneInfo

from drive_sync import (DriveError, atomic_private, exclusive, fsync_directory,
                        private_directory, private_file, safe_path)
from library import BridgeError, canonical_json, canonical_uuid, parse_json, validate_manifest

MAX_SOURCES = 4096
MAX_RECEIPTS = 10000
MAX_INVENTORY_BYTES = 4 * 1024 * 1024
FIELDS = {"segmentID", "sessionID", "sequence", "audioSHA256"}


def fingerprint(value):
    return hashlib.sha256(canonical_json(value).encode()).hexdigest()


def is_sha(value):
    return isinstance(value,str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def source_identity(value):
    if (not isinstance(value,dict) or set(value) != FIELDS or type(value["sequence"]) is not int
            or value["sequence"] < 0 or not is_sha(value["audioSHA256"])):
        raise DriveError("invalid_inventory")
    for key in ("segmentID","sessionID"):
        if canonical_uuid(value[key]) != value[key]: raise DriveError("invalid_inventory")


def original_inventory(data):
    value = parse_json(data)
    keys = {"schemaVersion","libraryID","day","timeZone","evidenceKind","dayClosed","evidenceRef","sources"}
    if (not isinstance(value,dict) or set(value) != keys or type(value["schemaVersion"]) is not int
            or value["schemaVersion"] != 1 or canonical_uuid(value["libraryID"]) != value["libraryID"]
            or value["timeZone"] != "Asia/Shanghai" or type(value["dayClosed"]) is not bool
            or value["evidenceKind"] not in {"source_catalog_verified","operator_declared"}
            or not isinstance(value["evidenceRef"],str) or not value["evidenceRef"].strip()
            or not isinstance(value["sources"],list) or len(value["sources"]) > MAX_SOURCES):
        raise DriveError("invalid_inventory")
    try:
        day = date.fromisoformat(value["day"])
        if day.isoformat() != value["day"]: raise ValueError()
        start = int(datetime.combine(day,daytime(),ZoneInfo(value["timeZone"])).timestamp()*1000)
        end = int(datetime.combine(day+timedelta(days=1),daytime(),ZoneInfo(value["timeZone"])).timestamp()*1000)
    except (ValueError,TypeError,OverflowError): raise DriveError("invalid_inventory") from None
    seen = set()
    for entry in value["sources"]:
        if not isinstance(entry,dict) or set(entry) != {"source","startedAt","endedAt","asr"}:
            raise DriveError("base_inventory_must_require_transcripts")
        source_identity(entry["source"])
        sid = entry["source"]["segmentID"]
        if (sid in seen or entry["asr"] != "transcript_required" or type(entry["startedAt"]) is not int
                or type(entry["endedAt"]) is not int or not 0 <= entry["startedAt"] < entry["endedAt"]
                or not (entry["startedAt"] < end and entry["endedAt"] > start)):
            raise DriveError("invalid_inventory")
        seen.add(sid)
    return value


ALLOWED = {
    "library": {"recordings":{"id","session_id","sequence","started_at","ended_at","manifest_json"},
                "exports":{"id","digest","imported_at"},"export_members":{"export_id","recording_id"},
                "transcripts":{"recording_id"}},
    "receiver": {"identity":{"singleton","receiver_id","library"},
                 "requests":{"id","archive_hash","receipt_json","failure_json"}},
    "worker": {"jobs":{"recording_id","audio_hash","status","attempts","retry_at","last_error","updated_at"}},
}


@contextlib.contextmanager
def readonly_database(path, kind):
    path = private_file(path); private_directory(path.parent)
    # Read-only WAL opening can need shared-memory creation on some SQLite
    # versions. Reject it rather than writing sidecars or ignoring committed WAL.
    for suffix in ("-wal","-shm"):
        if path.with_name(path.name+suffix).exists(): raise DriveError("wal_snapshot_not_supported")
    with path.open("rb") as header:
        data = header.read(20)
    if len(data) != 20 or data[:16] != b"SQLite format 3\0" or data[18:20] != b"\x01\x01":
        raise DriveError("unsupported_sqlite_journal")
    connection = sqlite3.connect(path.as_uri()+"?mode=ro",uri=True,timeout=2,isolation_level=None)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA trusted_schema=OFF")
        def authorize(action, table, column, database, trigger):
            if action == sqlite3.SQLITE_READ:
                return sqlite3.SQLITE_OK if column in ALLOWED[kind].get(table,set()) else sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK if action in {sqlite3.SQLITE_SELECT,sqlite3.SQLITE_TRANSACTION,sqlite3.SQLITE_PRAGMA} else sqlite3.SQLITE_DENY
        connection.set_authorizer(authorize)
        connection.execute("BEGIN")
        yield connection
    finally:
        connection.close()


class ASREvidence:
    def __init__(self, inventory, library, receiver_state, asr_state, *, clock=time.time, between_reads=None):
        self.inventory_path = private_file(inventory)
        if self.inventory_path.stat().st_size > MAX_INVENTORY_BYTES: raise DriveError("inventory_too_large")
        self.original_bytes = self.inventory_path.read_bytes()
        self.inventory = original_inventory(self.original_bytes)
        self.base_sha = hashlib.sha256(self.original_bytes).hexdigest()
        self.library = private_directory(library)
        self.receiver = private_directory(receiver_state)
        self.asr = private_directory(asr_state)
        self.clock, self.between_reads = clock, between_reads
        self.paths = {"library":self.library/"library.sqlite3", "receiver":self.receiver/"delivery.sqlite3",
                      "worker":self.asr/"transcription.sqlite3"}

    def _receipt_authorizations(self, library, receiver, receiver_id):
        rows = receiver.execute("SELECT id,archive_hash,receipt_json,failure_json IS NULL AS no_failure FROM requests WHERE receipt_json IS NOT NULL ORDER BY id LIMIT ?",
                                (MAX_RECEIPTS+1,)).fetchall()
        if len(rows) > MAX_RECEIPTS: raise DriveError("receipt_budget_exceeded")
        authorized = {}
        wanted = {entry["source"]["segmentID"] for entry in self.inventory["sources"]}
        for row in rows:
            try:
                receipt = parse_json(row["receipt_json"])
                if (not isinstance(receipt,dict) or set(receipt) != {"schemaVersion","receiverID","deliveryID","archiveSHA256","recordingIDs","storedAt"}
                        or type(receipt["schemaVersion"]) is not int or receipt["schemaVersion"] != 1
                        or receipt["receiverID"] != receiver_id or canonical_uuid(row["id"]) != row["id"]
                        or receipt["deliveryID"] != row["id"] or not row["no_failure"]
                        or not is_sha(row["archive_hash"]) or receipt["archiveSHA256"] != row["archive_hash"]
                        or type(receipt["storedAt"]) is not int or receipt["storedAt"] < 0
                        or not isinstance(receipt["recordingIDs"],list) or not 1 <= len(receipt["recordingIDs"]) <= MAX_SOURCES): continue
                ids = receipt["recordingIDs"]
                if len(set(ids)) != len(ids) or any(canonical_uuid(sid) != sid for sid in ids) or not wanted.intersection(ids): continue
                # Phone AutomaticDeliveryArchiveBuilder uses exportID=job.id;
                # it is not safe to guess another export from a shared member.
                exported = library.execute("SELECT id,digest,imported_at FROM exports WHERE id=?",(row["id"],)).fetchone()
                if exported is None or not is_sha(exported["digest"]) or type(exported["imported_at"]) is not int: continue
                members = library.execute("SELECT recording_id FROM export_members WHERE export_id=? ORDER BY recording_id LIMIT ?",
                                          (row["id"],MAX_SOURCES+1)).fetchall()
                selection = [member[0] for member in members]
                if selection != sorted(ids): continue
                proof = {"deliveryID":row["id"],"exportID":exported["id"],"archiveSHA256":row["archive_hash"],
                         "receiptSHA256":hashlib.sha256(row["receipt_json"].encode()).hexdigest(),
                         "exportEnvelopeSHA256":exported["digest"],"exportMembersSHA256":fingerprint(selection),
                         "exportMemberCount":len(selection),"storedAt":receipt["storedAt"]}
                for sid in wanted.intersection(ids): authorized.setdefault(sid,[]).append(proof)
            except (BridgeError,ValueError,TypeError,KeyError):
                continue  # unrelated/malformed receipts cannot authorize a source
        return authorized

    def _observe(self):
        with contextlib.ExitStack() as stack:
            db = {key:stack.enter_context(readonly_database(path,key)) for key,path in self.paths.items()}
            version = db["library"].execute("PRAGMA user_version").fetchone()[0]
            if version not in (1,2): raise DriveError("invalid_library_schema")
            owner = db["receiver"].execute("SELECT receiver_id,library FROM identity WHERE singleton=1").fetchone()
            if owner is None or owner["library"] != str(self.library): raise DriveError("receiver_library_mismatch")
            receiver_id = canonical_uuid(owner["receiver_id"])
            if receiver_id != owner["receiver_id"]: raise DriveError("receiver_identity_mismatch")
            authorizations = self._receipt_authorizations(db["library"],db["receiver"],receiver_id)
            observed = {}
            for entry in self.inventory["sources"]:
                sid = entry["source"]["segmentID"]
                record = db["library"].execute("SELECT id,session_id,sequence,started_at,ended_at,manifest_json FROM recordings WHERE id=?",(sid,)).fetchone()
                worker = db["worker"].execute("SELECT recording_id,audio_hash,status,attempts,retry_at,last_error IS NULL AS no_error,updated_at FROM jobs WHERE recording_id=?",(sid,)).fetchone()
                present = bool(db["library"].execute("SELECT recording_id FROM transcripts WHERE recording_id=? LIMIT 1",(sid,)).fetchone()) if version == 2 else False
                observed[sid] = {"record":dict(record) if record else None,"worker":dict(worker) if worker else None,
                                 "transcriptPresent":present,"authorizations":authorizations.get(sid,[])}
            return {"receiverID":receiver_id,"sources":observed}

    def _qualify(self, entry, observed, stable):
        sid, source = entry["source"]["segmentID"], entry["source"]
        reasons = []
        if not stable: reasons.append("metadata_changed_during_check")
        record, worker = observed["record"], observed["worker"]
        manifest_sha = None
        if not observed["authorizations"]: reasons.append("durable_receipt_export_members_missing")
        if record is None: reasons.append("recording_missing")
        else:
            try:
                manifest = validate_manifest(parse_json(record["manifest_json"]),256*1024*1024)
                expected = {"segmentID":manifest["id"],"sessionID":manifest["sessionID"],"sequence":manifest["sequence"],"audioSHA256":manifest["sha256"]}
                if (expected != source or record["id"] != source["segmentID"] or record["session_id"] != source["sessionID"]
                        or record["sequence"] != source["sequence"] or any(record[a] != manifest[b] or manifest[b] != entry[b]
                           for a,b in (("started_at","startedAt"),("ended_at","endedAt")))): reasons.append("source_identity_mismatch")
                manifest_sha = hashlib.sha256(record["manifest_json"].encode()).hexdigest()
            except (BridgeError,ValueError,TypeError,KeyError): reasons.append("invalid_source_manifest")
        if worker is None: reasons.append("worker_missing")
        elif (worker["recording_id"] != sid or worker["audio_hash"] != source["audioSHA256"]): reasons.append("worker_audio_identity_mismatch")
        elif (worker["status"] != "no_speech" or type(worker["attempts"]) is not int or worker["attempts"] < 1
                or worker["retry_at"] != 0 or not worker["no_error"] or type(worker["updated_at"]) is not int
                or worker["updated_at"] < 0): reasons.append("worker_not_terminal_no_speech")
        if observed["transcriptPresent"]: reasons.append("transcript_supersedes_no_speech")
        return {"source":copy.deepcopy(source),"status":"transcript_required" if reasons else "no_speech_verified",
                "reasonCodes":reasons,"manifestMetadataSHA256":manifest_sha,"transcriptRowPresent":observed["transcriptPresent"],
                "worker":worker,"authorizations":observed["authorizations"]}

    def reconcile(self, output_dir):
        root = safe_path(output_dir)
        if any(root == path or path in root.parents or root in path.parents for path in (self.library,self.receiver,self.asr)):
            raise DriveError("overlapping_output")
        root = private_directory(root,create=True)
        bound = {"schemaVersion":1,"baseInventorySHA256":self.base_sha,"library":str(self.library),
                 "receiverState":str(self.receiver),"asrState":str(self.asr)}
        with exclusive(root/"evidence.lock"):
            config_path = root/"binding.json"
            if config_path.exists():
                if parse_json(private_file(config_path).read_bytes()) != bound: raise DriveError("evidence_binding_changed")
            else: atomic_private(config_path,canonical_json(bound).encode())
            before = self._observe()
            if self.between_reads is not None: self.between_reads()
            after = self._observe()
            if private_file(self.inventory_path).read_bytes() != self.original_bytes: raise DriveError("base_inventory_changed")
            sources = []
            for entry in self.inventory["sources"]:
                sid = entry["source"]["segmentID"]
                stable = before["receiverID"] == after["receiverID"] and before["sources"][sid] == after["sources"][sid]
                sources.append(self._qualify(entry,after["sources"][sid],stable))
            payload = {"schemaVersion":1,"baseInventorySHA256":self.base_sha,"libraryID":self.inventory["libraryID"],
                       "day":self.inventory["day"],"sourceCount":len(sources),"receiverID":after["receiverID"],
                       "consistency":"two_equal_metadata_reads_not_cross_database_atomic","sources":sources,
                       "audioBytesRead":0,"transcriptBodyRead":False,"provesPhysicalSilence":False,
                       "sourceCatalogProofUnchanged":True}
            evidence_id = fingerprint(payload)
            evidence = {**payload,"evidenceID":evidence_id}
            candidate = copy.deepcopy(self.inventory)
            active = []
            for entry, proof in zip(candidate["sources"],sources):
                if proof["status"] == "no_speech_verified":
                    entry["asr"] = "no_speech_verified"
                    entry["noSpeechEvidence"] = "mac-asr-metadata:v1:"+evidence_id+"#"+entry["source"]["segmentID"]
                    active.append(entry["source"]["segmentID"])
            evidence_path, candidate_path = root/(evidence_id+".evidence.json"),root/(evidence_id+".inventory.json")
            for path,value in ((evidence_path,evidence),(candidate_path,candidate)):
                data = canonical_json(value).encode()
                if path.exists():
                    if private_file(path).read_bytes() != data: raise DriveError("immutable_evidence_conflict")
                else: atomic_private(path,data)
            latest_path, previous_active = root/"latest.json",set()
            if latest_path.exists(): previous_active = set(parse_json(private_file(latest_path).read_bytes())["activeNoSpeechSegmentIDs"])
            latest = {"schemaVersion":1,"evidenceID":evidence_id,"baseInventorySHA256":self.base_sha,
                      "candidateInventorySHA256":hashlib.sha256(candidate_path.read_bytes()).hexdigest(),
                      "checkedAtUnixMS":int(self.clock()*1000),"evidencePath":str(evidence_path),"candidateInventoryPath":str(candidate_path),
                      "activeNoSpeechSegmentIDs":active,"withdrawnNoSpeechSegmentIDs":sorted(previous_active-set(active))}
            atomic_private(latest_path,canonical_json(latest).encode()); fsync_directory(root)
            return {"schemaVersion":1,"evidenceID":evidence_id,"sourceCount":len(sources),"verifiedNoSpeechCount":len(active),
                    "transcriptRequiredCount":len(sources)-len(active),"withdrawnNoSpeechCount":len(latest["withdrawnNoSpeechSegmentIDs"]),
                    "latestPath":str(latest_path),"candidateInventoryPath":str(candidate_path),"audioBytesRead":0,"transcriptBodyRead":False,
                    "sourceCatalogProofChanged":False,"sourceDatabasesWritten":False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command",choices=["reconcile"])
    for name in ("inventory","library","receiver-state","asr-state","output-dir"): parser.add_argument("--"+name,required=True)
    args = parser.parse_args(argv)
    try:
        evidence = ASREvidence(args.inventory,args.library,args.receiver_state,args.asr_state)
        print(canonical_json(evidence.reconcile(args.output_dir))); return 0
    except (BridgeError,OSError,ValueError,TypeError,KeyError,sqlite3.Error) as error:
        code = error.code if isinstance(error,BridgeError) else "asr_metadata_unavailable"
        print(canonical_json({"error":{"code":code}}),file=sys.stderr); return 1


if __name__ == "__main__": raise SystemExit(main())
