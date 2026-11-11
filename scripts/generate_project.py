#!/usr/bin/env python3
"""Generate the Xcode project using only Python's standard library.

Phone/ and Watch/ are Xcode file-system-synchronized groups. Adding a Swift
source file to either folder does not require editing this generator.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "WristRecord.xcodeproj"
OBJECTS: dict[str, dict] = {}


def object_id(name: str) -> str:
    return hashlib.sha256(f"WristRecord:{name}".encode()).hexdigest()[:24].upper()


def add(object_name: str, isa: str, **values) -> str:
    key = object_id(object_name)
    if key in OBJECTS:
        raise ValueError(f"Duplicate object: {object_name}")
    OBJECTS[key] = {"isa": isa, **values}
    return key


def plist(value, level: int = 0) -> str:
    """Serialize the small OpenStep plist subset used by pbxproj files."""
    indent = "\t" * level
    if isinstance(value, dict):
        entries = [f"{indent}\t{plist(k)} = {plist(v, level + 1)};" for k, v in value.items()]
        return "{\n" + "\n".join(entries) + f"\n{indent}}}"
    if isinstance(value, list):
        if not value:
            return "()"
        return "(\n" + "\n".join(f"{indent}\t{plist(v, level + 1)}," for v in value) + f"\n{indent})"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def scheme(name: str) -> bytes:
    launcher_identifier = (
        "Xcode.DebuggerFoundation.Launcher.LLDB"
        if name == "WristRecordWatch"
        else "Xcode.IDEFoundation.Launcher.LLDB"
    )
    root = ET.Element("Scheme", LastUpgradeVersion="2640", version="1.3")
    build = ET.SubElement(root, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES",
                          buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")

    def reference(parent):
        ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary",
                      BlueprintIdentifier=object_id(f"target-{name}"), BuildableName=f"{name}.app",
                      BlueprintName=name, ReferencedContainer="container:WristRecord.xcodeproj")

    reference(entry)
    test = ET.SubElement(root, "TestAction", buildConfiguration="Debug",
                         selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                         selectedLauncherIdentifier=launcher_identifier,
                         shouldUseLaunchSchemeArgsEnv="YES")
    ET.SubElement(test, "Testables")
    launch = ET.SubElement(root, "LaunchAction", buildConfiguration="Debug",
                           selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                           selectedLauncherIdentifier=launcher_identifier,
                           launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO",
                           debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
    reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"))
    profile = ET.SubElement(root, "ProfileAction", buildConfiguration="Release",
                            shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="",
                            useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"))
    ET.SubElement(root, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(root, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    ET.indent(root, space="   ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def generate() -> dict[Path, bytes]:
    OBJECTS.clear()
    package = add("local-package", "XCLocalSwiftPackageReference", relativePath=".")
    config_files = {
        name: add(f"config-{name}", "PBXFileReference", lastKnownFileType="text.xcconfig",
                  path=f"{name}.xcconfig", sourceTree="<group>")
        for name in ["Shared", "Phone", "Watch"]
    }
    info_files = [add(f"plist-{name}", "PBXFileReference", lastKnownFileType="text.plist.xml",
                      path=f"{name}-Info.plist", sourceTree="<group>") for name in ["Phone", "Watch"]]
    config_group = add("config-group", "PBXGroup", children=[*config_files.values(), *info_files],
                       path="Config", sourceTree="<group>")
    source_groups = {name: add(f"group-{name}", "PBXFileSystemSynchronizedRootGroup", path=name,
                               sourceTree="<group>", explicitFileTypes={}, explicitFolders=[])
                     for name in ["Phone", "Watch"]}
    products = {name: add(f"product-{name}", "PBXFileReference", explicitFileType="wrapper.application",
                          includeInIndex=0, path=f"WristRecord{name}.app", sourceTree="BUILT_PRODUCTS_DIR")
                for name in ["Phone", "Watch", "PhoneValidation"]}
    product_group = add("products", "PBXGroup", children=list(products.values()), name="Products", sourceTree="<group>")
    package_file = add("package-file", "PBXFileReference", lastKnownFileType="sourcecode.swift",
                       path="Package.swift", sourceTree="<group>")
    main_group = add("main-group", "PBXGroup", children=[*source_groups.values(), config_group, package_file, product_group],
                     sourceTree="<group>")

    project_configs = []
    for config in ["Debug", "Release"]:
        settings = {
            "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
            "COPY_PHASE_STRIP": "NO", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17",
            "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "targeted",
        }
        if config == "Debug":
            settings.update({"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES",
                             "GCC_OPTIMIZATION_LEVEL": "0", "ONLY_ACTIVE_ARCH": "YES",
                             "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG",
                             "SWIFT_OPTIMIZATION_LEVEL": "-Onone"})
        else:
            settings.update({"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule",
                             "SWIFT_OPTIMIZATION_LEVEL": "-O", "VALIDATE_PRODUCT": "YES"})
        project_configs.append(add(f"project-{config}", "XCBuildConfiguration", name=config,
                                    baseConfigurationReference=config_files["Shared"], buildSettings=settings))
    project_config_list = add("project-config-list", "XCConfigurationList", buildConfigurations=project_configs,
                              defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

    proxy = add("watch-proxy", "PBXContainerItemProxy", containerPortal=object_id("project"), proxyType=1,
                remoteGlobalIDString=object_id("target-WristRecordWatch"), remoteInfo="WristRecordWatch")
    dependency = add("watch-dependency", "PBXTargetDependency", target=object_id("target-WristRecordWatch"), targetProxy=proxy)
    embed_file = add("watch-embed-file", "PBXBuildFile", fileRef=products["Watch"], settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
    embed_phase = add("watch-embed-phase", "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
                      dstPath="$(CONTENTS_FOLDER_PATH)/Watch", dstSubfolderSpec=16, files=[embed_file],
                      name="Embed Watch Content", runOnlyForDeploymentPostprocessing=0)

    targets = []
    for kind in ["Phone", "Watch", "PhoneValidation"]:
        name = f"WristRecord{kind}"
        source_kind = "Phone" if kind == "PhoneValidation" else kind
        product_dep = add(f"core-product-{kind}", "XCSwiftPackageProductDependency", package=package, productName="RecordingCore")
        framework_file = add(f"core-build-{kind}", "PBXBuildFile", productRef=product_dep)
        phases = [add(f"sources-{kind}", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                      files=[], runOnlyForDeploymentPostprocessing=0),
                  add(f"frameworks-{kind}", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                      files=[framework_file], runOnlyForDeploymentPostprocessing=0),
                  add(f"resources-{kind}", "PBXResourcesBuildPhase", buildActionMask=2147483647,
                      files=[], runOnlyForDeploymentPostprocessing=0)]
        if kind == "Phone":
            phases.append(embed_phase)
        settings = {}
        if kind == "PhoneValidation":
            # Compile/run the same phone source without the embedded-Watch platform
            # preflight. This is a simulator validation product, not the companion.
            settings = {"PRODUCT_NAME": name,
                        "PRODUCT_BUNDLE_IDENTIFIER": "$(WR_PHONE_BUNDLE_IDENTIFIER).validation",
                        "WR_APP_DISPLAY_NAME": "WristRecord 验证",
                        "SDKROOT": "iphonesimulator", "SUPPORTED_PLATFORMS": "iphonesimulator",
                        "SKIP_INSTALL": "YES"}
        configs = [add(f"{kind}-{config}", "XCBuildConfiguration", name=config,
                       baseConfigurationReference=config_files[source_kind], buildSettings=settings.copy())
                   for config in ["Debug", "Release"]]
        config_list = add(f"{kind}-config-list", "XCConfigurationList", buildConfigurations=configs,
                          defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
        targets.append(add(f"target-{name}", "PBXNativeTarget", buildConfigurationList=config_list,
                           buildPhases=phases, buildRules=[], dependencies=[dependency] if kind == "Phone" else [],
                           fileSystemSynchronizedGroups=[source_groups[source_kind]], name=name,
                           packageProductDependencies=[product_dep], productName=name, productReference=products[kind],
                           productType="com.apple.product-type.application"))

    project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES",
                   "LastUpgradeCheck": "2640", "LastSwiftUpdateCheck": "2640",
                   "TargetAttributes": {target: {"CreatedOnToolsVersion": "26.4", "ProvisioningStyle": "Automatic"} for target in targets}},
                  buildConfigurationList=project_config_list, developmentRegion="zh-Hans", hasScannedForEncodings=0,
                  knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group, minimizedProjectReferenceProxies=1,
                  packageReferences=[package], preferredProjectObjectVersion=77, productRefGroup=product_group,
                  projectDirPath="", projectRoot="", targets=targets)
    document = {"archiveVersion": 1, "classes": {}, "objectVersion": 77,
                "objects": dict(sorted(OBJECTS.items())), "rootObject": project}
    result = {PROJECT / "project.pbxproj": ("// !$*UTF8*$!\n" + plist(document) + "\n").encode()}
    for name in ["WristRecordPhone", "WristRecordWatch", "WristRecordPhoneValidation"]:
        result[PROJECT / "xcshareddata" / "xcschemes" / f"{name}.xcscheme"] = scheme(name)
    result[PROJECT / "project.xcworkspace" / "contents.xcworkspacedata"] = (
        '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0">\n'
        '   <FileRef location="self:"></FileRef>\n</Workspace>\n'
    ).encode()
    return result


def matches_generated_content(path: Path, actual: bytes, expected: bytes) -> bool:
    """Allow Xcode's XML formatting while preserving attributes and structure."""
    if path.suffix not in {".xcscheme", ".xcworkspacedata"}:
        return actual == expected
    try:
        return ET.canonicalize(xml_data=actual, strip_text=True) == ET.canonicalize(
            xml_data=expected, strip_text=True
        )
    except ET.ParseError:
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if generated project files are missing or stale")
    args = parser.parse_args()
    stale = []
    for path, content in generate().items():
        if args.check:
            if not path.exists() or not matches_generated_content(path, path.read_bytes(), content):
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
    if stale:
        parser.exit(1, "Regenerate with python3 scripts/generate_project.py:\n" + "\n".join(stale) + "\n")
    print("Xcode project is current." if args.check else "Generated WristRecord.xcodeproj and shared schemes.")


if __name__ == "__main__":
    main()
