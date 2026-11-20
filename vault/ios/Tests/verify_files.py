"""Exercise the shipping iPhone Files picker on a dedicated English-language simulator."""
import argparse
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

from context_vault.intake import import_drop, load_package, pairing
from context_vault.storage import Store


def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("udid", help="UDID of a booted, dedicated test iPhone")
    options = parser.parse_args()
    udid = str(uuid.UUID(options.udid)).upper()
    ios = Path(__file__).resolve().parents[1]
    simctl("bootstatus", udid, "-b")
    simctl("launch", udid, "com.apple.DocumentsApp")
    groups = simctl("get_app_container", udid, "com.apple.DocumentsApp", "groups")
    provider = Path(dict(row.split("\t", 1) for row in groups.splitlines())[
        "group.com.apple.FileProvider.LocalStorage"]) / "File Provider Storage"
    for _ in range(20):
        if provider.is_dir():
            break
        time.sleep(0.25)
    if not provider.is_dir():
        raise RuntimeError("Open On My iPhone in the simulator's Files app once and retry.")
    png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0l"
                           "EQVR42mP8/x8AAwMCAO+Xc1sAAAAASUVORK5CYII=")
    name = "ContextVaultSynthetic" + uuid.uuid4().hex[:8]
    fixture = provider / (name + ".png")
    try:
        with tempfile.TemporaryDirectory() as sandbox:
            temp = Path(sandbox)
            receiver = Store(temp / "receiver")
            receiver.create("a synthetic iPhone Files integration passphrase")
            pair = pairing(receiver, receiver.directory)["pairing"]
            with fixture.open("xb") as sample:
                sample.write(png)
            before = set(provider.rglob("context-*.cvdrop"))
            env = dict(os.environ, TEST_RUNNER_CONTEXT_VAULT_TEST_PAIR=pair,
                       TEST_RUNNER_CONTEXT_VAULT_TEST_FIXTURE=name)
            subprocess.run(["xcodebuild", "-quiet", "-project", str(ios / "ContextVaultCapture.xcodeproj"),
                            "-scheme", "ContextVaultCapture", "-destination", "id=" + udid,
                            "-parallel-testing-enabled", "NO", "-derivedDataPath", str(temp / "build"),
                            "-only-testing:CaptureUITests/CaptureUITests/testFilesRoundTrip",
                            "CODE_SIGNING_ALLOWED=NO", "test"], env=env, check=True)
            for exported in set(provider.rglob("context-*.cvdrop")) - before:
                receipt = import_drop(receiver, load_package(exported))
                full = receiver.get_item(receipt["id"])
                if full["label"] == "身份证" and base64.b64decode(full["value"]) == png:
                    exported.unlink()
                    print("Verified iPhone Files picker, cancel/retry, encrypted export and Mac import.")
                    return
            raise RuntimeError("Did not receive the synthetic image from On My iPhone.")
    finally:
        fixture.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
