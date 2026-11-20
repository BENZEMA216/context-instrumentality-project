"""Compile the shipping Swift sender and verify its synthetic output with the Mac vault."""
import base64
import json
from pathlib import Path
import subprocess
import tempfile

from context_vault.intake import import_drop, load_package, pairing
from context_vault.storage import Store, VaultError


def main():
    ios = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory() as sandbox:
        tmp = Path(sandbox)
        binary = tmp / "seal"
        subprocess.run(["swiftc", str(ios / "ContextVaultCapture/Transfer.swift"),
                        str(ios / "Tests/Interop.swift"), "-o", str(binary)], check=True)
        receiver = Store(tmp / "receiver")
        receiver.create("a synthetic transfer fixture passphrase")
        address = pairing(receiver, receiver.directory)

        def exported(name):
            path = tmp / name
            result = subprocess.run([str(binary), address["pairing"], str(path)], check=True,
                                    capture_output=True, text=True)
            assert result.stdout.strip() == address["fingerprint"]
            assert b"%PDF" not in path.read_bytes() and "合成跨端测试".encode() not in path.read_bytes()
            return load_package(path)

        one, two = exported("first.cvdrop"), exported("second.cvdrop")
        assert one != two
        receipt = import_drop(receiver, one)
        assert import_drop(receiver, two) == receipt
        full = receiver.get_item(receipt["id"])
        assert full["label"] == "合成跨端测试" and full["mime"] == "application/pdf"
        assert b"Synthetic Context Vault cross-platform fixture" in base64.b64decode(full["value"])

        wrong = Store(tmp / "wrong")
        wrong.create("a different synthetic fixture passphrase")
        altered = json.loads(json.dumps(one))
        data = bytearray(base64.b64decode(altered["ct"]))
        data[-1] ^= 1
        altered["ct"] = base64.b64encode(data).decode()
        for vault, invalid in [(wrong, one), (receiver, altered)]:
            try:
                import_drop(vault, invalid)
            except VaultError:
                continue
            raise AssertionError("Invalid message unexpectedly accepted")
        assert wrong.list_items() == []
        assert receiver.list_items() == [receipt]
        print("Swift → Python HPKE transfer verified. Duplicate, tamper and wrong-recipient checks passed.")


if __name__ == "__main__":
    main()
