#!/usr/bin/env python3
"""Offline actual HTTP/native adapter regression; generated JSON only, no device or audio."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler-plugin-no-sandbox', action='store_true',
        help='Disable compiler plugin nested sandboxing when the outer runner already supplies isolation')
    args = parser.parse_args()
    os.umask(0o077)
    run = Path(tempfile.mkdtemp(prefix='rfa-google-network-', dir='/tmp')).resolve()
    core = sorted((ROOT / 'Sources/RecordingCore').glob('*.swift'))
    phone = [ROOT / 'Phone' / name for name in ('GoogleDriveHTTP.swift', 'GoogleDriveFaultReports.swift',
        'BackgroundSessionRestorationGate.swift', 'GoogleDriveNetworkMonitor.swift')]
    inputs = [*core, *phone, ROOT / 'Phone/GoogleDriveBackgroundUploads.swift',
        HERE / 'Harness.swift', HERE / 'SessionInterleavingSupport.swift', Path(__file__).resolve()]
    hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    before = hashes()
    source = (ROOT / 'Phone/GoogleDriveBackgroundUploads.swift').read_text()
    start = '/// The only adapter that submits network bytes.'
    end = '/// UIKit completion must not wait for a user-facing OAuth flow.'
    types_start = 'struct GoogleDriveUploadTaskInfo: Sendable {'
    types_end = '/// A background attempt is bound to the same durable grant'
    for marker in (start, end, types_start, types_end):
        if source.count(marker) != 1:
            raise RuntimeError('Production boundary changed: ' + marker)
    adapter = run / 'GoogleDriveUploadSession.swift'
    adapter.write_text('import Foundation\nimport RecordingCore\nstruct GoogleDriveUploadRetryDeferred: Error {}\n' +
        source[source.index(types_start):source.index(types_end)] + source[source.index(start):source.index(end)])
    compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    flags = ['-target', platform.machine() + '-apple-macosx15.0', '-sdk', sdk, '-swift-version', '5',
        '-module-cache-path', str(run / 'module-cache')]
    if args.compiler_plugin_no_sandbox:
        flags += ['-Xfrontend', '-disable-sandbox']
    commands = [[compiler, '-parse-as-library', '-emit-module', '-emit-library', '-static', '-module-name',
        'RecordingCore', '-emit-module-path', str(run / 'RecordingCore.swiftmodule'), *flags,
        *map(str, core), '-o', str(run / 'libRecordingCore.a')],
        [compiler, '-parse-as-library', '-strict-concurrency=complete', *flags, '-I', str(run), '-L', str(run),
        '-lRecordingCore', *map(str, phone), str(adapter), str(HERE / 'SessionInterleavingSupport.swift'), str(HERE / 'Harness.swift'), '-o', str(run / 'probe')],
        [str(run / 'probe'), str(run / 'fixture')]]
    steps = []
    for i, command in enumerate(commands):
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
        stdout, stderr = run / f'step-{i}.stdout', run / f'step-{i}.stderr'
        stdout.write_text(result.stdout); stderr.write_text(result.stderr)
        steps.append(dict(exitCode=result.returncode, stdout=str(stdout), stderr=str(stderr)))
        if result.returncode:
            break
    after = hashes()
    stable = before == after
    status = 'passed' if len(steps) == 3 and steps[-1]['exitCode'] == 0 and stable else 'failed'
    evidence = dict(status=status, steps=steps, commands=commands, sourceStableDuringRun=stable,
        inputSHA256Before=before, inputSHA256After=after,
        deviceAccess=False, networkAccess=False, audioAccess=False)
    proof = run / 'evidence.json'
    proof.write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(dict(status=status, steps=steps, sourceStableDuringRun=stable,
        evidence=str(proof), deviceAccess=False, networkAccess=False, audioAccess=False)))
    return 0 if status == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
