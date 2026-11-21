import XCTest
import IPhoneUseRunnerSupport
@testable import IPhoneUseCore

final class NativeGestureValidationTests: XCTestCase {
    private func frame(patches: [(CGRect, [UInt8])] = []) throws -> CapturedObservation {
        CapturedObservation(nodes: [], metadata: [
            "backend": "apple-native", "displayID": UInt64(1), "displayUniqueID": "display",
            "displayRotation": "rot0", "nativeRotation": "rot0", "captureSource": "coredevice_screenshot",
            "screenContext": try jsonObject(JSONEncoder().encode(screenTestContext()))
        ], screenshot: try screenPNG(patches: patches))
    }

    private func gesture(_ kind: String = "tap", strict: Bool = false) throws -> (CoordinateGesture, DeviceAction) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ObservationCache(directory: root)
        _ = try cache.store(frame())
        var request: [String: Any] = ["reference": "o1", "x": 100, "y": 700]
        if kind == "swipe" {
            request = ["reference": "o1", "fromX": 100, "fromY": 700, "toX": 100, "toY": 200]
        }
        if kind == "long-press" { request["duration"] = 0.5 }
        if strict { request["maxScreenChange"] = 0.01 }
        let action = try DeviceAction(operation: kind, request: request, allowScreenText: true)
        let target = try cache.resolveTarget(for: action)
        _ = try cache.store(frame())
        XCTAssertThrowsError(try cache.resolveTarget(for: action)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "stale_reference")
        }
        return (try XCTUnwrap(target.gesture), action)
    }

    private func preflight(
        _ gesture: CoordinateGesture, action: DeviceAction, current: CapturedObservation,
        scoped: Bool = true, now: @escaping () -> TimeInterval = { 0 }
    ) throws -> ScreenGuard.Check {
        var captures = 0
        defer { XCTAssertEqual(captures, 1) }
        return try NativeInputPreflight.check(
            guard: gesture.screenGuard, displayID: 1, displayRotation: "rot0", displayUniqueID: "display",
            captureSource: "coredevice_screenshot", deadline: 8, maximumCaptures: 1,
            gestureValidation: scoped ? NativeGestureValidation(action: action, gesture: gesture) : nil,
            now: now, capture: { captures += 1; return current }).0
    }

    func testNativeClicksIgnoreUnrelatedGlobalChangeButRetainActualMeasurements() throws {
        let current = try frame(patches: [(CGRect(x: 200, y: 150, width: 160, height: 400), [0, 0, 0])])
        for kind in ["tap", "double-tap", "long-press"] {
            let (gesture, action) = try gesture(kind)
            let check = try preflight(gesture, action: action, current: current)
            XCTAssertTrue(check.accepted)
            XCTAssertGreaterThan(check.screenChange, 0.01)
            XCTAssertEqual(check.regionChanges, [0])
            XCTAssertEqual(check.result["diagnosticOnlyGlobal"] as? Bool, true)
            XCTAssertThrowsError(try preflight(gesture, action: action, current: current, scoped: false))
        }
    }

    func testScanningAnimationInsideSwipeCorridorDoesNotVetoScroll() throws {
        let (gesture, action) = try gesture("swipe")
        let current = try frame(patches: [(CGRect(x: 90, y: 480, width: 20, height: 20), [0, 0, 0])])
        let check = try preflight(gesture, action: action, current: current)
        XCTAssertTrue(check.accepted)
        XCTAssertEqual(check.regionChanges[0], 0)
        XCTAssertGreaterThan(check.regionChanges[1], 0)
        XCTAssertEqual(check.result["diagnosticOnlyRegions"] as? [Int], [1])
        XCTAssertThrowsError(try preflight(gesture, action: action, current: current, scoped: false))
    }

    func testChangedTouchDownOrClickTargetStillRejectsWithoutInput() throws {
        let current = try frame(patches: [(CGRect(x: 85, y: 685, width: 30, height: 30), [0, 0, 0])])
        for kind in ["tap", "double-tap", "long-press", "swipe"] {
            let (gesture, action) = try gesture(kind)
            XCTAssertThrowsError(try preflight(gesture, action: action, current: current)) {
                let failure = $0 as? ActionFailure
                XCTAssertEqual(failure?.code, "target_region_changed")
                XCTAssertEqual(failure?.possiblyExecuted, false)
                XCTAssertEqual(failure?.rejectedCapture?.screenshot, current.screenshot)
            }
        }
    }

    func testExplicitGlobalLimitStillRejectsUnrelatedChanges() throws {
        let (gesture, action) = try gesture(strict: true)
        let current = try frame(patches: [(CGRect(x: 200, y: 150, width: 160, height: 400), [0, 0, 0])])
        XCTAssertThrowsError(try preflight(gesture, action: action, current: current)) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
        }
    }

    func testDisplaySourceGeometryAndDeadlineCannotBeBypassedByGestureScope() throws {
        let (gesture, action) = try gesture("swipe"), original = try frame()
        for (key, value): (String, Any) in [
            ("displayID", UInt64(2)), ("displayUniqueID", "replacement"), ("displayRotation", "rot90"),
            ("captureSource", "native_media"), ("orientationResynchronized", true),
            ("screenContext", try jsonObject(JSONEncoder().encode(screenTestContext(orientation: 3))))
        ] {
            var metadata = original.metadata; metadata[key] = value
            let changed = CapturedObservation(nodes: [], metadata: metadata, screenshot: original.screenshot)
            XCTAssertThrowsError(try preflight(gesture, action: action, current: changed)) {
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false, key)
            }
        }
        let resized = CapturedObservation(
            nodes: [], metadata: original.metadata, screenshot: try screenPNG(width: 780, height: 1688))
        XCTAssertThrowsError(try preflight(gesture, action: action, current: resized))
        var calls = 0
        XCTAssertThrowsError(try preflight(gesture, action: action, current: original, now: {
            calls += 1; return calls < 4 ? 0 : 9
        })) {
            XCTAssertEqual(($0 as? ActionFailure)?.code, "input_preflight_timeout")
        }
    }
}
