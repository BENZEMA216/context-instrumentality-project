#!/usr/bin/env python3
"""Run the Phone iCloud Drive coordinator offline against synthetic temp files.

No device tools, security-scoped real folder, iCloud provider or private recording
is used. Production Swift is copied, never modified. UIKit and the pre-existing
GoogleDriveLocalFiles helper are replaced only in the isolated macOS harness.
An explicit synthetic-coordination mode also substitutes direct local accessors;
it does not exercise or claim system file-coordination behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SHIM = r'''
// Harness-only shims. All folders and source audio below are temporary synthetic files.
private final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState: State = .active
    static let willResignActiveNotification = Notification.Name("probe.resign")
    static let didBecomeActiveNotification = Notification.Name("probe.active")
}
private enum GoogleDriveLocalFiles {
    static func read(_ file: URL) throws -> Data { try Data(contentsOf: file) }
    static func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
'''
SYNTHETIC_COORDINATION_SHIM = r'''
// Optional local test double: only synthetic temporary folders are used.
// This does not model NSFileCoordinator's daemon, grants, waits or URL changes.
private final class ProbeFileCoordinator {
    init(filePresenter: NSFilePresenter?) {}
    func coordinate(readingItemAt url: URL, options: NSFileCoordinator.ReadingOptions,
                    error: inout NSError?, byAccessor accessor: (URL) -> Void) {
        accessor(url)
    }
    func coordinate(writingItemAt url: URL, options: NSFileCoordinator.WritingOptions,
                    error: inout NSError?, byAccessor accessor: (URL) -> Void) {
        accessor(url)
    }
}
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_write(path, value):
    path.write_text(value)
    os.chmod(path, 0o600)


def run_command(arguments, label, directory, environment=None):
    with (directory / (label + '.stdout')).open('w') as out, (directory / (label + '.stderr')).open('w') as err:
        os.chmod(out.name, 0o600)
        os.chmod(err.name, 0o600)
        result = subprocess.run(arguments, stdout=out, stderr=err, env=environment)
    if result.returncode:
        raise RuntimeError(f'{label} failed (exit {result.returncode}); see {directory / (label + ".stderr")}')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, help='New private output directory; default is a new temporary directory.')
    parser.add_argument('--recovery-only', action='store_true', help='Run only original-directory recovery regressions.')
    parser.add_argument('--continuation-only', action='store_true', help='Run only automatic provider continuation regressions.')
    parser.add_argument('--typed-only', action='store_true', help='Run only typed provider observation regressions.')
    parser.add_argument('--legacy-export-only', action='store_true', help='Run only interrupted legacy export recovery regressions.')
    parser.add_argument('--source-isolation-only', action='store_true', help='Run only source warning isolation and continuation regressions.')
    parser.add_argument('--foreground-slices-only', action='store_true', help='Run foreground sync publication and stop regressions.')
    parser.add_argument('--synthetic-coordination', action='store_true',
                        help='Use direct synthetic local accessors instead of system file coordination; separate logic evidence only.')
    options = parser.parse_args()
    if options.output_dir:
        directory = options.output_dir.resolve()
        directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    else:
        directory = Path(tempfile.mkdtemp(prefix='phone-icloud-offline-proof-'))
    os.chmod(directory, 0o700)
    inputs = [*sorted((ROOT / 'Sources/RecordingCore').glob('*.swift')),
              ROOT / 'Phone/ICloudDriveLibrary.swift', HERE / 'Harness.swift', HERE / 'BackgroundHarness.swift',
              HERE / 'LivenessHarness.swift', HERE / 'RecoveryHarness.swift', HERE / 'ContinuationHarness.swift',
              HERE / 'TypedObservationHarness.swift', HERE / 'LegacyExportRecoveryHarness.swift',
              HERE / 'SourceIsolationHarness.swift', HERE / 'ForegroundSliceHarness.swift', Path(__file__).resolve()]
    before = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    frozen = directory / 'core'
    frozen.mkdir(mode=0o700)
    for source in inputs:
        if source.parent == ROOT / 'Sources/RecordingCore':
            private_write(frozen / source.name, source.read_text())
    phone = (ROOT / 'Phone/ICloudDriveLibrary.swift').read_text()
    if phone.count('import UIKit') != 1:
        raise RuntimeError('Production UIKit import changed; inspect the documented harness boundary.')
    if options.synthetic_coordination:
        if phone.count('NSFileCoordinator(filePresenter: nil)') != 2:
            raise RuntimeError('Production coordination sites changed; inspect the optional synthetic harness boundary.')
        phone = phone.replace('NSFileCoordinator(filePresenter: nil)', 'ProbeFileCoordinator(filePresenter: nil)')
    shim = SHIM + (SYNTHETIC_COORDINATION_SHIM if options.synthetic_coordination else '')
    private_write(directory / 'PhoneOfflineProbe.swift', phone.replace('import UIKit', shim) + '\n' + (HERE / 'Harness.swift').read_text()
                  + '\n' + (HERE / 'BackgroundHarness.swift').read_text()
                  + '\n' + (HERE / 'LivenessHarness.swift').read_text()
                  + '\n' + (HERE / 'RecoveryHarness.swift').read_text()
                  + '\n' + (HERE / 'ContinuationHarness.swift').read_text()
                  + '\n' + (HERE / 'TypedObservationHarness.swift').read_text()
                  + '\n' + (HERE / 'LegacyExportRecoveryHarness.swift').read_text()
                  + '\n' + (HERE / 'SourceIsolationHarness.swift').read_text()
                  + '\n' + (HERE / 'ForegroundSliceHarness.swift').read_text())
    swiftc = subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True, text=True, check=True).stdout.strip()
    common = ['-module-cache-path', str(directory / 'module-cache')]
    start = time.monotonic()
    run_command([swiftc, '-parse-as-library', '-emit-module', '-emit-library', '-module-name', 'RecordingCore',
                 *map(str, sorted(frozen.glob('*.swift'))), *common, '-o', str(directory / 'libRecordingCore.dylib'),
                 '-emit-module-path', str(directory / 'RecordingCore.swiftmodule')], 'core-compile', directory)
    run_command([swiftc, '-parse-as-library', str(directory / 'PhoneOfflineProbe.swift'), *common,
                 '-I', str(directory), '-L', str(directory), '-lRecordingCore', '-o', str(directory / 'phone-probe')],
                'phone-compile', directory)
    environment = dict(os.environ, DYLD_LIBRARY_PATH=str(directory))
    if options.recovery_only:
        environment['RFA_ICLOUD_RECOVERY_ONLY'] = '1'
    if options.continuation_only:
        environment['RFA_ICLOUD_CONTINUATION_ONLY'] = '1'
    if options.typed_only:
        environment['RFA_ICLOUD_TYPED_ONLY'] = '1'
    if options.legacy_export_only:
        environment['RFA_ICLOUD_LEGACY_EXPORT_ONLY'] = '1'
    if options.foreground_slices_only:
        environment['RFA_ICLOUD_FOREGROUND_SLICES_ONLY'] = '1'
    if options.source_isolation_only:
        environment['RFA_ICLOUD_SOURCE_ISOLATION_ONLY'] = '1'
    run_command([str(directory / 'phone-probe')], 'phone-run', directory, environment)
    after = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    stable = before == after
    evidence = dict(sourceStableDuringRun=stable, inputSHA256=before, afterSHA256=after,
                    elapsedSeconds=round(time.monotonic() - start, 3),
                    realCloudAccess=False, privateRecordingAccess=False, deviceAccess=False,
                    syntheticCoordination=options.synthetic_coordination,
                    result=(directory / 'phone-run.stdout').read_text().strip())
    private_write(directory / 'proof.json', json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
    if not stable:
        raise RuntimeError('Production or harness sources changed while the probe ran; rerun against final inputs.')
    print(json.dumps(dict(result=evidence['result'], sourceStableDuringRun=stable,
                          realCloudAccess=False, syntheticCoordination=options.synthetic_coordination,
                          proof=str(directory / 'proof.json')), ensure_ascii=False))


if __name__ == '__main__':
    main()
