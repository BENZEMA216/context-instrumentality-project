#!/usr/bin/env python3
"""Full production Drive Library cold-start/revoke transactions, entirely offline.

Only UIKit opportunity notifications and OAuth browser/Keychain are inert. The
actual init/revoke/connect/continue/resume, ledger and atomic metadata writer are
compiled together, without extracting/reimplementing those method bodies.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reuse-core-build', type=Path)
    parser.add_argument('--case-filter', default='')
    parser.add_argument('--compiler-plugin-no-sandbox', action='store_true',
                        help='Disable nested compiler-plugin sandbox within the existing outer isolation')
    parser.add_argument('--without-stop-fence-control', action='store_true')
    args = parser.parse_args()
    if args.without_stop_fence_control and args.case_filter != 'first ledger rename fails':
        parser.error('The negative control must select only the cold-start regression')
    os.umask(0o077)
    run = Path(tempfile.mkdtemp(prefix='phone-google-revoke-library-')).resolve()
    core = sorted((ROOT / 'Sources/RecordingCore').glob('*.swift'))
    phone = [ROOT / 'Phone' / name for name in ('GoogleDriveHTTP.swift', 'GoogleDriveFaultReports.swift',
        'GoogleDriveClient.swift', 'GoogleDriveOAuth.swift', 'GoogleDriveSyncProgress.swift',
        'GoogleDriveExecutionBudget.swift', 'GoogleDriveMetadataRecovery.swift',
        'GoogleDriveBackgroundUploads.swift', 'BackgroundSessionRestorationGate.swift')]
    library = ROOT / 'Phone/GoogleDriveLibrary.swift'
    harness = HERE / 'Harness.swift'
    inputs = [*core, *phone, library, harness, Path(__file__).resolve()]
    hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    before = hashes()
    source = library.read_text()
    if source.count('import UIKit\n') != 1:
        raise RuntimeError('UIKit import boundary changed')
    # All production method bodies remain intact; macOS builds the inert UIKit
    # observation shell below rather than importing the device framework.
    source = source.replace('import UIKit\n', '', 1)
    if args.without_stop_fence_control:
        needle = '            try persistStopIntent()\n'
        if source.count(needle) != 1:
            raise RuntimeError('Stop-fence negative-control boundary changed')
        source = source.replace(needle, '', 1)
    prepared = run / 'GoogleDriveLibrary.swift'
    prepared.write_text(source)
    swift = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    flags = ['-target', platform.machine() + '-apple-macosx15.0', '-sdk', sdk, '-swift-version', '5',
             '-module-cache-path', str(run / 'module-cache')]
    commands = [[swift, '-emit-module', '-emit-library', '-static', '-parse-as-library', '-module-name', 'RecordingCore',
        '-emit-module-path', str(run / 'RecordingCore.swiftmodule'), *flags, *map(str, core), '-o', str(run / 'libRecordingCore.a')],
        [swift, '-parse-as-library', '-strict-concurrency=complete', *flags, '-I', str(run), '-L', str(run),
         '-lRecordingCore', *map(str, phone), str(prepared), str(harness), '-o', str(run / 'probe')],
        [str(run / 'probe'), str(run / 'synthetic-json'), args.case_filter]]
    if args.compiler_plugin_no_sandbox:
        commands[1].insert(1, '-disable-sandbox')
    steps, reuse = [], None
    if args.reuse_core_build:
        old_run = args.reuse_core_build.resolve(strict=True)
        proof = old_run / 'evidence.json'
        old = json.loads(proof.read_text())
        if old['steps'][0]['exitCode'] != 0 or old['steps'][0].get('executedThisRun') is False:
            raise RuntimeError('Reuse must reference the original successful Core compile, not a reuse chain')
        old_command = old['commands'][0]
        old_core = [x for x in old_command if '/Sources/RecordingCore/' in x]
        if len(old_core) != len(core):
            raise RuntimeError('Reuse Core source set changed')
        old_root = str(Path(old_core[0]).parents[2])
        normalize = lambda xs, a, b: [x.replace(a, '<RUN>').replace(b, '<ROOT>') for x in xs]
        if normalize(old_command, str(old_run), old_root) != normalize(commands[0], str(run), str(ROOT)):
            raise RuntimeError('Reuse compiler/SDK/target/flags or input paths changed')
        for current in core:
            key = str(current.relative_to(ROOT))
            if old['inputSHA256Before'].get(key) != before[key] or old['inputSHA256After'].get(key) != before[key]:
                raise RuntimeError('Reuse input bytes differ: ' + key)
        artifact_hashes = {}
        for name in ['RecordingCore.swiftmodule', 'RecordingCore.swiftdoc', 'RecordingCore.swiftsourceinfo', 'libRecordingCore.a']:
            path = old_run / name
            if path.is_symlink() or not path.is_file():
                raise RuntimeError('Reuse artifact is not an ordinary file')
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            shutil.copyfile(path, run / name)
            if hashlib.sha256((run / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError('Reuse copy bytes changed')
            artifact_hashes[name] = digest
        reuse = dict(sourceEvidence=str(proof), sourceEvidenceSHA256=hashlib.sha256(proof.read_bytes()).hexdigest(),
                     sourceRoot=old_root, sourceCompileExitCode=0, compilerSDKTargetFlagsAndCoreInputsMatch=True,
                     artifactsSHA256=artifact_hashes)
        steps.append(dict(index=0, exitCode=0, executedThisRun=False, operation='verified_prior_core_reuse'))
    for index, command in enumerate(commands):
        if index == 0 and reuse:
            continue
        result = subprocess.run(command, capture_output=True, timeout=240)
        out, err = run / ('step-%d.stdout' % index), run / ('step-%d.stderr' % index)
        out.write_bytes(result.stdout); err.write_bytes(result.stderr)
        steps.append(dict(index=index, exitCode=result.returncode, executedThisRun=True, stdout=str(out), stderr=str(err)))
        if result.returncode:
            break
    after = hashes()
    report = run / 'synthetic-json/report.json'
    passed = len(steps) == 3 and steps[-1]['exitCode'] == 0 and before == after
    proof = dict(status='passed' if passed else 'failed', fullProductionLibrary=True,
        sourceStableDuringRun=before == after, inputSHA256Before=before, inputSHA256After=after,
        preparedLibrarySHA256=hashlib.sha256(prepared.read_bytes()).hexdigest(),
        productionTransform='remove UIKit import only; production OS-conditional file protection unchanged',
        negativeControl=args.without_stop_fence_control, compilerPluginNoSandbox=args.compiler_plugin_no_sandbox,
        commands=commands, steps=steps,
        reusedCoreBuild=reuse, report=str(report), deviceAccess=False, realNetworkAccess=False, realKeychainAccess=False, audioAccess=False)
    proof_path = run / 'proof.json'; proof_path.write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(dict(status=proof['status'], sourceStableDuringRun=before == after,
        proof=str(proof_path), report=json.loads(report.read_text()) if report.exists() else None, steps=steps)))
    if len(steps) > 1 and steps[-1]['exitCode'] and steps[-1].get('stderr'):
        print(Path(steps[-1]['stderr']).read_text()[-7000:])
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
