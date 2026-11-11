"""Private TLS pairing setup must survive repeats and reject partial identity files."""
import hashlib
import json
from pathlib import Path
import ssl
import tempfile
import unittest

from test_bridge import segment  # Adds the bridge module directory for discovery.
from library import BridgeError
from setup_receiver import prepare


class ReceiverSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "receiver"
        self.endpoint = "https://paired-receiver.local:8766"

    def tearDown(self):
        self.temporary.cleanup()

    def test_real_certificate_key_pin_and_idempotent_setup(self):
        result = prepare(self.root, self.endpoint, ["127.0.0.1"])
        before = {path.name: path.read_bytes() for path in self.root.iterdir() if path.is_file()}
        payload = json.loads(before["pairing.json"])
        self.assertEqual(len(payload["token"]), 43)
        self.assertNotIn(payload["token"], json.dumps(result))
        self.assertEqual(payload["certificateSHA256"], hashlib.sha256(ssl.PEM_cert_to_DER_cert(before["receiver.crt"].decode())).hexdigest())
        self.assertEqual(prepare(self.root, self.endpoint)["status"], "existing")
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.root.iterdir() if path.is_file()})
        for path in self.root.iterdir():
            self.assertEqual(path.stat().st_mode & 0o077, 0)

    def test_empty_private_key_from_interrupted_setup_is_rejected_without_replacement(self):
        prepare(self.root, self.endpoint)
        key = self.root / "receiver.key"
        key.write_bytes(b"")
        with self.assertRaises(BridgeError) as error:
            prepare(self.root, self.endpoint)
        self.assertEqual(error.exception.code, "incomplete_setup")
        self.assertEqual(key.read_bytes(), b"")

    def test_identity_file_mismatch_is_rejected_without_repairing_to_another_owner(self):
        prepare(self.root, self.endpoint)
        path = self.root / "receiver.json"
        value = json.loads(path.read_text())
        value["receiverID"] = "00000000-0000-0000-0000-000000000000"
        path.write_text(json.dumps(value))
        with self.assertRaises(BridgeError) as error:
            prepare(self.root, self.endpoint)
        self.assertEqual(error.exception.code, "pairing_mismatch")

    def test_endpoint_change_does_not_silently_rotate_pairing(self):
        prepare(self.root, self.endpoint)
        before = (self.root / "pairing.json").read_bytes()
        with self.assertRaises(BridgeError):
            prepare(self.root, "https://another-receiver.local:8766")
        self.assertEqual(before, (self.root / "pairing.json").read_bytes())


if __name__ == "__main__":
    unittest.main()
