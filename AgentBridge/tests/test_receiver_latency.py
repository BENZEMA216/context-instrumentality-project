"""Receiver latency regressions; generated audio and loopback TLS only."""

import contextlib
import http.client
import io
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

import automatic


class TranscriptionLatencyTests(unittest.TestCase):
    def background(self):
        store = mock.Mock()
        store.root = Path('/unused-test-state')
        with mock.patch('automatic_transcription.TranscriptionWorker'):
            worker = automatic.BackgroundTranscription(store, '/unused-test-helper', interval=30)
        return worker

    def test_existing_backlog_drains_without_an_idle_poll_between_jobs(self):
        worker = self.background()
        calls = []

        def run_once(*args, **kwargs):
            calls.append(1)
            if len(calls) == 3:
                worker.stopped.set()
            return [{'status': 'ready'}]

        worker.worker.run_once.side_effect = run_once
        # Waiting after successful work reproduces the old 30s-per-segment delay.
        with mock.patch.object(worker.stopped, 'wait', side_effect=AssertionError('idle delay during backlog')):
            with contextlib.redirect_stdout(io.StringIO()):
                worker.run()
        self.assertEqual(len(calls), 3)

    def test_new_import_wakes_an_idle_worker_and_stop_is_prompt(self):
        worker = self.background()
        idle = threading.Event()
        resumed = threading.Event()

        def run_once(*args, **kwargs):
            if idle.is_set():
                resumed.set()
            idle.set()
            return []

        worker.worker.run_once.side_effect = run_once
        worker.start()
        try:
            self.assertTrue(idle.wait(2))
            worker.wake()
            self.assertTrue(resumed.wait(2), 'import waited for periodic polling')
        finally:
            worker.stop()
        self.assertFalse(worker.thread.is_alive())

    def test_unavailable_catalog_entries_do_not_create_a_busy_loop(self):
        worker = self.background()
        worker.worker.run_once.return_value = [{'status': 'unavailable', 'error': 'missing'}]
        with mock.patch.object(worker, 'work_available', create=True) as available:
            available.wait.side_effect = lambda _: worker.stopped.set()
            with contextlib.redirect_stdout(io.StringIO()):
                worker.run()
        self.assertEqual(worker.worker.run_once.call_count, 1)

    def test_stop_during_wakeup_clear_does_not_scan_or_wait_again(self):
        worker = self.background()
        clear = worker.work_available.clear

        def stop_during_clear():
            worker.stopped.set()
            worker.wake()
            clear()

        with mock.patch.object(worker.work_available, 'clear', side_effect=stop_during_clear):
            with mock.patch.object(worker.work_available, 'wait', side_effect=AssertionError('waiting after stop')):
                worker.run()
        worker.worker.run_once.assert_not_called()


class ReceiverTLSLatencyTests(unittest.TestCase):
    def test_idle_tls_handshake_cannot_block_another_authenticated_request(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cert, key = root / 'cert.pem', root / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(key), '-out', str(cert), '-days', '1',
                            '-subj', '/CN=localhost'], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            store = mock.Mock()
            store.accept.return_value = {'stored': True}
            token = 'A' * 43
            imported = mock.Mock()
            server = automatic.HTTPSReceiverServer(('127.0.0.1', 0),
                      automatic.receiver_handler(store, token, on_import=imported), context)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            idle = socket.create_connection(server.server_address, timeout=2)
            client = http.client.HTTPSConnection(*server.server_address, timeout=2,
                      context=ssl._create_unverified_context())
            try:
                client.request('POST', '/v1/imports', body=b'x', headers={
                    'Authorization': 'Bearer ' + token, 'Content-Type': 'application/zip',
                    'X-Delivery-ID': '00000000-0000-4000-8000-000000000001',
                    'X-Archive-SHA256': '0' * 64})
                response = client.getresponse()
                self.assertEqual(response.status, 200)
                response.read()
                imported.assert_called_once_with()
                store.accept.assert_called_once()
            finally:
                idle.close()
                client.close()
                server.shutdown()
                server.server_close()
                thread.join(2)


if __name__ == '__main__':
    unittest.main()
