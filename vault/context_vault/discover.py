"""Owner-selected discovery. Only filenames, aliases, and variable names leave this CLI."""

import argparse
import base64
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from email import policy
from email.parser import BytesParser
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener

from .mcp_bridge import NoRedirect, _data_dir


MAX_DOC = 8 * 1024 * 1024
MAX_MAIL = 16 * 1024 * 1024
MIMES = {
    ".pdf": "application/pdf",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
}
MAGIC = {
    "application/pdf": b"%PDF-",
    "image/png": b"\x89PNG\r\n\x1a\n",
    "image/jpeg": b"\xff\xd8\xff",
}
SKIP_DIRS = {"node_modules", "__pycache__", "venv", "Library", "Pods"}
ENV_PREFIX = (
    r"^[[:blank:]]*(export[[:blank:]]+)?[A-Za-z_][A-Za-z0-9_]{0,126}[[:blank:]]*="
)
KEY_NAME = re.compile(r"(KEY|TOKEN|SECRET|CREDENTIAL|PASSWORD|PASSWD)", re.I)
SSH_ALIAS = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")
GMAIL_BASE = "https://gmail.googleapis.com/gmail/v1/users/me/messages"
GMAIL_ID = re.compile(r"[A-Za-z0-9_-]{1,2048}\Z")


def _label(name):
    # A producer-controlled filename must remain inert, even in terminal output.
    name = str(name).replace("\\", "/").split("/")[-1]
    return (
        "".join(ch if ch.isprintable() else "_" for ch in name).strip()[:120]
        or "document"
    )


def _ref(*parts):
    data = json.dumps(parts, ensure_ascii=True).encode()
    return hashlib.sha256(data).hexdigest()[:32]


def _stamp(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


@dataclass
class Candidate:
    ref: str
    label: str
    source: str
    kind: str
    read: object = None

    def metadata(self):
        return {
            "ref": self.ref,
            "label": self.label,
            "source": self.source,
            "kind": self.kind,
            "can_stage": self.read is not None,
        }


def _open_file(root, relative):
    # Re-open each path component relative to its verified directory. This also
    # prevents a directory swap between the original scan and selected import.
    path = Path(relative)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError("Invalid selected file.")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(root, flags)
    try:
        for part in path.parts[:-1]:
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        file_fd = os.open(
            path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd
        )
    finally:
        os.close(fd)
    file = os.fdopen(file_fd, "rb")
    if not stat.S_ISREG(os.fstat(file.fileno()).st_mode):
        file.close()
        raise ValueError("The selected path must be a regular file.")
    return file


def _document(label, mime, data):
    if (
        not isinstance(data, bytes)
        or len(data) > MAX_DOC
        or not data.startswith(MAGIC[mime])
    ):
        raise ValueError("Selected file has an unsupported format or size.")
    return {
        "kind": "document",
        "label": label,
        "mime": mime,
        "value": base64.b64encode(data).decode("ascii"),
    }


def _selected_file(root, relative, stamp, mime, label):
    with _open_file(root, relative) as source:
        if _stamp(os.fstat(source.fileno())) != stamp:
            raise ValueError("The selected file changed. Repeat discovery.")
        payload = source.read(MAX_DOC + 1)
        if _stamp(os.fstat(source.fileno())) != stamp:
            raise ValueError("The selected file changed. Repeat discovery.")
    return _document(label, mime, payload)


def _env_names(root, relative):
    # grep takes a file descriptor, cannot execute the file, and returns only
    # left-hand assignment names. Secret values never enter Python or stdout.
    with _open_file(root, relative) as file:
        if os.fstat(file.fileno()).st_size > 1024 * 1024:
            return
        out = subprocess.run(
            ["/usr/bin/grep", "-aEo", ENV_PREFIX],
            stdin=file,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"LC_ALL": "C"},
            timeout=5,
        )
    if out.returncode not in (0, 1):
        raise ValueError("Could not read variable names.")
    names = set()
    for line in out.stdout.decode("ascii").splitlines():
        name = line[:-1].strip().split()[-1]
        if KEY_NAME.search(name):
            names.add(name)
    yield from sorted(names)


def file_candidates(roots, include_env=False):
    for supplied in roots:
        root = Path(supplied).expanduser().absolute()
        if root.is_symlink() or not root.is_dir():
            raise ValueError("Choose an existing directory without a symlink.")
        for current, dirs, files, fd in os.fwalk(root, follow_symlinks=False):
            dirs[:] = sorted(
                name
                for name in dirs
                if not name.startswith(".") and name not in SKIP_DIRS
            )
            for name in sorted(files):
                mime = MIMES.get(Path(name).suffix.lower())
                env_file = include_env and (name == ".env" or name.startswith(".env."))
                if not env_file and (not mime or name.startswith(".")):
                    continue
                try:
                    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if not stat.S_ISREG(info.st_mode):
                    continue
                rel = Path(current).relative_to(root) / name
                stamp = _stamp(info)
                if env_file:
                    for key in _env_names(root, rel):
                        yield Candidate(
                            _ref(str(root), str(rel), key), key, "env-name", "key-name"
                        )
                elif 0 < info.st_size <= MAX_DOC:
                    label = _label(name)
                    ref = _ref(str(root), str(rel), stamp)
                    yield Candidate(
                        ref,
                        label,
                        "file",
                        "document",
                        lambda r=root, p=rel, s=stamp, m=mime, l=label: _selected_file(
                            r, p, s, m, l
                        ),
                    )


def mail_candidates(path):
    path = Path(path).expanduser().absolute()
    if path.suffix.lower() != ".eml":
        raise ValueError("Select an exported .eml message.")
    with _open_file(path.parent, path.name) as source:
        stamp = _stamp(os.fstat(source.fileno()))
        if stamp[2] > MAX_MAIL:
            raise ValueError("Selected message exceeds the size limit.")
        raw = source.read(MAX_MAIL + 1)
    if len(raw) > MAX_MAIL:
        raise ValueError("Selected message exceeds the size limit.")
    message = BytesParser(policy=policy.default).parsebytes(raw)
    for index, part in enumerate(message.walk()):
        name, mime = part.get_filename(), part.get_content_type()
        if not name or mime not in MAGIC:
            continue
        label = _label(name)
        yield Candidate(
            _ref(str(path), stamp, index),
            label,
            "eml",
            "document",
            lambda p=part, l=label, m=mime: _document(l, m, p.get_payload(decode=True)),
        )


def ssh_candidates(path):
    path = Path(path).expanduser().absolute()
    if path.name not in {"config", "ssh_config"}:
        raise ValueError("Select an OpenSSH config named config or ssh_config.")
    with _open_file(path.parent, path.name) as source:
        if os.fstat(source.fileno()).st_size > 1024 * 1024:
            raise ValueError("SSH config exceeds the size limit.")
        # No includes, IdentityFile reads, known_hosts, subprocesses, or ssh commands.
        out = subprocess.run(
            ["/usr/bin/grep", "-aEi", r"^[[:blank:]]*Host([[:blank:]]+|=)"],
            stdin=source,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"LC_ALL": "C"},
            timeout=5,
        )
    if out.returncode not in (0, 1):
        raise ValueError("Could not list SSH aliases.")
    aliases = set()
    for line in out.stdout.decode("utf-8", errors="replace").splitlines():
        tokens = re.split(r"[=\s]+", line.partition("#")[0].strip())[1:]
        aliases.update(alias for alias in tokens if SSH_ALIAS.fullmatch(alias))
    for alias in sorted(aliases):
        yield Candidate(
            _ref(str(path), alias),
            alias,
            "ssh-config",
            "ssh",
            lambda a=alias: {"kind": "ssh", "label": a, "value": a},
        )


class Gmail:
    """Fixed Google origin. Never request raw messages, headers, snippets or inline bodies."""

    def __init__(self, token):
        if not token or not re.fullmatch(r"[!-~]{1,8192}", token):
            raise ValueError(
                "Set CONTEXT_VAULT_GMAIL_TOKEN in the owner's local process (gmail.readonly)."
            )
        self._token = token
        self._http = build_opener(ProxyHandler({}), NoRedirect())

    def get(self, suffix, params, limit=2 * 1024 * 1024):
        req = Request(
            GMAIL_BASE + suffix + "?" + urlencode(params),
            headers={"Authorization": "Bearer " + self._token},
        )
        try:
            with self._http.open(req, timeout=15) as reply:
                raw = reply.read(limit + 1)
        except HTTPError as err:
            status = err.code
            err.close()
            raise ValueError(
                f"Gmail returned HTTP {status}. Check consent and the gmail.readonly scope."
            ) from None
        except (URLError, OSError):
            raise ValueError("Could not reach Gmail.") from None
        if len(raw) > limit:
            raise ValueError("Gmail response exceeds the size limit.")
        return json.loads(raw)


def _gmail_fields():
    node = "partId,filename,mimeType,body(attachmentId,size)"
    fields = node
    for _ in range(6):
        fields = node + ",parts(" + fields + ")"
    return "id,payload(" + fields + ")"


def _parts(part):
    yield part
    for child in part.get("parts", []):
        yield from _parts(child)


def _gmail_doc(client, message_id, attachment_id, mime, label, size):
    reply = client.get(
        "/" + message_id + "/attachments/" + attachment_id,
        {"fields": "size,data"},
        limit=MAX_DOC * 2,
    )
    encoded = reply.get("data", "")
    if not isinstance(encoded, str) or len(encoded) > ((MAX_DOC + 2) // 3) * 4:
        raise ValueError("Invalid attachment.")
    data = base64.b64decode(
        encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True
    )
    if len(data) != size:
        raise ValueError("Gmail attachment size changed. Repeat discovery.")
    return _document(label, mime, data)


def gmail_candidates(client, query, limit):
    if not query.strip() or not 1 <= limit <= 100:
        raise ValueError(
            "Provide a scoped Gmail query and a limit between 1 and 100 messages."
        )
    seen = 0
    params = {
        "q": "has:attachment " + query,
        "maxResults": limit,
        "fields": "nextPageToken,messages(id)",
    }
    while seen < limit:
        messages = client.get("", params)
        for entry in messages.get("messages", [])[: limit - seen]:
            message_id = entry["id"]
            if not GMAIL_ID.fullmatch(message_id):
                raise ValueError("Invalid Gmail message reference.")
            seen += 1
            message = client.get(
                "/" + message_id, {"format": "full", "fields": _gmail_fields()}
            )
            for part in _parts(message.get("payload", {})):
                name, mime = part.get("filename"), part.get("mimeType")
                body = part.get("body", {})
                aid, size = body.get("attachmentId"), body.get("size")
                if (
                    not name
                    or mime not in MAGIC
                    or not isinstance(size, int)
                    or not 0 < size <= MAX_DOC
                ):
                    continue
                label = _label(name)
                ref = _ref("gmail", message_id, part.get("partId"), name, size, aid)
                load = None
                if isinstance(aid, str) and GMAIL_ID.fullmatch(aid):

                    def load(mid=message_id, a=aid, m=mime, l=label, s=size):
                        return _gmail_doc(client, mid, a, m, l, s)

                yield Candidate(ref, label, "gmail", "document", load)
        page = messages.get("nextPageToken")
        if not page or not messages.get("messages") or page == params.get("pageToken"):
            return
        params["pageToken"] = page


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=_data_dir())
    subs = parser.add_subparsers(dest="source", required=True)
    files = subs.add_parser(
        "files", help="PDF, PNG, JPEG filename inventory within selected folders"
    )
    files.add_argument("--root", type=Path, action="append", required=True)
    files.add_argument(
        "--include-env",
        action="store_true",
        help="also list credential variable names in .env files",
    )
    mail = subs.add_parser(
        "eml", help="attachments in one explicitly selected local export"
    )
    mail.add_argument("--file", type=Path, required=True)
    ssh = subs.add_parser(
        "ssh", help="literal Host aliases in one explicitly selected OpenSSH config"
    )
    ssh.add_argument("--config", type=Path, required=True)
    connect = subs.add_parser(
        "gmail-connect",
        help="pair your Gmail account in macOS Keychain using a desktop OAuth client",
    )
    connect.add_argument(
        "--client",
        required=True,
        type=Path,
        help="selected Google Desktop OAuth client JSON",
    )
    subs.add_parser(
        "gmail-disconnect", help="forget this vault’s Gmail authorization locally"
    )
    gmail = subs.add_parser(
        "gmail", help="read-only search in the authorized Gmail account"
    )
    gmail.add_argument("--query", required=True)
    gmail.add_argument(
        "--limit", type=int, default=20, help="max matching messages, 1–100"
    )
    for sub in [files, mail, ssh, gmail]:
        sub.add_argument(
            "--match", default="", help="case-insensitive filename or alias substring"
        )
        sub.add_argument(
            "--stage",
            metavar="REF",
            help="stage exactly this candidate in the encrypted inbox",
        )
    args = parser.parse_args(argv)
    try:
        if args.source == "gmail-connect":
            from . import gmail_auth

            gmail_auth.connect(args.data_dir, args.client)
            print('{"gmail": "connected"}')
            return 0
        if args.source == "gmail-disconnect":
            from . import gmail_auth

            gmail_auth.disconnect(args.data_dir)
            print('{"gmail": "disconnected locally"}')
            return 0
        if args.source == "files":
            candidates = file_candidates(args.root, args.include_env)
        elif args.source == "eml":
            candidates = mail_candidates(args.file)
        elif args.source == "ssh":
            candidates = ssh_candidates(args.config)
        else:
            from . import gmail_auth

            client = Gmail(
                os.getenv("CONTEXT_VAULT_GMAIL_TOKEN")
                or gmail_auth.access_token(args.data_dir)
            )
            candidates = gmail_candidates(client, args.query, args.limit)
        shown = 0
        for candidate in candidates:
            if args.match.casefold() not in candidate.label.casefold():
                continue
            if args.stage:
                if args.stage != candidate.ref:
                    continue
                if candidate.read is None:
                    raise ValueError(
                        "This metadata reference cannot be staged. Use trusted owner entry or a selected .eml."
                    )
                from .intake import stage_item

                drop_id = stage_item(args.data_dir, candidate.read())
                print(json.dumps({"staged": drop_id}, ensure_ascii=True))
                return 0
            print(json.dumps(candidate.metadata(), ensure_ascii=True))
            shown += 1
            if shown >= 500:
                print(
                    "Showing the first 500 candidates. Narrow --root or --match for additional results.",
                    file=sys.stderr,
                )
                break
        if args.stage:
            raise ValueError(
                "Selection was not found or has changed. Repeat discovery."
            )
        return 0
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
    ) as exc:
        # OS and parser exceptions may include paths, byte sequences, or request URLs.
        message = (
            str(exc)
            if type(exc) is ValueError and not isinstance(exc, UnicodeError)
            else "Selected source unavailable."
        )
        parser.exit(2, "Discovery: " + message + "\n")


if __name__ == "__main__":
    sys.exit(main())
