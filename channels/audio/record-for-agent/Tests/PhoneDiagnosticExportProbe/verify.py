#!/usr/bin/env python3
"""Execute unchanged production diagnostic Store methods with controlled UI/attachment adapters and complete Core."""
import argparse, hashlib, json, os, subprocess, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--core-build', type=Path, required=True)
    parser.add_argument('--core-evidence', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    os.umask(0o077)
    run = options.output_dir.resolve(); run.mkdir(parents=True, exist_ok=False); run.chmod(0o700)
    store = ROOT / 'Phone/PhoneStore.swift'
    core = sorted((ROOT / 'Sources/RecordingCore').glob('*.swift'))
    paths = [store, HERE / 'Harness.swift', Path(__file__).resolve(), *core]
    hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    before = hashes()
    core_evidence = json.loads(options.core_evidence.read_text())
    if not core_evidence.get('passed') or not core_evidence.get('sourceStable'):
        raise SystemExit('Core build evidence did not pass with stable sources')
    if any(core_evidence['inputSHA256After'].get(str(p.relative_to(ROOT))) != before[str(p.relative_to(ROOT))] for p in core):
        raise SystemExit('Core source differs from tested module evidence')
    for name, digest in core_evidence['coreBuildArtifactsSHA256'].items():
        if hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest:
            raise SystemExit('Core build artifact differs from evidence')
    original = store.read_text()
    start = original.index('    func prepareDiagnostics(includeFullHistory:')
    end = original.index('\n}\n\nprivate struct PhoneLibraryRead', start)
    bundle_start = original.index('private struct PhoneDiagnosticBundle:')
    prepared = (HERE / 'Harness.swift').read_text().replace('/* PRODUCTION_METHODS */', original[start:end]).replace('/* PRODUCTION_BUNDLE */', original[bundle_start:])
    prepared_path = run / 'Probe.swift'; prepared_path.write_text(prepared)
    build = options.core_build.resolve()
    modules = build / 'out/Products/Debug'
    objects = [modules / 'libRecordingCore.a'] if modules.is_dir() else []
    if not objects:
        modules = next(build.glob('*/debug/Modules'))
        objects = sorted(modules.parent.glob('RecordingCore.build/*.swift.o'))
    if not objects: raise SystemExit('No evidenced Core object files')
    executable = run / 'probe'
    command = ['xcrun','swiftc','-swift-version','5','-parse-as-library','-I',str(modules),str(prepared_path),*[str(p) for p in objects],'-o',str(executable)]
    with (run / 'compile.log').open('wb') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode: raise SystemExit('Compilation failed; see private compile.log')
    with (run / 'run.json').open('wb') as output, (run / 'run.stderr').open('wb') as error:
        result = subprocess.run([str(executable)], stdout=output, stderr=error, timeout=40)
    after = hashes()
    evidence = {'schemaVersion':1,'passed':result.returncode == 0,'sourceStable':before == after,
        'inputSHA256Before':before,'inputSHA256After':after,'sourceTransformation':'Extract unchanged diagnostic methods/bundle into property shell; controlled UI/environment/fault adapters; complete actual Core',
        'coreEvidence':str(options.core_evidence.resolve()),'coreBuildArtifactsSHA256':core_evidence['coreBuildArtifactsSHA256'],
        'productionDeviceOrAudioAccess':False,'testsUseSyntheticEventsOnly':True}
    (run / 'evidence.json').write_text(json.dumps(evidence, indent=2)+'\n')
    print(json.dumps({'passed':evidence['passed'],'sourceStable':evidence['sourceStable'],'evidence':str(run / 'evidence.json')}))
    if result.returncode or before != after: raise SystemExit(1)
if __name__ == '__main__': main()
