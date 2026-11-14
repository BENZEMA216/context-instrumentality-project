"""Synthetic cloud outbox tests; no accounts, network calls, or real recordings."""

import builtins
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock
import uuid

from test_bridge import segment, write_package
from test_transcripts import transcript_for, version2
from cloud_delivery import CloudDelivery
from library import BridgeError, DB_NAME, Library, import_package


BASE_MS = 1_700_000_000_000
PRIVATE_TEXT = "SYNTHETIC-PRIVATE-4826：封面改成蓝色，先等待确认。"


class CloudDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        # macOS's default /var temp prefix is itself an alias of /private/var.
        self.root = Path(self.temporary.name).resolve()
        self.catalog = self.root / "library"
        self.state = self.root / "cloud-state"
        # A real imported schema, populated exclusively with generated fixtures.
        self.seed = segment(0)
        self.import_items([self.seed])

    def tearDown(self):
        self.temporary.cleanup()

    def import_items(self, items):
        package = self.root / (str(uuid.uuid4()) + ".zip")
        write_package(package, items, version2(items))
        return import_package(package, self.catalog)

    def ready(self, sequence=1, text=PRIVATE_TEXT):
        item = segment(sequence)
        item[0]["transcript"] = transcript_for(item[0], text)
        return item

    def initialize(self, scope="all", since_ms=None):
        return CloudDelivery.initialize(
            self.state, self.catalog,
            destination_account="owner@example.test",
            email="instinct@example.test",
            folder_id="synthetic-folder",
            scope=scope, since_ms=since_ms,
        )

    def planned(self):
        self.import_items([self.ready()])
        queue = self.initialize()
        planned = queue.plan()
        self.assertEqual(len(planned["createdBatches"]), 1)
        batch_id = planned["createdBatches"][0]["batchID"]
        self.assertEqual(queue.payload(batch_id)["state"], "pending")
        return queue, batch_id

    def batch_status(self, queue, batch_id):
        return next(row for row in queue.status(history=True)["batches"] if row["batchID"] == batch_id)

    def record(self, queue, batch_id, operation, expected_state, **fields):
        return queue.record(
            batch_id, operation, expected_state,
            attempt_id=self.batch_status(queue, batch_id)["attemptID"], **fields,
        )

    def fail(self, queue, batch_id, expected_state, error):
        return queue.fail(
            batch_id, expected_state, error,
            attempt_id=self.batch_status(queue, batch_id)["attemptID"],
        )

    def resolve(self, queue, batch_id, expected_state, action, evidence):
        return queue.resolve(
            batch_id, expected_state, action, evidence,
            attempt_id=self.batch_status(queue, batch_id)["attemptID"],
        )

    def create_document(self, queue, batch_id):
        attempt = queue.begin(batch_id, "create-doc", "pending")["attemptID"]
        self.record(
            queue, batch_id, "doc", "doc_creating",
            id="synthetic-doc-1",
            url="https://docs.google.com/document/d/synthetic-doc-1/edit",
        )
        self.assertEqual(self.batch_status(queue, batch_id)["attemptID"], attempt)
        return attempt

    def verify_document(self, queue, batch_id):
        attempt = self.create_document(queue, batch_id)
        self.record(
            queue, batch_id, "verify-doc", "doc_created",
            sha256=queue.payload(batch_id)["document"]["sha256"],
        )
        self.assertEqual(self.batch_status(queue, batch_id)["attemptID"], attempt)
        return attempt

    def create_draft(self, queue, batch_id):
        prior_attempt = self.verify_document(queue, batch_id)
        attempt = queue.begin(batch_id, "create-mail", "doc_verified")["attemptID"]
        self.assertNotEqual(attempt, prior_attempt)
        self.record(queue, batch_id, "draft", "mail_creating", id="synthetic-draft-1")
        self.assertEqual(self.batch_status(queue, batch_id)["attemptID"], attempt)
        return attempt

    def test_plan_is_idempotent_across_restart_and_reimport(self):
        item = self.ready()
        self.import_items([item])
        queue = self.initialize()
        planned = queue.plan()["createdBatches"]
        self.assertEqual(len(planned), 1)
        batch_id = planned[0]["batchID"]
        original = queue.payload(batch_id)
        self.assertEqual(queue.plan()["createdBatches"], [])
        self.import_items([item])
        reopened = CloudDelivery(self.state)
        self.assertEqual(reopened.plan()["createdBatches"], [])
        self.assertEqual(reopened.payload(batch_id), original)
        self.assertEqual(len(reopened.status()["batches"]), 1)

    def test_persistence_failure_rolls_back_entire_plan_without_losing_items(self):
        items = [self.ready(index + 1, "ROLLBACK-FIXTURE-%02d" % index) for index in range(21)]
        self.import_items(items)
        queue = self.initialize()
        original_save = queue._save_batch
        saved_batches = []

        def interrupted_save(connection, entries):
            result = original_save(connection, entries)
            saved_batches.append(result["batchID"])
            if len(saved_batches) == 2:
                # Both batches and their items have been inserted in the transaction.
                raise sqlite3.OperationalError("synthetic_storage_interruption")
            return result

        with mock.patch.object(queue, "_save_batch", side_effect=interrupted_save):
            with self.assertRaises(sqlite3.OperationalError):
                queue.plan(max_batches=10)
        self.assertEqual(len(saved_batches), 2)
        self.assertEqual(queue.status()["batches"], [])
        reopened = CloudDelivery(self.state)
        self.assertEqual(reopened.status()["batches"], [])
        result = reopened.plan(max_batches=10)
        self.assertEqual(len(result["createdBatches"]), 2)
        payloads = [reopened.payload(row["batchID"]) for row in result["createdBatches"]]
        identifiers = [
            member["recordingID"] for payload in payloads for member in payload["members"]
        ]
        self.assertEqual(len(identifiers), 21)
        self.assertEqual(set(identifiers), {item[0]["manifest"]["id"] for item in items})
        self.assertEqual(reopened.plan()["createdBatches"], [])

    def test_future_scope_includes_cutoff_and_late_transcript_but_not_history(self):
        old_ready = self.ready(1, "HISTORICAL-READY-TEXT")
        old_late = segment(2)
        at_cutoff = self.ready(3, "BOUNDARY-READY-TEXT")
        future_late = segment(4)
        self.import_items([old_ready, old_late, at_cutoff, future_late])
        queue = self.initialize(scope="future", since_ms=BASE_MS + 3000)
        first = queue.plan()["createdBatches"]
        self.assertEqual(len(first), 1)
        first_ids = {
            row["recordingID"] for row in queue.payload(first[0]["batchID"])["members"]
        }
        self.assertEqual(first_ids, {at_cutoff[0]["manifest"]["id"]})
        for item in (old_late, future_late):
            item[0]["transcript"] = transcript_for(item[0], "LATE-READY-TEXT")
        self.import_items([old_late, future_late])
        reopened = CloudDelivery(self.state)
        second = reopened.plan()["createdBatches"]
        self.assertEqual(len(second), 1)
        second_ids = {
            row["recordingID"] for row in reopened.payload(second[0]["batchID"])["members"]
        }
        self.assertEqual(second_ids, {future_late[0]["manifest"]["id"]})
        self.assertEqual(reopened.plan()["createdBatches"], [])

    def test_all_scope_includes_ready_history(self):
        item = self.ready(1, "EXPLICIT-HISTORY-TEXT")
        self.import_items([item])
        queue = self.initialize(scope="all")
        planned = queue.plan()["createdBatches"]
        self.assertEqual(len(planned), 1)
        self.assertIn(
            "EXPLICIT-HISTORY-TEXT",
            queue.payload(planned[0]["batchID"])["document"]["text"],
        )

    def test_corrupt_candidate_does_not_starve_later_valid_recording(self):
        broken, healthy = self.ready(1), self.ready(2, "HEALTHY-SYNTHETIC-TEXT")
        self.import_items([broken, healthy])
        with sqlite3.connect(self.catalog / DB_NAME) as connection:
            connection.execute(
                "UPDATE transcripts SET transcript_json=? WHERE recording_id=?",
                ('{"schemaVersion":1,"text":"BROKEN"}', broken[0]["manifest"]["id"]),
            )
        queue = self.initialize()
        result = queue.plan()
        self.assertGreaterEqual(sum(result["skipped"].values()), 1)
        self.assertEqual(len(result["createdBatches"]), 1)
        payload = queue.payload(result["createdBatches"][0]["batchID"])
        self.assertEqual(
            {row["recordingID"] for row in payload["members"]},
            {healthy[0]["manifest"]["id"]},
        )
        self.assertIn("HEALTHY-SYNTHETIC-TEXT", payload["document"]["text"])
        self.assertNotIn("BROKEN", payload["document"]["text"])

    def test_twenty_one_ready_recordings_are_split_without_loss_or_duplicates(self):
        items = [self.ready(index + 1, "BATCH-FIXTURE-%02d" % index) for index in range(21)]
        self.import_items(items)
        queue = self.initialize()
        result = queue.plan(max_batches=10)
        self.assertEqual(len(result["createdBatches"]), 2)
        payloads = [queue.payload(row["batchID"]) for row in result["createdBatches"]]
        self.assertEqual(sorted(len(payload["members"]) for payload in payloads), [1, 20])
        identifiers = [
            member["recordingID"] for payload in payloads for member in payload["members"]
        ]
        self.assertEqual(len(identifiers), len(set(identifiers)))
        self.assertEqual(set(identifiers), {item[0]["manifest"]["id"] for item in items})
        self.assertEqual(CloudDelivery(self.state).plan()["createdBatches"], [])

    def test_max_batches_leaves_remaining_work_for_next_plan(self):
        self.import_items([self.ready(index + 1) for index in range(21)])
        queue = self.initialize()
        first = queue.plan(max_batches=1)["createdBatches"]
        second = CloudDelivery(self.state).plan(max_batches=1)["createdBatches"]
        self.assertEqual((len(first), len(second)), (1, 1))
        self.assertNotEqual(first[0]["batchID"], second[0]["batchID"])
        self.assertEqual(queue.plan(max_batches=1)["createdBatches"], [])

    def test_large_legal_transcript_gets_its_own_oversized_batch(self):
        large_text = "LARGE-SYNTHETIC-" + "x" * (220 * 1024)
        oversized = self.ready(2, large_text)
        oversized[0]["transcript"]["spans"] = []
        small_before = self.ready(1, "SMALL-BEFORE")
        small_after = self.ready(3, "SMALL-AFTER")
        self.import_items([small_before, oversized, small_after])
        queue = self.initialize()
        result = queue.plan(max_batches=10)
        payloads = [queue.payload(row["batchID"]) for row in result["createdBatches"]]
        large_payload = next(
            payload for payload in payloads
            if any(row["recordingID"] == oversized[0]["manifest"]["id"]
                   for row in payload["members"])
        )
        self.assertEqual(len(large_payload["members"]), 1)
        self.assertTrue(large_payload["oversized"])
        self.assertIn(large_text, large_payload["document"]["text"])
        self.assertLessEqual(len(large_payload["document"]["text"].encode("utf-8")), 300 * 1024)
        identifiers = [row["recordingID"] for payload in payloads for row in payload["members"]]
        self.assertEqual(len(identifiers), 3)
        self.assertEqual(
            set(identifiers),
            {item[0]["manifest"]["id"] for item in (small_before, oversized, small_after)},
        )
        self.assertEqual(CloudDelivery(self.state).plan()["createdBatches"], [])

    def test_document_verification_code_is_unique_frozen_and_absent_from_mail(self):
        items = [self.ready(index + 1) for index in range(21)]
        self.import_items(items)
        queue = self.initialize()
        batches = queue.plan()["createdBatches"]
        self.assertEqual(len(batches), 2)
        codes = []
        for batch in batches:
            payload = queue.payload(batch["batchID"])
            code = payload["document"]["verificationCode"]
            self.assertIsInstance(code, str)
            self.assertTrue(code.strip())
            self.assertNotEqual(code, batch["batchID"])
            self.assertIn(code, payload["document"]["text"])
            self.assertNotIn(code, json.dumps(payload["mail"], ensure_ascii=False))
            self.assertNotIn(PRIVATE_TEXT, json.dumps(payload["mail"], ensure_ascii=False))
            self.assertEqual(
                CloudDelivery(self.state).payload(batch["batchID"])["document"]["verificationCode"],
                code,
            )
            codes.append(code)
        self.assertEqual(len(set(codes)), 2)

    def test_payload_preserves_source_identity_without_location_or_audio_access(self):
        item = self.ready()
        manifest = item[0]["manifest"]
        manifest["timeZoneIdentifier"] = "Asia/Shanghai"
        manifest["location"] = {
            "latitude": 31.2304, "longitude": 121.4737,
            "horizontalAccuracy": 12.0, "capturedAt": manifest["startedAt"],
        }
        self.import_items([item])
        original_open, original_path_open = builtins.open, Path.open

        def guarded_open(file, *args, **kwargs):
            if isinstance(file, (str, Path)) and str(file).endswith(".caf"):
                raise AssertionError("Text delivery must not read original audio")
            return original_open(file, *args, **kwargs)

        def guarded_path_open(path, *args, **kwargs):
            if path.suffix == ".caf":
                raise AssertionError("Text delivery must not read original audio")
            return original_path_open(path, *args, **kwargs)

        with mock.patch("builtins.open", side_effect=guarded_open), \
                mock.patch.object(Path, "open", guarded_path_open), \
                mock.patch.object(Library, "get_audio_asset", side_effect=AssertionError("No audio API")):
            queue = self.initialize()
            batch_id = queue.plan()["createdBatches"][0]["batchID"]
            payload = queue.payload(batch_id)
            status = queue.status()
        text = payload["document"]["text"]
        self.assertIn(PRIVATE_TEXT, text)
        self.assertIn(manifest["id"], text)
        self.assertIn(manifest["sessionID"], text)
        self.assertIn(manifest["sha256"], text)
        self.assertIn("Asia/Shanghai", text)
        self.assertEqual(
            payload["document"]["sha256"], hashlib.sha256(text.encode("utf-8")).hexdigest()
        )
        self.assertEqual(payload["document"]["mimeType"], "application/vnd.google-apps.document")
        serialized = json.dumps(payload, ensure_ascii=False)
        for forbidden in ("latitude", "longitude", "31.2304", "121.4737", ".caf", str(self.catalog)):
            self.assertNotIn(forbidden, serialized)
        self.assertNotIn("location", json.dumps(payload["members"]))
        self.assertNotIn(PRIVATE_TEXT, json.dumps(status, ensure_ascii=False))
        self.assertEqual(payload["mail"]["to"], "instinct@example.test")

    def test_successful_state_machine_retains_remote_identifiers_after_restart(self):
        queue, batch_id = self.planned()
        prior_attempt = self.create_draft(queue, batch_id)
        attempt = queue.begin(batch_id, "send-mail", "mail_drafted")["attemptID"]
        self.assertNotEqual(attempt, prior_attempt)
        self.record(
            queue, batch_id, "sent", "mail_sending",
            id="synthetic-message-1", thread_id="synthetic-thread-1",
        )
        reopened = CloudDelivery(self.state)
        row = self.batch_status(reopened, batch_id)
        self.assertEqual(row["state"], "notified")
        self.assertEqual(row["attemptID"], attempt)
        self.assertEqual(row["docID"], "synthetic-doc-1")
        self.assertEqual(row["draftID"], "synthetic-draft-1")
        self.assertEqual(row["messageID"], "synthetic-message-1")
        self.assertEqual(row["threadID"], "synthetic-thread-1")
        self.assertEqual(reopened.plan()["createdBatches"], [])

    def test_failed_document_verification_cannot_advance_or_discard_document(self):
        queue, batch_id = self.planned()
        self.create_document(queue, batch_id)
        with self.assertRaises(BridgeError):
            self.record(queue, batch_id, "verify-doc", "doc_created", sha256="0" * 64)
        self.fail(queue, batch_id, "doc_created", "synthetic_readback_hash_mismatch")
        row = self.batch_status(CloudDelivery(self.state), batch_id)
        self.assertEqual(row["state"], "doc_created")
        self.assertEqual(row["docID"], "synthetic-doc-1")
        self.assertEqual(row["docURL"], "https://docs.google.com/document/d/synthetic-doc-1/edit")

    def test_read_confirmation_requires_exact_document_code_count_and_thread(self):
        queue, batch_id = self.planned()
        self.create_draft(queue, batch_id)
        attempt = queue.begin(batch_id, "send-mail", "mail_drafted")["attemptID"]
        self.record(
            queue, batch_id, "sent", "mail_sending",
            id="synthetic-message-1", thread_id="synthetic-thread-1",
        )
        self.assertEqual(self.batch_status(queue, batch_id)["attemptID"], attempt)
        payload = queue.payload(batch_id)
        correct = {
            "reply_id": "synthetic-reply-1",
            "thread_id": "synthetic-thread-1",
            "verification_code": payload["document"]["verificationCode"],
            "recording_count": len(payload["members"]),
        }
        for field, wrong in (
            ("verification_code", "WRONG-SYNTHETIC-CODE"),
            ("recording_count", len(payload["members"]) + 1),
            ("thread_id", "other-synthetic-thread"),
        ):
            with self.subTest(field=field):
                values = dict(correct, **{field: wrong})
                with self.assertRaises(BridgeError):
                    self.record(queue, batch_id, "read", "notified", **values)
                self.assertEqual(queue.payload(batch_id)["state"], "notified")
        self.record(queue, batch_id, "read", "notified", **correct)
        reopened = CloudDelivery(self.state)
        self.assertEqual(reopened.payload(batch_id)["state"], "read_confirmed")
        self.assertEqual(self.batch_status(reopened, batch_id)["attemptID"], attempt)
        self.assertEqual(reopened.plan()["createdBatches"], [])

    def test_mail_failures_preserve_verified_document_and_draft(self):
        queue, batch_id = self.planned()
        self.create_draft(queue, batch_id)
        queue.begin(batch_id, "send-mail", "mail_drafted")
        self.fail(queue, batch_id, "mail_sending", "synthetic_timeout_after_send")
        reopened = CloudDelivery(self.state)
        row = self.batch_status(reopened, batch_id)
        self.assertEqual(row["state"], "mail_sending")
        self.assertEqual(row["docID"], "synthetic-doc-1")
        self.assertEqual(row["draftID"], "synthetic-draft-1")
        self.assertEqual(reopened.plan()["createdBatches"], [])
        with self.assertRaises(BridgeError):
            reopened.begin(batch_id, "send-mail", "mail_drafted")

    def test_uncertain_operations_never_auto_reset_or_repeat(self):
        for operation, initial, inflight in (
            ("create-doc", "pending", "doc_creating"),
            ("create-mail", "doc_verified", "mail_creating"),
            ("send-email", "doc_verified", "mail_sending"),
            ("send-mail", "mail_drafted", "mail_sending"),
        ):
            with self.subTest(operation=operation):
                # Keep each scenario in its own durable outbox.
                self.state = self.root / ("state-" + operation)
                queue, batch_id = self.planned()
                if operation in ("create-mail", "send-email"):
                    self.verify_document(queue, batch_id)
                elif operation == "send-mail":
                    self.create_draft(queue, batch_id)
                queue.begin(batch_id, operation, initial)
                self.fail(queue, batch_id, inflight, "synthetic_ambiguous_transport")
                reopened = CloudDelivery(self.state)
                self.assertEqual(reopened.plan()["createdBatches"], [])
                self.assertEqual(reopened.payload(batch_id)["state"], inflight)
                with self.assertRaises(BridgeError):
                    reopened.begin(batch_id, operation, initial)
                with self.assertRaises(BridgeError):
                    self.resolve(reopened, batch_id, inflight, "retry-confirmed-absent", "")
                self.assertEqual(reopened.payload(batch_id)["state"], inflight)
                self.resolve(
                    reopened, batch_id, inflight, "retry-confirmed-absent",
                    "Synthetic provider definitively rejected the request before committing any side effect.",
                )
                self.assertEqual(reopened.payload(batch_id)["state"], initial)
                reopened.begin(batch_id, operation, initial)
                self.assertEqual(reopened.payload(batch_id)["state"], inflight)

    def test_stale_compare_and_swap_cannot_claim_or_overwrite_state(self):
        queue, batch_id = self.planned()
        contender = CloudDelivery(self.state)
        queue.begin(batch_id, "create-doc", "pending")
        with self.assertRaises(BridgeError):
            contender.begin(batch_id, "create-doc", "pending")
        with self.assertRaises(BridgeError):
            self.fail(contender, batch_id, "pending", "synthetic_stale_worker")
        with self.assertRaises(BridgeError):
            self.record(
                contender, batch_id, "doc", "pending",
                id="wrong-doc", url="https://docs.google.com/document/d/wrong-doc/edit",
            )
        self.assertEqual(queue.payload(batch_id)["state"], "doc_creating")
        self.record(
            queue, batch_id, "doc", "doc_creating",
            id="synthetic-doc-1", url="https://docs.google.com/document/d/synthetic-doc-1/edit",
        )
        with self.assertRaises(BridgeError):
            self.record(
                contender, batch_id, "doc", "doc_creating",
                id="wrong-doc", url="https://docs.google.com/document/d/wrong-doc/edit",
            )
        self.assertEqual(self.batch_status(queue, batch_id)["docID"], "synthetic-doc-1")

    def test_old_attempt_cannot_mutate_retried_operation_after_aba(self):
        queue, batch_id = self.planned()
        stale_worker = CloudDelivery(self.state)
        attempt_a = queue.begin(batch_id, "create-doc", "pending")["attemptID"]
        self.assertEqual(str(uuid.UUID(attempt_a)), attempt_a)
        queue.resolve(
            batch_id, "doc_creating", "retry-confirmed-absent",
            "Synthetic provider definitively rejected attempt A before creating a document.",
            attempt_id=attempt_a,
        )
        self.assertIsNone(self.batch_status(queue, batch_id)["attemptID"])
        attempt_b = queue.begin(batch_id, "create-doc", "pending")["attemptID"]
        self.assertEqual(str(uuid.UUID(attempt_b)), attempt_b)
        self.assertNotEqual(attempt_a, attempt_b)
        baseline = self.batch_status(queue, batch_id)
        for operation in ("record", "fail", "resolve"):
            with self.subTest(operation=operation):
                with self.assertRaises(BridgeError):
                    if operation == "record":
                        stale_worker.record(
                            batch_id, "doc", "doc_creating", attempt_id=attempt_a,
                            id="stale-doc", url="https://docs.google.com/document/d/stale-doc/edit",
                        )
                    elif operation == "fail":
                        stale_worker.fail(
                            batch_id, "doc_creating", "synthetic_stale_failure",
                            attempt_id=attempt_a,
                        )
                    else:
                        stale_worker.resolve(
                            batch_id, "doc_creating", "retry-confirmed-absent",
                            "Synthetic stale reconciliation for attempt A.",
                            attempt_id=attempt_a,
                        )
                self.assertEqual(self.batch_status(queue, batch_id), baseline)
        queue.record(
            batch_id, "doc", "doc_creating", attempt_id=attempt_b,
            id="synthetic-doc-1", url="https://docs.google.com/document/d/synthetic-doc-1/edit",
        )
        row = self.batch_status(CloudDelivery(self.state), batch_id)
        self.assertEqual(row["state"], "doc_created")
        self.assertEqual(row["attemptID"], attempt_b)
        self.assertEqual(row["docID"], "synthetic-doc-1")

    def test_reopened_configuration_is_validated_without_expanding_scope(self):
        queue = self.initialize(scope="future", since_ms=BASE_MS)
        original = dict(queue.configuration)
        for changes in (
            {"scope": "futrue"},
            {"scope": "future", "sinceMS": None},
            {"scope": "future", "sinceMS": True},
            {"scope": "all", "sinceMS": BASE_MS},
            {"email": "first@example.test,second@example.test"},
            {"folderID": "../other-folder"},
            {"library": str(self.root / "missing-library")},
        ):
            with self.subTest(changes=changes):
                with sqlite3.connect(queue.database) as connection:
                    connection.execute(
                        "UPDATE configuration SET value=? WHERE singleton=1",
                        (json.dumps(dict(original, **changes)),),
                    )
                with self.assertRaises(BridgeError):
                    CloudDelivery(self.state)
        with sqlite3.connect(queue.database) as connection:
            connection.execute(
                "UPDATE configuration SET value=? WHERE singleton=1",
                (json.dumps(original),),
            )
        self.assertEqual(CloudDelivery(self.state).configuration, original)

    def test_mail_is_frozen_after_document_identity_is_recorded(self):
        queue, batch_id = self.planned()
        self.create_document(queue, batch_id)
        original = queue.payload(batch_id)["mail"]
        self.assertIn("https://docs.google.com/document/d/synthetic-doc-1/edit", original["body"])
        self.assertNotIn(queue.payload(batch_id)["document"]["verificationCode"], original["body"])
        with mock.patch.object(CloudDelivery, "_mail_body", return_value="A future template must not replace this mail"):
            self.assertEqual(CloudDelivery(self.state).payload(batch_id)["mail"], original)

    def test_direct_send_has_separate_sent_and_read_proof_and_bounded_history(self):
        queue, batch_id = self.planned()
        self.verify_document(queue, batch_id)
        attempt = queue.begin(batch_id, "send-email", "doc_verified")["attemptID"]
        self.assertIsNone(queue.payload(batch_id)["mail"]["draftID"])
        self.record(queue, batch_id, "sent", "mail_sending",
                    id="direct-message", thread_id="direct-thread")
        self.assertEqual(queue.status(limit=1)["batches"][0]["state"], "notified")
        payload = queue.payload(batch_id)
        self.record(queue, batch_id, "read", "notified", reply_id="direct-reply",
                    thread_id="direct-thread", verification_code=payload["document"]["verificationCode"],
                    recording_count=len(payload["members"]))
        self.assertEqual(queue.status()["batches"], [])
        historical = queue.status(history=True, limit=1)
        self.assertEqual(historical["batches"][0]["state"], "read_confirmed")
        self.assertEqual(historical["batches"][0]["attemptID"], attempt)
        self.assertEqual(historical["counts"]["read_confirmed"], 1)
        with self.assertRaises(BridgeError):
            queue.status(limit=0)
        with self.assertRaises(BridgeError):
            queue.status(limit=1001)

    def test_status_limit_reports_more_without_document_content(self):
        self.import_items([self.ready(index + 1) for index in range(21)])
        queue = self.initialize()
        queue.plan()
        result = queue.status(limit=1)
        self.assertEqual(len(result["batches"]), 1)
        self.assertTrue(result["hasMore"])
        self.assertEqual(result["counts"]["pending"], 2)
        self.assertNotIn(PRIVATE_TEXT, json.dumps(result, ensure_ascii=False))

    def test_returned_mail_id_survives_readback_failure_without_marking_sent(self):
        queue, batch_id = self.planned()
        self.verify_document(queue, batch_id)
        attempt = queue.begin(batch_id, "send-email", "doc_verified")["attemptID"]
        returned = queue.record(batch_id, "mail-returned", "mail_sending",
                                attempt_id=attempt, id="returned-message")
        self.assertEqual(returned["state"], "mail_sending")
        self.assertEqual(returned["messageID"], "returned-message")
        self.assertIsNone(returned["threadID"])
        self.assertEqual(queue.record(batch_id, "mail-returned", "mail_sending",
                                     attempt_id=attempt, id="returned-message"), returned)
        queue.fail(batch_id, "mail_sending", "synthetic_readback_unavailable", attempt_id=attempt)
        reopened = CloudDelivery(self.state)
        row = self.batch_status(reopened, batch_id)
        self.assertEqual((row["state"], row["messageID"]), ("mail_sending", "returned-message"))
        self.assertEqual(row["error"], "synthetic_readback_unavailable")
        self.assertEqual(reopened.plan()["createdBatches"], [])
        with self.assertRaises(BridgeError):
            reopened.resolve(batch_id, "mail_sending", "retry-confirmed-absent",
                             "The message has not appeared in a search yet.", attempt_id=attempt)
        # A later response can enrich the known result, never replace its identity.
        reopened.record(batch_id, "mail-returned", "mail_sending", attempt_id=attempt,
                        id="returned-message", thread_id="returned-thread")
        reopened.record(batch_id, "sent", "mail_sending", attempt_id=attempt,
                        id="returned-message", thread_id="returned-thread")
        self.assertEqual(reopened.payload(batch_id)["state"], "notified")
        with sqlite3.connect(reopened.database) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 3)

    def test_returned_mail_identity_cannot_be_overwritten_by_conflicting_results(self):
        queue, batch_id = self.planned()
        self.verify_document(queue, batch_id)
        attempt = queue.begin(batch_id, "send-email", "doc_verified")["attemptID"]
        queue.record(batch_id, "mail-returned", "mail_sending", attempt_id=attempt,
                     id="returned-message", thread_id="returned-thread")
        baseline = self.batch_status(queue, batch_id)
        for operation in ("mail-returned", "sent"):
            for values in ({"id": "other-message", "thread_id": "returned-thread"},
                           {"id": "returned-message", "thread_id": "other-thread"}):
                with self.subTest(operation=operation, values=values):
                    with self.assertRaises(BridgeError):
                        queue.record(batch_id, operation, "mail_sending", attempt_id=attempt, **values)
                    self.assertEqual(self.batch_status(queue, batch_id), baseline)

    def test_late_returned_message_from_old_attempt_is_rejected(self):
        queue, batch_id = self.planned()
        self.verify_document(queue, batch_id)
        attempt_a = queue.begin(batch_id, "send-email", "doc_verified")["attemptID"]
        queue.resolve(batch_id, "mail_sending", "retry-confirmed-absent",
                      "Synthetic provider rejected request before sending.", attempt_id=attempt_a)
        attempt_b = queue.begin(batch_id, "send-email", "doc_verified")["attemptID"]
        baseline = self.batch_status(queue, batch_id)
        with self.assertRaises(BridgeError):
            queue.record(batch_id, "mail-returned", "mail_sending", attempt_id=attempt_a, id="stale-message")
        self.assertEqual(self.batch_status(queue, batch_id), baseline)
        queue.record(batch_id, "mail-returned", "mail_sending", attempt_id=attempt_b, id="fresh-message")
        self.assertEqual(self.batch_status(queue, batch_id)["messageID"], "fresh-message")

    def test_reply_backlog_does_not_consume_delivery_listing_limit(self):
        self.import_items([self.ready(index + 1) for index in range(21)])
        queue = self.initialize()
        batches = queue.plan()["createdBatches"]
        first, second = [batch["batchID"] for batch in batches]
        self.verify_document(queue, first)
        attempt = queue.begin(first, "send-email", "doc_verified")["attemptID"]
        queue.record(first, "sent", "mail_sending", attempt_id=attempt,
                     id="sent-message", thread_id="sent-thread")
        delivery = queue.status(limit=1, phase="delivery")
        replies = queue.status(limit=1, phase="replies")
        self.assertEqual([row["batchID"] for row in delivery["batches"]], [second])
        self.assertEqual([row["batchID"] for row in replies["batches"]], [first])
        self.assertEqual(delivery["counts"]["notified"], 1)
        self.assertNotIn(PRIVATE_TEXT, json.dumps(delivery, ensure_ascii=False))
        with self.assertRaises(BridgeError):
            queue.status(phase="delivery", history=True)

    def test_reply_checks_rotate_durably_without_changing_sent_proof(self):
        self.import_items([self.ready(index + 1) for index in range(41)])
        queue = self.initialize()
        batches = queue.plan()["createdBatches"]
        for batch in batches:
            batch_id = batch["batchID"]
            self.verify_document(queue, batch_id)
            attempt = queue.begin(batch_id, "send-email", "doc_verified")["attemptID"]
            queue.record(batch_id, "sent", "mail_sending", attempt_id=attempt,
                         id="message-" + batch_id, thread_id="thread-" + batch_id)
        order = []
        for outcome in ("no_reply", "unavailable", "unmatched"):
            reopened = CloudDelivery(self.state)
            batch = reopened.status(phase="replies", limit=1)["batches"][0]
            order.append(batch["batchID"])
            result = reopened.record(batch["batchID"], "reply-checked", "notified",
                                     attempt_id=batch["attemptID"], outcome=outcome)
            for key in ("state", "messageID", "threadID", "docID", "attemptID"):
                self.assertEqual(result[key], batch[key])
        self.assertEqual(len(set(order)), 3)
        first_again = CloudDelivery(self.state).status(phase="replies", limit=1)["batches"][0]
        self.assertEqual(first_again["batchID"], order[0])
        self.assertEqual(queue.status(phase="delivery")["batches"], [])
        with self.assertRaises(BridgeError):
            queue.record(first_again["batchID"], "reply-checked", "notified",
                         attempt_id=str(uuid.uuid4()), outcome="no_reply")
        with self.assertRaises(BridgeError):
            queue.record(first_again["batchID"], "reply-checked", "notified",
                         attempt_id=first_again["attemptID"], outcome="Arbitrary message text is forbidden")

    def test_opening_missing_state_does_not_initialize_it(self):
        with self.assertRaises(BridgeError):
            CloudDelivery(self.state)
        self.assertFalse(self.state.exists())

    def test_symlink_state_and_library_are_rejected(self):
        queue, batch_id = self.planned()
        alias = self.root / "state-alias"
        alias.symlink_to(self.state, target_is_directory=True)
        with self.assertRaises(BridgeError):
            CloudDelivery(alias)
        library_alias = self.root / "library-alias"
        library_alias.symlink_to(self.catalog, target_is_directory=True)
        with self.assertRaises(BridgeError):
            CloudDelivery.initialize(
                self.root / "other-state", library_alias,
                destination_account="owner@example.test",
                email="instinct@example.test", folder_id="synthetic-folder",
                scope="all",
            )
        self.assertEqual(queue.payload(batch_id)["state"], "pending")


if __name__ == "__main__":
    unittest.main()
