"""Temporary synthetic metadata databases only: no service, audio, text or cloud."""

import contextlib
import copy
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid

import recording_usage_asr_evidence as evidence
from drive_sync import DriveError
from library import SCHEMA, TRANSCRIPT_SCHEMA, canonical_json

DAY_START = 1792771200000  # 2026-10-24 00:00 Asia/Shanghai
BODY = "SYNTHETIC SENTINEL: transcript body must never be selected"


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(); self.root.chmod(0o700)
        self.library, self.receiver, self.asr = (self.root/x for x in ("library","receiver","worker"))
        for path in (self.library,self.receiver,self.asr): path.mkdir(mode=0o700)
        self.db = {"library":self.library/"library.sqlite3","receiver":self.receiver/"delivery.sqlite3",
                   "worker":self.asr/"transcription.sqlite3"}
        self.library_id, self.receiver_id, self.delivery_id = (str(uuid.uuid4()) for _ in range(3))
        self.manifest = {"schemaVersion":1,"id":str(uuid.uuid4()),"sessionID":str(uuid.uuid4()),"sequence":7,
                         "startedAt":DAY_START+1000,"endedAt":DAY_START+1010,"sampleRate":16000.0,
                         "frameCount":160,"byteCount":384,"sha256":"a"*64}
        self.manifest["fileName"] = self.manifest["id"]+".caf"
        self.source = {"segmentID":self.manifest["id"],"sessionID":self.manifest["sessionID"],
                       "sequence":7,"audioSHA256":"a"*64}
        self.inventory = {"schemaVersion":1,"libraryID":self.library_id,"day":"2026-10-24","timeZone":"Asia/Shanghai",
                          "evidenceKind":"source_catalog_verified","dayClosed":True,"evidenceRef":"SYNTHETIC closed source catalog",
                          "sources":[{"source":self.source,"startedAt":self.manifest["startedAt"],
                                      "endedAt":self.manifest["endedAt"],"asr":"transcript_required"}]}
        self.inventory_path = self.root/"original.json"
        self.write_inventory(self.inventory)
        self.receipt = {"schemaVersion":1,"receiverID":self.receiver_id,"deliveryID":self.delivery_id,"archiveSHA256":"b"*64,
                        "recordingIDs":[self.source["segmentID"]],"storedAt":DAY_START+2000}
        with sqlite3.connect(self.db["library"]) as db:
            for statement in SCHEMA+TRANSCRIPT_SCHEMA: db.execute(statement)
            db.execute("PRAGMA user_version=2")
            db.execute("INSERT INTO recordings VALUES(?,?,?,?,?,?)",(self.source["segmentID"],self.source["sessionID"],7,
                       self.manifest["startedAt"],self.manifest["endedAt"],canonical_json(self.manifest)))
            db.execute("INSERT INTO exports VALUES(?,?,?)",(self.delivery_id,"c"*64,DAY_START+2000))
            db.execute("INSERT INTO export_members VALUES(?,?)",(self.delivery_id,self.source["segmentID"]))
        with sqlite3.connect(self.db["receiver"]) as db:
            db.execute("CREATE TABLE identity(singleton INTEGER PRIMARY KEY,receiver_id TEXT,library TEXT)")
            db.execute("INSERT INTO identity VALUES(1,?,?)",(self.receiver_id,str(self.library)))
            db.execute("CREATE TABLE requests(id TEXT PRIMARY KEY,archive_hash TEXT,receipt_json TEXT,failure_json TEXT)")
            db.execute("INSERT INTO requests VALUES(?,?,?,NULL)",(self.delivery_id,"b"*64,canonical_json(self.receipt)))
        with sqlite3.connect(self.db["worker"]) as db:
            db.execute("CREATE TABLE jobs(recording_id TEXT PRIMARY KEY,audio_hash TEXT,status TEXT,attempts INTEGER,"
                       "retry_at INTEGER,last_error TEXT,updated_at INTEGER)")
            db.execute("INSERT INTO jobs VALUES(?,?,?,1,0,NULL,?)",(self.source["segmentID"],"a"*64,"no_speech",DAY_START+3000))
        for path in self.db.values(): path.chmod(0o600)
        self.output = self.root/"new-evidence"

    def tearDown(self): self.temporary.cleanup()

    def write_inventory(self,value):
        self.inventory_path.write_text(canonical_json(value)); self.inventory_path.chmod(0o600)

    def engine(self,**kwargs):
        return evidence.ASREvidence(self.inventory_path,self.library,self.receiver,self.asr,clock=lambda:1800000000,**kwargs)

    def sql(self,kind,statement,args=()):
        with sqlite3.connect(self.db[kind]) as db: db.execute(statement,args)

    def receipt_change(self,**changes):
        value = {**self.receipt,**changes}
        self.sql("receiver","UPDATE requests SET receipt_json=?",(canonical_json(value),))

    def reconcile(self,**kwargs):
        result = self.engine(**kwargs).reconcile(self.output)
        return result,json.loads(Path(result["candidateInventoryPath"]).read_bytes()),json.loads(Path(result["latestPath"]).read_bytes())

    def rejected_source(self,reason=None,**kwargs):
        result,candidate,latest = self.reconcile(**kwargs)
        self.assertEqual(result["verifiedNoSpeechCount"],0)
        self.assertEqual(candidate,self.inventory)
        proof = json.loads(Path(latest["evidencePath"]).read_bytes())["sources"][0]
        if reason: self.assertIn(reason,proof["reasonCodes"])
        return result,proof

    @contextlib.contextmanager
    def code(self,code):
        with self.assertRaises(DriveError) as caught: yield
        self.assertEqual(caught.exception.code,code)

    def test_exact_terminal_receipt_selection_and_source_evidence(self):
        original = self.inventory_path.read_bytes()
        before = {kind:path.read_bytes() for kind,path in self.db.items()}
        result,candidate,latest = self.reconcile()
        self.assertEqual(result["verifiedNoSpeechCount"],1)
        self.assertEqual(result["audioBytesRead"],0); self.assertFalse(result["transcriptBodyRead"])
        self.assertFalse(result["sourceDatabasesWritten"])
        expected = copy.deepcopy(self.inventory)
        expected["sources"][0].update(asr="no_speech_verified",noSpeechEvidence="mac-asr-metadata:v1:"+result["evidenceID"]+"#"+self.source["segmentID"])
        self.assertEqual(candidate,expected)
        proof = json.loads(Path(latest["evidencePath"]).read_bytes())
        self.assertEqual(proof["baseInventorySHA256"],hashlib.sha256(original).hexdigest())
        self.assertEqual(proof["sources"][0]["source"],self.source)
        authorization = proof["sources"][0]["authorizations"][0]
        self.assertEqual(authorization["archiveSHA256"],"b"*64)
        self.assertEqual(authorization["exportEnvelopeSHA256"],"c"*64)
        self.assertEqual(authorization["exportID"],self.delivery_id)
        self.assertEqual(authorization["exportMemberCount"],1)
        self.assertFalse(proof["provesPhysicalSilence"])
        self.assertEqual(self.inventory_path.read_bytes(),original)
        self.assertEqual({kind:path.read_bytes() for kind,path in self.db.items()},before)
        for directory in (self.library,self.receiver,self.asr):
            self.assertEqual(len(list(directory.iterdir())),1)
        for path in self.output.iterdir(): self.assertEqual(path.stat().st_mode&0o777,0o600)
        self.assertEqual(self.output.stat().st_mode&0o777,0o700)

    def test_repeated_reconciliation_is_content_idempotent(self):
        first,_,_ = self.reconcile(); names = sorted(x.name for x in self.output.iterdir())
        second,_,_ = self.reconcile()
        self.assertEqual(first,second)
        self.assertEqual(names,sorted(x.name for x in self.output.iterdir()))

    def test_392_source_day_full_selection_and_one_reverted_worker(self):
        records, jobs, members = [], [], []
        for index in range(1,392):
            manifest = {**self.manifest,"id":str(uuid.uuid4()),"sequence":7+index,
                        "startedAt":DAY_START+1000+index*1000,"endedAt":DAY_START+1010+index*1000,
                        "sha256":hashlib.sha256(str(index).encode()).hexdigest()}
            manifest["fileName"] = manifest["id"]+".caf"
            source = {"segmentID":manifest["id"],"sessionID":manifest["sessionID"],
                      "sequence":manifest["sequence"],"audioSHA256":manifest["sha256"]}
            self.inventory["sources"].append({"source":source,"startedAt":manifest["startedAt"],
                                               "endedAt":manifest["endedAt"],"asr":"transcript_required"})
            records.append((manifest["id"],manifest["sessionID"],manifest["sequence"],manifest["startedAt"],manifest["endedAt"],canonical_json(manifest)))
            members.append((self.delivery_id,manifest["id"]))
            jobs.append((manifest["id"],manifest["sha256"],"no_speech",1,0,None,DAY_START+3000))
        with sqlite3.connect(self.db["library"]) as db:
            db.executemany("INSERT INTO recordings VALUES(?,?,?,?,?,?)",records)
            db.executemany("INSERT INTO export_members VALUES(?,?)",members)
        with sqlite3.connect(self.db["worker"]) as db: db.executemany("INSERT INTO jobs VALUES(?,?,?,?,?,?,?)",jobs)
        self.receipt_change(recordingIDs=[entry["source"]["segmentID"] for entry in self.inventory["sources"]])
        self.write_inventory(self.inventory)
        before = {kind:path.read_bytes() for kind,path in self.db.items()}
        result,candidate,_ = self.reconcile()
        self.assertEqual(result["sourceCount"],392)
        self.assertEqual(result["verifiedNoSpeechCount"],392)
        self.assertEqual(len(candidate["sources"]),392)
        self.assertEqual({kind:path.read_bytes() for kind,path in self.db.items()},before)
        self.sql("worker","UPDATE jobs SET status='retry' WHERE recording_id=?",(jobs[-1][0],))
        result,candidate,_ = self.reconcile()
        self.assertEqual(result["verifiedNoSpeechCount"],391)
        self.assertEqual(result["transcriptRequiredCount"],1)
        self.assertEqual(result["withdrawnNoSpeechCount"],1)
        self.assertEqual(candidate["sources"][-1]["asr"],"transcript_required")

    def test_every_nonterminal_or_failed_status_revokes(self):
        first,_,_ = self.reconcile()
        for status in ("pending","retry","running","failed","ready","missing","unknown"):
            with self.subTest(status=status):
                self.sql("worker","UPDATE jobs SET status=?",(status,))
                result,_ = self.rejected_source("worker_not_terminal_no_speech")
                self.assertNotEqual(result["evidenceID"],first["evidenceID"])
        self.sql("worker","UPDATE jobs SET status='no_speech'")
        self.assertEqual(self.reconcile()[0]["evidenceID"],first["evidenceID"])
        self.sql("worker","DELETE FROM jobs")
        result,_ = self.rejected_source("worker_missing")
        self.assertEqual(result["withdrawnNoSpeechCount"],1)

    def test_terminal_status_requires_attempt_no_retry_and_no_error(self):
        for field,value,reset in (("attempts",0,1),("retry_at",123,0),("last_error","SYNTHETIC failure",None),("updated_at",-1,DAY_START+3000)):
            with self.subTest(field=field):
                self.sql("worker","UPDATE jobs SET "+field+"=?",(value,))
                self.rejected_source("worker_not_terminal_no_speech")
                self.sql("worker","UPDATE jobs SET "+field+"=?",(reset,))

    def test_worker_hash_must_match_exact_source(self):
        self.sql("worker","UPDATE jobs SET audio_hash=?",("d"*64,))
        self.rejected_source("worker_audio_identity_mismatch")

    def test_row_identity_and_manifest_identity_and_time_must_all_match(self):
        for field,value in (("session_id",str(uuid.uuid4())),("sequence",99),("started_at",DAY_START+999),("ended_at",DAY_START+1099)):
            with self.subTest(field=field):
                original = {"session_id":self.source["sessionID"],"sequence":7,"started_at":self.manifest["startedAt"],"ended_at":self.manifest["endedAt"]}[field]
                self.sql("library","UPDATE recordings SET "+field+"=?",(value,))
                self.rejected_source("source_identity_mismatch")
                self.sql("library","UPDATE recordings SET "+field+"=?",(original,))
        for field,value in (("sha256","d"*64),("sessionID",str(uuid.uuid4())),("sequence",8),("startedAt",DAY_START+999)):
            with self.subTest(manifest=field):
                altered = {**self.manifest,field:value}
                self.sql("library","UPDATE recordings SET manifest_json=?",(canonical_json(altered),))
                self.rejected_source("source_identity_mismatch")

    def test_recording_missing_or_invalid_manifest_never_qualifies(self):
        self.sql("library","UPDATE recordings SET manifest_json='{}'")
        self.rejected_source("invalid_source_manifest")
        self.sql("library","DELETE FROM recordings")
        self.rejected_source("recording_missing")

    def test_transcript_row_supersedes_worker_without_body_read(self):
        self.reconcile()
        self.sql("library","INSERT INTO transcripts VALUES(?,?,?)",(self.source["segmentID"],BODY,BODY))
        result,proof = self.rejected_source("transcript_supersedes_no_speech")
        self.assertEqual(result["withdrawnNoSpeechCount"],1)
        self.assertTrue(proof["transcriptRowPresent"])
        self.assertNotIn(BODY,"".join(p.read_text() for p in self.output.iterdir()))
        with evidence.readonly_database(self.db["library"],"library") as db:
            for column in ("transcript_json","search_text"):
                with self.assertRaises(sqlite3.DatabaseError): db.execute("SELECT "+column+" FROM transcripts").fetchall()
            with self.assertRaises(sqlite3.DatabaseError): db.execute("DELETE FROM transcripts")

    def test_library_v1_without_transcript_table_is_supported(self):
        self.sql("library","DROP TABLE transcripts"); self.sql("library","PRAGMA user_version=1")
        self.assertEqual(self.reconcile()[0]["verifiedNoSpeechCount"],1)

    def test_absent_pending_or_failed_receipt_does_not_authorize(self):
        for statement,args in (("UPDATE requests SET receipt_json=NULL",()),
                               ("UPDATE requests SET receipt_json=?,failure_json=?",(canonical_json(self.receipt),"SYNTHETIC failure"))):
            with self.subTest(statement=statement):
                self.sql("receiver",statement,args)
                self.rejected_source("durable_receipt_export_members_missing")

    def test_receipt_exact_identity_hash_and_member_schema(self):
        changes = [{"archiveSHA256":"d"*64},{"receiverID":str(uuid.uuid4())},{"deliveryID":str(uuid.uuid4())},
                   {"schemaVersion":True},{"storedAt":-1},{"recordingIDs":[]},
                   {"recordingIDs":[self.source["segmentID"]]*2},{"recordingIDs":[str(uuid.uuid4())]}]
        for change in changes:
            with self.subTest(change=change):
                self.receipt_change(**change)
                self.rejected_source("durable_receipt_export_members_missing")

    def test_export_id_must_be_bound_not_guessed_from_shared_members(self):
        self.sql("library","UPDATE exports SET id=?",(str(uuid.uuid4()),))
        self.rejected_source("durable_receipt_export_members_missing")

    def test_exact_full_export_members_not_subset_or_superset(self):
        extra = str(uuid.uuid4())
        self.sql("library","INSERT INTO export_members VALUES(?,?)",(self.delivery_id,extra))
        self.rejected_source("durable_receipt_export_members_missing")
        self.sql("library","DELETE FROM export_members WHERE recording_id=?",(extra,))
        self.receipt_change(recordingIDs=[self.source["segmentID"],extra])
        self.rejected_source("durable_receipt_export_members_missing")

    def test_worker_change_between_reads_defers_until_stable_recheck(self):
        self.reconcile()
        result,proof = self.rejected_source("metadata_changed_during_check",between_reads=lambda:self.sql("worker","UPDATE jobs SET status='retry'"))
        self.assertIn("worker_not_terminal_no_speech",proof["reasonCodes"])
        self.assertEqual(result["withdrawnNoSpeechCount"],1)

    def test_receipt_and_manifest_change_between_reads_are_not_certified(self):
        for kind,statement,args in (("receiver","DELETE FROM requests",()),
                                    ("library","UPDATE recordings SET manifest_json=?",(canonical_json({**self.manifest,"sha256":"e"*64}),))):
            with self.subTest(kind=kind):
                self.rejected_source("metadata_changed_during_check",between_reads=lambda:self.sql(kind,statement,args))

    def test_original_inventory_modification_during_check_rejected(self):
        with self.code("base_inventory_changed"):
            self.engine(between_reads=lambda:self.write_inventory({**self.inventory,"evidenceRef":"changed"})).reconcile(self.output)
        self.assertFalse((self.output/"latest.json").exists())

    def test_receiver_identity_and_library_binding_are_required(self):
        self.sql("receiver","UPDATE identity SET library=?",(str(self.root/"other-library"),))
        with self.code("receiver_library_mismatch"): self.reconcile()

    def test_foreign_or_unsupported_library_version_fails_closed(self):
        self.sql("library","PRAGMA user_version=99")
        with self.code("invalid_library_schema"): self.reconcile()

    def test_readonly_wal_and_sidecars_rejected_without_writing_source(self):
        sidecar = self.db["worker"].with_name("transcription.sqlite3-wal")
        sidecar.write_bytes(b"synthetic unfinished WAL"); sidecar.chmod(0o600)
        with self.code("wal_snapshot_not_supported"): self.reconcile()
        sidecar.unlink()
        self.sql("worker","PRAGMA journal_mode=WAL")
        with self.code("unsupported_sqlite_journal"): self.reconcile()

    def test_input_and_output_permissions_links_and_overlap_fail_closed(self):
        self.inventory_path.chmod(0o644)
        with self.code("unsafe_permissions"): self.engine()
        self.inventory_path.chmod(0o600)
        self.db["worker"].chmod(0o644)
        with self.code("unsafe_permissions"): self.reconcile()
        self.db["worker"].chmod(0o600)
        linked = self.root/"inventory-link.json"; linked.symlink_to(self.inventory_path)
        with self.code("unsafe_path"): evidence.ASREvidence(linked,self.library,self.receiver,self.asr)
        hard = self.root/"inventory-hard.json"; os.link(self.inventory_path,hard)
        with self.code("unsafe_permissions"): self.engine()
        hard.unlink()
        with self.code("overlapping_output"): self.engine().reconcile(self.receiver/"output")
        self.output.mkdir(mode=0o755,exist_ok=True); self.output.chmod(0o755)
        with self.code("unsafe_permissions"): self.reconcile()

    def test_original_is_only_base_and_candidate_cannot_be_reused(self):
        _,candidate,_ = self.reconcile(); self.write_inventory(candidate)
        with self.code("base_inventory_must_require_transcripts"): self.engine()

    def test_new_base_cannot_reuse_existing_evidence_directory(self):
        self.reconcile(); self.inventory["evidenceRef"] = "SYNTHETIC second base"; self.write_inventory(self.inventory)
        with self.code("evidence_binding_changed"): self.reconcile()

    def test_existing_source_proof_and_open_or_untrusted_status_not_upgraded(self):
        self.inventory.update(evidenceKind="operator_declared",dayClosed=False)
        self.write_inventory(self.inventory)
        _,candidate,_ = self.reconcile()
        self.assertFalse(candidate["dayClosed"])
        self.assertEqual(candidate["evidenceKind"],"operator_declared")
        self.assertEqual(candidate["evidenceRef"],self.inventory["evidenceRef"])
        self.assertEqual(candidate["sources"][0]["source"],self.source)

    def test_closed_day_overlap_and_unique_identity_validation(self):
        for mutate in (lambda x:x["sources"].append(copy.deepcopy(x["sources"][0])),
                       lambda x:x["sources"][0].update(startedAt=DAY_START-20,endedAt=DAY_START),
                       lambda x:x["sources"][0]["source"].update(sequence=True)):
            invalid = copy.deepcopy(self.inventory); mutate(invalid); self.write_inventory(invalid)
            with self.code("invalid_inventory"): self.engine()

    def test_cli_reports_counts_only_and_errors_redact_paths_or_private_text(self):
        arguments = [sys.executable,str(Path(evidence.__file__).resolve()),"reconcile","--inventory",str(self.inventory_path),
                     "--library",str(self.library),"--receiver-state",str(self.receiver),"--asr-state",str(self.asr),
                     "--output-dir",str(self.output)]
        run = subprocess.run(arguments,text=True,capture_output=True,check=False)
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertEqual(json.loads(run.stdout)["verifiedNoSpeechCount"],1)
        self.assertNotIn(self.source["segmentID"],run.stdout)
        self.assertNotIn(self.receiver_id,run.stdout)
        self.assertNotIn(BODY,run.stdout+run.stderr)
        self.db["worker"].unlink()
        failed = subprocess.run(arguments,text=True,capture_output=True,check=False)
        self.assertEqual(failed.returncode,1)
        self.assertEqual(json.loads(failed.stderr),{"error":{"code":"asr_metadata_unavailable"}})
        self.assertNotIn(str(self.root),failed.stderr)


if __name__ == "__main__": unittest.main()
