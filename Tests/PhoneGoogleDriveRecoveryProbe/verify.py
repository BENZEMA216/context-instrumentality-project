#!/usr/bin/env python3
"""Actual Library metadata recovery plus same-request HTTP/OAuth timeout recovery.

Only the UIKit/OS opportunity shell and native task transport are synthetic.
All input files are synthetic JSON in a private temporary build directory.
URLProtocol intercepts HTTP; no Google network, Keychain, device, recording
content, login UI or OS scheduler is used.
"""
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
    parser.add_argument('--case-filter', default='')
    parser.add_argument('--legacy-no-recovery-control', action='store_true')
    parser.add_argument('--compiler-plugin-no-sandbox', action='store_true',
                        help='Disable the compiler plugin nested sandbox when the outer runner already provides isolation')
    args = parser.parse_args()
    if args.legacy_no_recovery_control and args.case_filter != 'one temporary metadata failure':
        parser.error('Negative control requires the one temporary metadata failure regression')
    os.umask(0o077)
    run = Path(tempfile.mkdtemp(prefix='phone-google-metadata-recovery-')).resolve()
    core = sorted((ROOT / 'Sources/RecordingCore').glob('*.swift'))
    phone = [ROOT / 'Phone' / name for name in ('GoogleDriveHTTP.swift', 'GoogleDriveFaultReports.swift',
        'GoogleDriveClient.swift', 'GoogleDriveOAuth.swift', 'GoogleDriveSyncProgress.swift',
        'GoogleDriveExecutionBudget.swift', 'GoogleDriveMetadataRecovery.swift',
        'GoogleDriveBackgroundUploads.swift', 'BackgroundSessionRestorationGate.swift')]
    library = ROOT / 'Phone/GoogleDriveLibrary.swift'
    harness = HERE / 'Harness.swift'
    cases = HERE / 'HTTPRecoveryCases.swift'
    inputs = [*core, *phone, library, harness, cases, Path(__file__).resolve()]
    hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    before = hashes()
    text = library.read_text()
    boundaries = [('    func resume() {', '    func transcriptDidSave('),
        ('    func continueSync() {', '    func revoke() {'),
        ('    func prepareBackgroundDelivery(', '    private func schedule('),
        ('    private func stopWork() {', '    private func scheduleRetry('),
        ('    private func failClosed(', '    private func publish() {')]
    methods = []
    for start, end in boundaries:
        if text.count(start) != 1 or text.count(end) != 1:
            raise RuntimeError('Production extraction boundary changed: ' + start)
        method = text[text.index(start):text.index(end)]
        methods.append(method.replace('private func ', 'func '))
    actual = '\n'.join(methods)
    if args.legacy_no_recovery_control:
        needle = '        if ledgerUnavailable { startMetadataRecoveryAtOpportunity(); return }\n'
        if actual.count(needle) != 2:
            raise RuntimeError('Legacy negative-control boundary changed')
        actual = actual.replace(needle, '', 1)  # old resume only schedules a blocked worker
    prepared = run / 'Harness.swift'
    shell = harness.read_text()
    marker = '// PRODUCTION_LIBRARY_METHODS'
    if shell.count(marker) != 1:
        raise RuntimeError('Production method insertion boundary changed')
    prepared.write_text(shell.replace(marker, actual))
    compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    flags = ['-target', platform.machine() + '-apple-macosx15.0', '-sdk', sdk, '-swift-version', '5',
             '-module-cache-path', str(run / 'module-cache')]
    if args.compiler_plugin_no_sandbox:
        flags += ['-Xfrontend', '-disable-sandbox']
    commands = [[compiler, '-parse-as-library', '-emit-module', '-emit-library', '-static',
        '-module-name', 'RecordingCore', '-emit-module-path', str(run / 'RecordingCore.swiftmodule'),
        *flags, *map(str, core), '-o', str(run / 'libRecordingCore.a')],
        [compiler, '-parse-as-library', '-strict-concurrency=complete', *flags, '-I', str(run), '-L', str(run),
         '-lRecordingCore', *map(str, phone), str(prepared), str(cases), '-o', str(run / 'probe')],
        [str(run / 'probe'), str(run / 'synthetic-json'), args.case_filter]]
    steps = []
    for index, command in enumerate(commands):
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
        stdout, stderr = run / ('step-%d.stdout' % index), run / ('step-%d.stderr' % index)
        stdout.write_text(result.stdout); stderr.write_text(result.stderr)
        steps.append(dict(exitCode=result.returncode, stdout=str(stdout), stderr=str(stderr)))
        if result.returncode:
            break
    after = hashes()
    report = run / 'synthetic-json/report.json'
    status = 'passed' if len(steps) == 3 and steps[-1]['exitCode'] == 0 and before == after else 'failed'
    proof = dict(status=status, sourceStableDuringRun=before == after, inputSHA256Before=before,
        inputSHA256After=after, commands=commands, steps=steps,
        productionMethodsSHA256=hashlib.sha256(actual.encode()).hexdigest(), report=str(report),
        negativeControl=args.legacy_no_recovery_control, deviceAccess=False, networkAccess=False, audioAccess=False)
    proof_path = run / 'proof.json'
    proof_path.write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(dict(status=status, sourceStableDuringRun=before == after, proof=str(proof_path),
                         report=json.loads(report.read_text()) if report.exists() else None, steps=steps)))
    return 0 if status == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
