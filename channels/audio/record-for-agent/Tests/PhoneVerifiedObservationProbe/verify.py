#!/usr/bin/env python3
"""Run actual receipt owner and iCloud actor hooks in a synthetic build86/87 bundle.
Only generated temporary fixtures are used; no real media, device, account or provider is accessed.
The unchecked-tail setup exports synthetic bytes, then observations read metadata only.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-build', type=Path, required=True)
    parser.add_argument('--build', choices=('86','87'), default='86')
    parser.add_argument('--output-dir', type=Path)
    args = parser.parse_args()
    run = args.output_dir.resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='phone-verified-observation-'))
    run.mkdir(parents=True, exist_ok=not bool(args.output_dir))
    core = sorted((ROOT / 'Sources/RecordingCore').glob('*.swift'))
    previous = json.loads((args.core_build / 'evidence.json').read_text())
    hashes = {str(path.relative_to(ROOT)): digest(path) for path in core}
    if not previous.get('sourceStableDuringRun') or any(previous['inputSHA256After'].get(k) != v for k, v in hashes.items()):
        raise SystemExit('Prior Core input bytes do not match final source.')
    if previous['steps'][0].get('exitCode') != 0:
        raise SystemExit('Prior Core did not compile successfully.')
    core_build = args.core_build.resolve()
    inputs = [*core, ROOT / 'Phone/PhoneConnectivity.swift', ROOT / 'Phone/ICloudDriveLibrary.swift',
              ROOT / 'Tests/PhoneICloudDriveProbe/verify.py', HERE / 'Harness.swift', Path(__file__).resolve()]
    before = {str(p.relative_to(ROOT)): digest(p) for p in inputs}
    spec = importlib.util.spec_from_file_location('icloud_probe', ROOT / 'Tests/PhoneICloudDriveProbe/verify.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    icloud = (ROOT / 'Phone/ICloudDriveLibrary.swift').read_text()
    if icloud.count('import UIKit') != 1 or icloud.count('NSFileCoordinator(filePresenter: nil)') != 2:
        raise SystemExit('Known synthetic iCloud platform boundaries changed.')
    icloud = icloud.replace('import UIKit', module.SHIM + module.SYNTHETIC_COORDINATION_SHIM)
    icloud = icloud.replace('NSFileCoordinator(filePresenter: nil)', 'ProbeFileCoordinator(filePresenter: nil)')
    phone = (ROOT / 'Phone/PhoneConnectivity.swift').read_text()
    marker = 'private final class PhoneReceiptEvidence:'
    if phone.count(marker) != 1:
        raise SystemExit('Receipt evidence owner boundary changed.')
    receipt = marker + phone.split(marker, 1)[1]
    prepared = run / 'Probe.swift'
    prepared.write_text(icloud + '\n' + receipt + '\n' + (HERE / 'Harness.swift').read_text())
    bundle = run / 'ObservationProbe.app/Contents'
    binary = bundle / 'MacOS/probe'; binary.parent.mkdir(parents=True)
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'invalid.synthetic.observation',
        'CFBundleExecutable': 'probe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': args.build}))
    swift = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    commands = [[swift, '-parse-as-library', '-swift-version', '5', '-sdk', sdk,
                 '-module-cache-path', str(run / 'module-cache'), '-I', str(core_build), '-L', str(core_build),
                 '-lRecordingCore', str(prepared), '-o', str(binary)],
                [str(binary), str(run / 'fixtures')]]
    steps = []
    for i, command in enumerate(commands):
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
        log = run / ('step-%s.log' % i); log.write_text(result.stdout + result.stderr)
        steps.append({'exitCode': result.returncode, 'log': str(log)})
        if result.returncode:
            break
    after = {str(p.relative_to(ROOT)): digest(p) for p in inputs}
    status = 'passed' if len(steps) == 2 and all(s['exitCode'] == 0 for s in steps) and before == after else 'failed'
    proof = {'status': status, 'sourceStableDuringRun': before == after, 'build': args.build,
        'inputSHA256Before': before, 'inputSHA256After': after,
        'coreEvidence': str(core_build / 'evidence.json'), 'coreArtifactSHA256': digest(core_build / 'libRecordingCore.a'),
        'preparedSHA256': digest(prepared), 'commands': commands, 'steps': steps,
        'deviceAccess': False, 'realAudioRead': False, 'syntheticByteFixtures': True,
        'observationMetadataOnly': True, 'realProviderAccess': False,
        'transformations': ['Reuse exact existing iCloud offline platform adapters',
            'Extract actual complete private PhoneReceiptEvidence class unchanged',
            'Append same-file read-only test accessors for serial drainage, loaded flags and the owned archive',
            'Run executable inside synthetic CFBundleVersion' + args.build + ' app; no production build substitution']}
    (run / 'proof.json').write_text(json.dumps(proof, indent=2)+'\n')
    print(json.dumps({'status':status, 'proof':str(run/'proof.json'), 'result':(run/'step-1.log').read_text() if len(steps)==2 else None}))
    return 0 if status == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
