import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


packager = load_script("package-agent-bridge")
diagnostic = load_script("diagnose-agent-bridge")


class OnboardingDistributionTests(unittest.TestCase):
    def fixture(self, root):
        for name in packager.FILES:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("public source fixture\n")
        core = root / "Sources/RecordingCore/RecordingMetadata.swift"
        core.parent.mkdir(parents=True)
        core.write_text("struct RecordingMetadata {}\n")

    def test_allowlist_excludes_private_data_and_manifest_verifies_every_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            self.fixture(root)
            for name in ("pairing.json", "receiver-token", "receiver.key", "recording.caf", "library.sqlite3", "Config/Local.xcconfig"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("PRIVATE_FIXTURE_MUST_NOT_SHIP")
            report = packager.package(root, Path(temporary) / "package.zip")
            with zipfile.ZipFile(report["path"]) as archive:
                prefix = packager.PACKAGE_ROOT + "/"
                manifest = json.loads(archive.read(prefix + "PACKAGE-MANIFEST.json"))
                self.assertIn("Sources/RecordingCore/RecordingMetadata.swift", [item["path"] for item in manifest["files"]])
                self.assertEqual(len(archive.namelist()), len(manifest["files"]) + 1)
                for item in manifest["files"]:
                    data = archive.read(prefix + item["path"])
                    self.assertNotIn(b"PRIVATE_FIXTURE_MUST_NOT_SHIP", data)
                    self.assertEqual(len(data), item["bytes"])
                    self.assertEqual(hashlib.sha256(data).hexdigest(), item["sha256"])
                self.assertIsNone(manifest["prebuiltTranscriber"])
            original = Path(report["path"]).read_bytes()
            with self.assertRaises(FileExistsError):
                packager.package(root, Path(report["path"]))
            self.assertEqual(original, Path(report["path"]).read_bytes())

    def test_symlinked_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            self.fixture(root)
            first = root / packager.FILES[0]
            first.unlink()
            target = Path(temporary) / "private"
            target.write_text("private fixture")
            first.symlink_to(target)
            with self.assertRaises(ValueError):
                packager.package(root, Path(temporary) / "package.zip")
            self.assertFalse((Path(temporary) / "package.zip").exists())

    def test_prebuilt_helper_is_hashed_without_execution_and_architecture_is_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            self.fixture(root)
            runtime = Path(temporary) / "transcriber"
            runtime.write_bytes(b"synthetic Mach-O fixture; never executed")
            runtime.chmod(0o700)
            with mock.patch.object(packager.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "arm64\n", "")) as run:
                report = packager.package(root, Path(temporary) / "package.zip", runtime)
            self.assertEqual(run.call_args.args[0], ["/usr/bin/lipo", "-archs", str(runtime.resolve())])
            self.assertEqual(report["prebuiltTranscriber"]["architecture"], "arm64")
            self.assertEqual(report["prebuiltTranscriber"]["sha256"], hashlib.sha256(runtime.read_bytes()).hexdigest())
            with mock.patch.object(packager.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "x86_64\n", "")):
                with self.assertRaises(ValueError):
                    packager.package(root, Path(temporary) / "wrong-arch.zip", runtime)
            self.assertFalse((Path(temporary) / "wrong-arch.zip").exists())

    def test_diagnostic_does_not_create_missing_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            before = list(home.rglob("*"))
            result = diagnostic.inspect_paths(home, home / "absent-library", home / "absent-state")
            self.assertFalse(result["library"]["exists"])
            self.assertFalse(result["delivery"]["exists"])
            self.assertEqual(before, list(home.rglob("*")))

    def test_diagnostic_redacts_secrets_and_does_not_change_existing_databases(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            library, state = home / "library", home / "state"
            library.mkdir(); state.mkdir()
            secret = "PRIVATE_FIXTURE_MUST_NOT_PRINT"
            db_path = library / "library.sqlite3"
            with sqlite3.connect(db_path) as db:
                db.executescript("CREATE TABLE recordings(id TEXT); CREATE TABLE transcripts(transcript_json TEXT);")
                db.execute("INSERT INTO recordings VALUES ('a')")
                db.execute("INSERT INTO transcripts VALUES (?)", (secret,))
            for name in ("pairing.json", "receiver-token", "receiver.key"):
                (state / name).write_text(secret)
            plist = home / "Library/LaunchAgents" / (diagnostic.LABEL + ".plist")
            plist.parent.mkdir(parents=True)
            plist.write_bytes(plistlib.dumps({"ProgramArguments": ["python", "--library", str(library), "--password", secret],
                                             "EnvironmentVariables": {"SECRET": secret}}))
            before = {str(path): path.read_bytes() for path in home.rglob("*") if path.is_file()}
            result = diagnostic.inspect_paths(home, library, state)
            self.assertEqual(result["library"]["recordings"], 1)
            self.assertEqual(result["library"]["readyTranscripts"], 1)
            self.assertNotIn(secret, json.dumps(result))
            self.assertEqual(before, {str(path): path.read_bytes() for path in home.rglob("*") if path.is_file()})


if __name__ == "__main__":
    unittest.main()
