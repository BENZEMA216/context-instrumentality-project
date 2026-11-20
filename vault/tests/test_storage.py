import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os

import pytest

from context_vault import storage
from context_vault.storage import FILENAME, Store, VaultError

PASSPHRASE = "fictional example passphrase"
KEY = {
    "kind": "key",
    "label": "synthetic-service",
    "value": "secret-test-only",
    "target": "https://service.example/catalog",
}
PHOTO = {
    "kind": "document",
    "label": "synthetic-document",
    "mime": "image/png",
    "value": base64.b64encode(b"example-picture-marker").decode(),
}


def test_confidentiality_backup_and_recovery(tmp_path):
    store = Store(tmp_path / "one")
    assert not store.initialized and not store.unlocked
    with pytest.raises(VaultError):
        store.create("short")
    store.create(PASSPHRASE)
    with pytest.raises(VaultError):
        store.create(PASSPHRASE)
    key = store.save_item(KEY)
    photo = store.save_item(PHOTO)
    pairing = store.intake_private_key()
    assert len(pairing) == 32
    assert key == {
        "id": key["id"],
        "kind": "key",
        "label": KEY["label"],
        "revision": 1,
        "target": KEY["target"],
    }
    assert store.list_items() == [key, photo]
    content = (store.directory / FILENAME).read_bytes()
    assert os.stat(store.directory / FILENAME).st_mode & 0o077 == 0
    for tag in (
        KEY["label"],
        KEY["target"],
        KEY["value"],
        PHOTO["label"],
        PHOTO["value"],
        "example-picture-marker",
        pairing.hex(),
        PASSPHRASE,
        key["id"],
    ):
        assert tag.encode() not in content
    store.lock()
    with pytest.raises(VaultError, match="locked"):
        store.list_items()
    folder = tmp_path / "cloud"
    one = folder / store.backup(folder)
    two = folder / store.backup(folder)
    assert one != two
    assert one.read_bytes() == two.read_bytes() == content
    assert sorted(folder.iterdir()) == sorted([one, two])
    restored = Store(tmp_path / "two")
    with pytest.raises(VaultError):
        restored.restore(one, "wrong guess")
    assert not restored.initialized and not restored.unlocked
    restored.restore(one, PASSPHRASE)
    assert restored.get_item(photo["id"])["value"] == PHOTO["value"]
    assert restored.intake_private_key() == pairing
    with pytest.raises(VaultError, match="empty"):
        restored.restore(one, PASSPHRASE)
    restored.lock()
    assert not restored.unlocked
    restored.unlock(PASSPHRASE)
    assert restored.list_items() == [key, photo]


def test_tampered_ciphertext_and_invalid_kdf_rejected(tmp_path, monkeypatch):
    store = Store(tmp_path / "one")
    store.create(PASSPHRASE)
    path = store.directory / FILENAME
    original = path.read_bytes()
    path.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
    with pytest.raises(VaultError, match="damaged"):
        store.unlock(PASSPHRASE)
    assert not store.unlocked

    def must_not_derive(*args, **kwargs):
        pytest.fail("Performed costly KDF before checking the envelope")

    monkeypatch.setattr(storage, "_derive", must_not_derive)
    for damaged in (
        original[:8],
        bytes(len(storage.PREFIX)) + original[len(storage.PREFIX) :],
    ):
        path.write_bytes(damaged)
        with pytest.raises(VaultError):
            store.unlock(PASSPHRASE)


def test_two_writers_share_latest_and_reject_stale_edits(tmp_path):
    first, second = Store(tmp_path), Store(tmp_path)
    first.create(PASSPHRASE)
    second.unlock(PASSPHRASE)
    a = first.save_item(KEY)
    b = second.save_item(PHOTO)
    assert first.list_items() == [a, b]

    def edit(job):
        store, label = job
        try:
            return store.save_item({**KEY, "id": a["id"], "label": label}, expected=1)[
                "revision"
            ]
        except VaultError as exc:
            return exc.status

    with ThreadPoolExecutor(2) as pool:
        assert sorted(
            pool.map(edit, [(first, "revision A"), (second, "revision B")])
        ) == [2, 409]
    with pytest.raises(VaultError):
        first.save_item({**KEY, "id": a["id"]})
    with pytest.raises(VaultError):
        first.delete_item(a["id"], expected=1)
    second.delete_item(a["id"], expected=2)
    assert first.list_items() == [b]
    with pytest.raises(VaultError):
        second.get_item(a["id"])


def test_target_and_secret_field_validation(tmp_path):
    store = Store(tmp_path)
    store.create(PASSPHRASE)
    for target in (
        "https://name:pass@service.example/",
        "https://service.example/path?key=secret",
        "http://service.example/",
        "https://service.example/\r\n",
        "https://service.example:8443/",
        "https://service.example/#",
    ):
        with pytest.raises(VaultError):
            store.save_item({**KEY, "target": target})
    for item in (
        {"kind": "payment", "label": "card", "value": "123"},
        {"kind": "payment", "label": "0000 0000 0000 0000", "value": "link"},
        {"kind": "ssh", "label": "staging", "value": "-----BEGIN PRIVATE KEY-----"},
        {**PHOTO, "value": "<not-base64>"},
        {**PHOTO, "mime": "text/html"},
        {**KEY, "value": "bad header\n"},
        {"kind": "profile", "label": "old", "value": "  "},
    ):
        with pytest.raises(VaultError):
            store.save_item(item)
    assert (
        store.save_item(
            {"kind": "payment", "label": "Virtual wallet", "value": "link"}
        )["kind"]
        == "payment"
    )
    assert (
        store.save_item({"kind": "ssh", "label": "Test", "value": "synthetic-host"})[
            "kind"
        ]
        == "ssh"
    )
    assert (
        store.save_item(
            {
                "kind": "ssh",
                "label": "Key metadata",
                "value": "SHA256:" + base64.b64encode(bytes(32)).decode().rstrip("="),
            }
        )["kind"]
        == "ssh"
    )


def test_atomic_intake_and_deleted_tombstone(tmp_path):
    a, b = Store(tmp_path), Store(tmp_path)
    a.create(PASSPHRASE)
    b.unlock(PASSPHRASE)
    sid = hashlib.sha256(b"synthetic-intake-only").hexdigest()
    with ThreadPoolExecutor(2) as pool:
        one, two = pool.map(lambda s: s.import_item(PHOTO, sid), (a, b))
    assert one == two and len(a.list_items()) == 1
    a.delete_item(one["id"], 1)
    with pytest.raises(VaultError) as ex:
        b.import_item(PHOTO, sid)
    assert ex.value.status == 410
    b.lock()
    b.unlock(PASSPHRASE)
    assert b.list_items() == []


def test_symlinks_not_followed(tmp_path):
    source = Store(tmp_path / "original")
    source.create(PASSPHRASE)
    fake = Store(tmp_path / "other")
    (fake.directory / FILENAME).symlink_to(source.directory / FILENAME)
    with pytest.raises(VaultError):
        fake.create(PASSPHRASE)
    with pytest.raises((VaultError, OSError)):
        fake.unlock(PASSPHRASE)
    links = tmp_path / "linked-folder"
    links.symlink_to(source.directory, target_is_directory=True)
    with pytest.raises((VaultError, OSError)):
        source.backup(links)
