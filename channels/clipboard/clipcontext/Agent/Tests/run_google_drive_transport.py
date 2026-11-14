#!/usr/bin/env python3
"""Exercise the production Google Drive transport with synthetic responses on macOS."""

import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PRODUCTION = ROOT / "Maccy" / "ClipboardGoogleDrive.swift"
SCENARIOS = Path(__file__).with_name("GoogleDriveTransportSmoke.swift")


class RedirectHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append(self.path)
        self.send_response(307 if self.path == "/initial" else 200)
        if self.path == "/initial":
            self.send_header("Location", "/destination")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


def main():
    with tempfile.TemporaryDirectory(prefix="clipcontext-drive-smoke-") as directory:
        temporary = Path(directory)
        source = temporary / "GoogleDriveTransportSmoke.swift"
        binary = temporary / "google-drive-transport-smoke"
        # One compilation unit exercises the exact private transport and callback from the app.
        source.write_bytes(PRODUCTION.read_bytes() + b"\n" + SCENARIOS.read_bytes())
        subprocess.run(
            ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", str(source), "-o", str(binary)],
            cwd=temporary, check=True, timeout=120,
        )

        with ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler) as server:
            server.requests = []
            listener = threading.Thread(target=server.serve_forever, daemon=True)
            listener.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}/initial"
                subprocess.run([str(binary), url], cwd=temporary, check=True, timeout=45)
            finally:
                server.shutdown()
                listener.join()
            if server.requests != ["/initial"]:
                raise AssertionError(f"The redirect was followed: {server.requests}")
        print("PASS: Google Drive transport smoke tests")


if __name__ == "__main__":
    main()
