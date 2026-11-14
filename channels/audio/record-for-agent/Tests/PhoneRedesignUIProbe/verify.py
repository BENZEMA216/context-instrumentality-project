#!/usr/bin/env python3
"""Build exact production SwiftUI views in an isolated simulator-only UI probe.

Only the probe bundle is installed. All stores, 137 metadata-only jobs, drafts
and reminder settings are in memory. No physical device command is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
APP_ID = "dev.benzema.WristRecord.RedesignUIProbe"
NAME = "RedesignUIProbe"


def identifier(label):
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()


def plist(value, indent=0):
    pad = "\t" * indent
    if isinstance(value, dict):
        return "{\n" + "".join(pad + "\t" + json.dumps(str(k)) + " = " + plist(v, indent + 1) + ";\n" for k, v in value.items()) + pad + "}"
    if isinstance(value, list):
        return "(\n" + "".join(pad + "\t" + plist(v, indent + 1) + ",\n" for v in value) + pad + ")"
    return json.dumps(str(value))


def make_project(run):
    # Compile the production reminder View verbatim, with the synthetic store in
    # HarnessApp. Exclude the production store so no notification API can run.
    reminder = ROOT / "Phone/RecordingReminderView.swift"
    reminder_view = run / "ProductionRecordingReminderView.swift"
    marker = "struct RecordingReminderView: View {"
    source = reminder.read_text()
    if source.count(marker) != 1:
        raise RuntimeError("Production reminder view declaration changed; inspect extraction.")
    reminder_view.write_text("import SwiftUI\nimport UIKit\n\n" + marker + source.split(marker, 1)[1])
    objects = {}

    def add(label, isa, **fields):
        key = identifier(label)
        objects[key] = dict(isa=isa, **fields)
        return key

    app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", path=NAME + ".app", sourceTree="BUILT_PRODUCTS_DIR")
    test_product = add("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", path=NAME + "Tests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    files = []
    builds = []
    for path in [HERE / "HarnessApp.swift", ROOT / "Phone/AutomaticDeliveryView.swift",
                 ROOT / "Phone/PhoneViews.swift", ROOT / "Phone/RecordDesign.swift",
                 ROOT / "Phone/AgentOnboardingStatement.swift", ROOT / "Phone/SyncSetupView.swift",
                 ROOT / "Phone/ICloudDriveLibraryView.swift", ROOT / "Phone/GoogleDriveLibraryView.swift", reminder_view]:
        ref = add(str(path), "PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(path), sourceTree="<absolute>")
        files.append(ref)
        builds.append(add("build-" + str(path), "PBXBuildFile", fileRef=ref))
    test_ref = add("test-source", "PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(HERE / "ProbeUITests.swift"), sourceTree="<absolute>")
    files.append(test_ref)
    test_build = add("test-build", "PBXBuildFile", fileRef=test_ref)
    products = add("products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
    group = add("group", "PBXGroup", children=files + [products], sourceTree="<group>")
    package = add("package", "XCLocalSwiftPackageReference", relativePath=str(ROOT))
    core = add("core", "XCSwiftPackageProductDependency", package=package, productName="RecordingCore")
    core_build = add("core-build", "PBXBuildFile", productRef=core)

    def configs(label, extra):
        settings = dict(SDKROOT="iphonesimulator", SUPPORTED_PLATFORMS="iphonesimulator",
                        IPHONEOS_DEPLOYMENT_TARGET="18.0", SWIFT_VERSION="5.0",
                        ALWAYS_SEARCH_USER_PATHS="NO", ARCHS="arm64", ONLY_ACTIVE_ARCH="YES",
                        SWIFT_OPTIMIZATION_LEVEL="-Onone",
                        CODE_SIGNING_ALLOWED="YES", CODE_SIGN_IDENTITY="-",
                        CODE_SIGNING_REQUIRED="YES", TARGETED_DEVICE_FAMILY="1",
                        GENERATE_INFOPLIST_FILE="YES", **extra)
        entries = [add(label + config, "XCBuildConfiguration", name=config, buildSettings=settings) for config in ["Debug", "Release"]]
        return add(label + "-configs", "XCConfigurationList", buildConfigurations=entries, defaultConfigurationIsVisible="0", defaultConfigurationName="Debug")

    common = configs("project", {})
    app_configs = configs("app", dict(PRODUCT_NAME=NAME, PRODUCT_BUNDLE_IDENTIFIER=APP_ID,
                                     INFOPLIST_KEY_UILaunchScreen_Generation="YES",
                                     INFOPLIST_KEY_UIApplicationSceneManifest_Generation="YES"))
    test_configs = configs("test", dict(PRODUCT_NAME=NAME + "Tests", PRODUCT_BUNDLE_IDENTIFIER=APP_ID + ".tests",
                                      TEST_TARGET_NAME=NAME))
    asset_ref = add("brand-assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog", path=str(ROOT / "Phone/Assets.xcassets"), sourceTree="<absolute>")
    objects[group]["children"].append(asset_ref)
    asset_build = add("brand-assets-build", "PBXBuildFile", fileRef=asset_ref)
    resources = add("app-resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[asset_build], runOnlyForDeploymentPostprocessing="0")
    source_phase = add("app-sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")
    frameworks = add("app-frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[core_build], runOnlyForDeploymentPostprocessing="0")
    app = add("app-target", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=[source_phase, frameworks, resources],
              buildRules=[], dependencies=[], name=NAME, productName=NAME, productReference=app_product,
              packageProductDependencies=[core], productType="com.apple.product-type.application")
    proxy = add("proxy", "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType="1", remoteGlobalIDString=app, remoteInfo=NAME)
    dependency = add("dependency", "PBXTargetDependency", target=app, targetProxy=proxy)
    test_phase = add("test-sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[test_build], runOnlyForDeploymentPostprocessing="0")
    test_frameworks = add("test-frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
    tests = add("test-target", "PBXNativeTarget", buildConfigurationList=test_configs, buildPhases=[test_phase, test_frameworks],
                buildRules=[], dependencies=[dependency], name=NAME + "Tests", productName=NAME + "Tests",
                productReference=test_product, productType="com.apple.product-type.bundle.ui-testing")
    project = add("project", "PBXProject", attributes={"LastUpgradeCheck": "2710"},
                  buildConfigurationList=common, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans",
                  hasScannedForEncodings="0", knownRegions=["zh-Hans", "en", "Base"], mainGroup=group,
                  productRefGroup=products, projectDirPath="", projectRoot="", targets=[app, tests], packageReferences=[package])
    folder = run / (NAME + ".xcodeproj")
    folder.mkdir()
    (folder / "project.pbxproj").write_text("// !$*UTF8*$!\n" + plist(dict(archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject=project)) + "\n")
    schemes = folder / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True)

    def reference(key, product, target):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key}" BuildableName="{product}" BlueprintName="{target}" ReferencedContainer="container:{NAME}.xcodeproj"/>'
    app_reference = reference(app, NAME + ".app", NAME)
    tests_reference = reference(tests, NAME + "Tests.xctest", NAME + "Tests")
    (schemes / (NAME + ".xcscheme")).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{app_reference}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{tests_reference}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
<Testables><TestableReference skipped="NO">{tests_reference}</TestableReference></Testables>
</TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><BuildableProductRunnable runnableDebuggingMode="0">{app_reference}</BuildableProductRunnable></LaunchAction>
</Scheme>''')
    return folder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", help="Existing simulator UDID; never a physical device.")
    parser.add_argument("--only-test", action="append", help="Optional XCTest selector; repeat to select multiple tests.")
    parser.add_argument("--derived-data", help="Reuse a prior probe DerivedData directory.")
    parser.add_argument("--build-only", action="store_true")
    args = parser.parse_args()
    run = Path(tempfile.mkdtemp(prefix="wristrecord-redesign-ui-probe-"))
    project = make_project(run)
    inputs = [HERE / "HarnessApp.swift", HERE / "ProbeUITests.swift", Path(__file__).resolve(),
              ROOT / "Phone/AutomaticDeliveryView.swift", ROOT / "Phone/PhoneViews.swift",
              ROOT / "Phone/RecordDesign.swift", ROOT / "Phone/RecordingReminderView.swift",
              ROOT / "Phone/AgentOnboardingStatement.swift",
              ROOT / "Sources/RecordingCore/RecordingActivity.swift"]
    inputs += [ROOT / "Phone/SyncSetupView.swift", ROOT / "Phone/ICloudDriveLibraryView.swift", ROOT / "Phone/GoogleDriveLibraryView.swift", *sorted((ROOT / "Phone/Assets.xcassets").rglob("*.*"))]
    inputs = [p for p in inputs if p.is_file()]
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    env = os.environ.copy()
    if args.build_only:
        destination = "generic/platform=iOS Simulator"
    else:
        devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], env=env))
        available = [(runtime, device) for runtime, values in devices["devices"].items() for device in values if device.get("isAvailable")]
        selected = next(((runtime, device) for runtime, device in available if device["udid"] == args.simulator), None) if args.simulator else next(((runtime, device) for runtime, device in available if device["name"] == "Record for Agent UI Probe"), None)
        if args.simulator and selected is None:
            raise SystemExit("Requested simulator is not an available simulator.")
        if selected is None:
            types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "--json"], env=env))["devicetypes"]
            small = next(item for item in types if item["name"] == "iPhone SE (3rd generation)")
            runtime = next(runtime for runtime, _ in available if runtime.endswith("iOS-26-4"))
            udid = subprocess.check_output(["xcrun", "simctl", "create", "Record for Agent UI Probe", small["identifier"], runtime], env=env, text=True).strip()
            selected = (runtime, dict(udid=udid, state="Shutdown", name="Record for Agent UI Probe"))
        device = selected[1]
        print(json.dumps({"run": str(run), "phase": "simulator-ready", "simulator": device}, indent=2), flush=True)
        if device["state"] != "Booted":
            subprocess.run(["xcrun", "simctl", "boot", device["udid"]], env=env, check=True, capture_output=True)
            subprocess.run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], env=env, check=True, timeout=60)
        destination = "platform=iOS Simulator,id=" + device["udid"]
    command = ["xcodebuild", "-project", str(project), "-scheme", NAME, "-configuration", "Debug",
               "-destination", destination, "-derivedDataPath", str(Path(args.derived_data).resolve() if args.derived_data else run / "DerivedData"),
               "-resultBundlePath", str(run / "Result.xcresult"),
               "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=YES",
               "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
    for selector in args.only_test or []:
        command.append("-only-testing:" + selector)
    command.append("build-for-testing" if args.build_only else "test")
    print(json.dumps({"run": str(run), "phase": "build" if args.build_only else "simulator-ui-test"}, indent=2), flush=True)
    with (run / "xcodebuild.log").open("w") as log:
        result = subprocess.run(command, env=env, cwd=run, stdout=log, stderr=subprocess.STDOUT)
    after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    summary = dict(exitCode=result.returncode, sourceStableDuringRun=before == after, inputSHA256Before=before,
                   inputSHA256After=after, resultBundle=str(run / "Result.xcresult"), log=str(run / "xcodebuild.log"),
                   scope="Production annual Record page, same-page SyncSetup, provider forms, pairing and brand assets; isolated synthetic stores and metadata-only fixtures; simulator only; no real recordings, network or notifications.")
    (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if result.returncode == 0 and before == after else 1


if __name__ == "__main__":
    raise SystemExit(main())
