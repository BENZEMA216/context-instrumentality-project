// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WristRecord",
    platforms: [.macOS("15.0"), .iOS("18.0"), .watchOS("11.0")],
    products: [.library(name: "RecordingCore", targets: ["RecordingCore"])],
    targets: [
        .target(name: "RecordingCore"),
        .target(name: "WatchAudio", dependencies: ["RecordingCore"], path: "Watch",
                exclude: ["WatchRecorderModel.swift", "WatchTransferBridge.swift", "WristRecordWatchApp.swift", "RecordingLocationManager.swift", "WatchIntegrityAuditCoordinator.swift", "PrivacyInfo.xcprivacy"],
                sources: ["AudioSegmentWriter.swift", "AudioTailRecovery.swift", "RecordingTailRecovery.swift"]),
        .testTarget(name: "RecordingCoreTests", dependencies: ["RecordingCore"]),
        .testTarget(name: "WatchAudioTests", dependencies: ["WatchAudio", "RecordingCore"])
    ]
)
