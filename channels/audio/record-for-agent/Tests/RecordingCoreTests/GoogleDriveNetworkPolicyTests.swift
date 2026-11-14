import Foundation
import XCTest
@testable import RecordingCore

final class GoogleDriveNetworkPolicyTests: XCTestCase {
    private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
        private var values: [String: Any] = [:]
        override func object(forKey key: String) -> Any? { values[key] }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    func testMissingSettingPreservesWiFiOnlyWithoutMigrationWrite() {
        let defaults = MemoryDefaults()
        let settings = GoogleDriveNetworkSettings(defaults: defaults)
        XCTAssertFalse(settings.allowsCellularAccess)
        XCTAssertNil(defaults.object(forKey: GoogleDriveNetworkSettings.defaultsKey))
        XCTAssertFalse(settings.policy.permits(.cellular))
        XCTAssertTrue(settings.policy.permits(.nonCellular))
    }

    func testExplicitChoiceSurvivesSettingsReloadAndLeavesUnrelatedSettingsAlone() {
        let defaults = MemoryDefaults()
        defaults.set("existing-choice", forKey: "unrelated")
        GoogleDriveNetworkSettings(defaults: defaults).setAllowsCellularAccess(true)
        let restored = GoogleDriveNetworkSettings(defaults: defaults)
        XCTAssertTrue(restored.allowsCellularAccess)
        restored.setAllowsCellularAccess(false)
        XCTAssertFalse(GoogleDriveNetworkSettings(defaults: defaults).allowsCellularAccess)
        XCTAssertEqual(defaults.object(forKey: "unrelated") as? String, "existing-choice")
    }

    func testMalformedPreferenceCannotOptIntoCellular() {
        let defaults = MemoryDefaults()
        defaults.set("true", forKey: GoogleDriveNetworkSettings.defaultsKey)
        XCTAssertFalse(GoogleDriveNetworkSettings(defaults: defaults).allowsCellularAccess)
    }

    func testAdmissionAndWaitingReasonAcrossNetworkChoices() {
        for allows in [false, true] {
            let policy = GoogleDriveNetworkPolicy(allowsCellularAccess: allows)
            XCTAssertFalse(policy.permits(.unknown))
            XCTAssertFalse(policy.permits(.unavailable))
            XCTAssertTrue(policy.permits(.nonCellular))
            XCTAssertEqual(policy.permits(.cellular), allows)
            XCTAssertEqual(policy.isWaitingForWiFi(on: .cellular), !allows)
            for path: GoogleDriveNetworkPath in [.unknown, .unavailable, .nonCellular] {
                XCTAssertFalse(policy.isWaitingForWiFi(on: path))
            }
        }
    }

    func testInitialOrRepeatedAvailablePathDoesNotManufactureRecovery() {
        var transition = GoogleDriveNetworkPathTransition()
        let policy = GoogleDriveNetworkPolicy()
        XCTAssertFalse(transition.observe(.nonCellular, policy: policy))
        XCTAssertFalse(transition.observe(.nonCellular, policy: policy))
        XCTAssertFalse(transition.observe(.unavailable, policy: policy))
        XCTAssertTrue(transition.observe(.nonCellular, policy: policy))
        XCTAssertFalse(transition.observe(.nonCellular, policy: policy))
    }

    func testCellularRecoveryRequiresTheUsersPermission() {
        var transition = GoogleDriveNetworkPathTransition()
        let wifiOnly = GoogleDriveNetworkPolicy()
        let cellular = GoogleDriveNetworkPolicy(allowsCellularAccess: true)
        XCTAssertFalse(transition.observe(.unavailable, policy: wifiOnly))
        XCTAssertFalse(transition.observe(.cellular, policy: wifiOnly))
        XCTAssertTrue(transition.observe(.cellular, policy: cellular))
        XCTAssertFalse(transition.observe(.cellular, policy: cellular))
        XCTAssertFalse(transition.observe(.cellular, policy: wifiOnly))
        XCTAssertTrue(transition.observe(.nonCellular, policy: wifiOnly))
    }
}
