import XCTest
@testable import RecordingCore

final class WatchLifecyclePolicyTests: XCTestCase {
    func testColdInactiveThenActiveEntersOnlyOnce() {
        var policy = WatchLifecyclePolicy()
        let initial = policy.observe(source: .scene, phase: .inactive, applicationPhase: .inactive)
        XCTAssertEqual(initial.action, .none)
        XCTAssertFalse(initial.foreground)
        let active = policy.observe(source: .scene, phase: .active, applicationPhase: .active)
        XCTAssertEqual(active.action, .enterForeground)
        XCTAssertTrue(active.foreground)
        XCTAssertFalse(active.forwardBackground)
    }

    func testSystemBackgroundLaunchDoesNotGrantForegroundAndCanLaterActivate() {
        var policy = WatchLifecyclePolicy()
        XCTAssertEqual(policy.observe(source: .scene, phase: .background, applicationPhase: .background).action, .none)
        let background = policy.observe(source: .delegateDidEnterBackground, phase: .background, applicationPhase: .background)
        XCTAssertTrue(background.forwardBackground)
        XCTAssertFalse(background.foreground)
        let active = policy.observe(source: .delegateDidBecomeActive, phase: .active, applicationPhase: .active)
        XCTAssertEqual(active.action, .enterForeground)
    }

    func testSceneAndDelegateActiveInEitherOrderHaveOneEffect() {
        for first in [WatchLifecyclePolicy.Source.scene, .delegateDidBecomeActive] {
            var policy = WatchLifecyclePolicy()
            let second: WatchLifecyclePolicy.Source = first == .scene ? .delegateDidBecomeActive : .scene
            let decisions = [policy.observe(source: first, phase: .active, applicationPhase: .active),
                             policy.observe(source: second, phase: .active, applicationPhase: .active),
                             policy.observe(source: first, phase: .active, applicationPhase: .active)]
            XCTAssertEqual(decisions.filter { $0.action == .enterForeground }.count, 1)
            XCTAssertEqual(decisions.dropFirst().map(\.disposition), [.duplicate, .duplicate])
        }
    }

    func testLateInactiveSceneCannotCloseAActuallyActiveOwner() {
        var policy = WatchLifecyclePolicy()
        _ = policy.observe(source: .delegateDidBecomeActive, phase: .active, applicationPhase: .active)
        let late = policy.observe(source: .scene, phase: .inactive, applicationPhase: .active)
        XCTAssertEqual(late.disposition, .sceneStateMismatch)
        XCTAssertEqual(late.action, .none)
        XCTAssertTrue(late.foreground)
    }

    func testWillResignRetiresOwnerWhileWKStateStillActiveAndBlocksLateSceneActive() {
        var policy = WatchLifecyclePolicy()
        _ = policy.observe(source: .scene, phase: .active, applicationPhase: .active)
        let resign = policy.observe(source: .delegateWillResignActive, phase: .inactive, applicationPhase: .active)
        XCTAssertEqual(resign.action, .leaveForeground)
        XCTAssertFalse(resign.foreground)
        let late = policy.observe(source: .scene, phase: .active, applicationPhase: .active)
        XCTAssertEqual(late.disposition, .awaitingActiveEdge)
        XCTAssertEqual(late.action, .none)
        XCTAssertFalse(late.foreground)
        XCTAssertEqual(policy.observe(source: .delegateDidBecomeActive, phase: .active, applicationPhase: .active).action,
                       .enterForeground)
    }

    func testSceneFallbackRecoversAfterObservedNonactiveWithoutAnActiveDelegate() {
        var policy = WatchLifecyclePolicy()
        _ = policy.observe(source: .scene, phase: .active, applicationPhase: .active)
        _ = policy.observe(source: .delegateWillResignActive, phase: .inactive, applicationPhase: .active)
        _ = policy.observe(source: .scene, phase: .inactive, applicationPhase: .inactive)
        XCTAssertEqual(policy.observe(source: .scene, phase: .active, applicationPhase: .active).action, .enterForeground)
    }

    func testActiveInactiveBackgroundDeliversBackgroundOncePerCycle() {
        var policy = WatchLifecyclePolicy()
        for _ in 0..<2 {
            XCTAssertEqual(policy.observe(source: .delegateDidBecomeActive, phase: .active, applicationPhase: .active).action,
                           .enterForeground)
            XCTAssertEqual(policy.observe(source: .delegateWillResignActive, phase: .inactive, applicationPhase: .active).action,
                           .leaveForeground)
            XCTAssertEqual(policy.observe(source: .scene, phase: .inactive, applicationPhase: .inactive).action, .none)
            XCTAssertFalse(policy.observe(source: .scene, phase: .background, applicationPhase: .background).forwardBackground)
            XCTAssertTrue(policy.observe(source: .delegateDidEnterBackground, phase: .background, applicationPhase: .background)
                .forwardBackground)
            XCTAssertFalse(policy.observe(source: .delegateDidEnterBackground, phase: .background, applicationPhase: .background)
                .forwardBackground)
        }
    }

    func testStaleSceneActiveAndUncorroboratedActiveDelegateCannotStartWork() {
        for actual in [WatchLifecyclePolicy.Phase.inactive, .background, .unknown] {
            var policy = WatchLifecyclePolicy()
            let scene = policy.observe(source: .scene, phase: .active, applicationPhase: actual)
            XCTAssertEqual(scene.disposition, .sceneStateMismatch)
            XCTAssertFalse(scene.foreground)
            let delegate = policy.observe(source: .delegateDidBecomeActive, phase: .active, applicationPhase: actual)
            XCTAssertEqual(delegate.disposition, .delegateStateMismatch)
            XCTAssertFalse(delegate.foreground)
        }
    }

    func testLateActiveInputsCannotRetainForegroundWhenWatchKitIsNotActive() {
        for source in [WatchLifecyclePolicy.Source.scene, .delegateDidBecomeActive] {
            for actual in [WatchLifecyclePolicy.Phase.inactive, .background, .unknown] {
                var policy = WatchLifecyclePolicy()
                _ = policy.observe(source: .scene, phase: .active, applicationPhase: .active)
                let late = policy.observe(source: source, phase: .active, applicationPhase: actual)
                XCTAssertEqual(late.disposition, source == .scene ? .sceneStateMismatch : .delegateStateMismatch)
                XCTAssertEqual(late.action, .leaveForeground)
                XCTAssertFalse(late.foreground)
                XCTAssertFalse(late.forwardBackground)
                XCTAssertEqual(policy.observe(source: source, phase: .active, applicationPhase: actual).action, .none)
            }
        }
    }
}
