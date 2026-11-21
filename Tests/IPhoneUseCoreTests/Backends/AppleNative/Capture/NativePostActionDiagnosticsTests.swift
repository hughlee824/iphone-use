import XCTest
@testable import IPhoneUseCore

final class NativePostActionDiagnosticsTests: XCTestCase {
    func testDisabledUnlessExplicitAbsoluteDirectory() {
        XCTAssertNil(NativePostActionDiagnostics.fromEnvironment([:]))
        XCTAssertNil(NativePostActionDiagnostics.fromEnvironment([
            NativePostActionDiagnostics.environmentKey: "relative/path"
        ]))
    }

    func testExportsExactFramesAfterSamplingWithoutChangingReadiness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = NativePostActionDiagnostics(root: root)
        let fixtures = NativePostActionStabilityTests()
        let first = try fixtures.frame(), second = try fixtures.frame(180)
        var time = 0.0, count = 0
        let sampled = try NativePostActionStability.capture(
            now: { time }, pause: { time += $0 }, checkCancellation: {}, sample: { _ in
                count += 1; time += 0.6
                let frame = count == 1 ? first : second
                trace.record(frame, phase: "stability", started: 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: trace.directory.path))
                return frame
            })
        XCTAssertEqual(count, 3)
        trace.stability = sampled.metadata["postActionStability"]
        let final = CapturedObservation(nodes: [], metadata: ["postActionStability": [
            "stable": false, "reason": "changed_during_ax_capture"
        ]], screenshot: second.screenshot)
        trace.record(final, phase: "finalObservation", started: 0)
        let result = trace.complete(final)
        XCTAssertEqual(result.screenshot, final.screenshot)
        XCTAssertEqual((result.metadata["postActionDiagnostics"] as? [String: Any])?["exported"] as? Bool, true)
        let manifest = try jsonObject(Data(contentsOf: trace.directory.appendingPathComponent("manifest.json")))
        let samples = try XCTUnwrap(manifest["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual((manifest["stabilityBeforeAX"] as? [String: Any])?["samples"] as? Int, 3)
        for (index, sample) in samples.enumerated() {
            let name = try XCTUnwrap(sample["screenshot"] as? String)
            let saved = try Data(contentsOf: trace.directory.appendingPathComponent(name))
            XCTAssertEqual(saved, index == 0 ? first.screenshot : second.screenshot)
            XCTAssertNotNil(sample["startedUptime"])
            XCTAssertNotNil(sample["finishedUptime"])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: trace.directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testBoundedRetentionReportsDroppedFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = try NativePostActionStabilityTests().frame()
        for (bytes, frames) in [(frame.screenshot.count, 8), (1024 * 1024, 1)] {
            let trace = NativePostActionDiagnostics(root: root, maximumBytes: bytes, maximumFrames: frames)
            for _ in 0..<3 { trace.record(frame, phase: "stability", started: 0) }
            let result = trace.complete(frame)
            let facts = try XCTUnwrap(result.metadata["postActionDiagnostics"] as? [String: Any])
            XCTAssertEqual(facts["retainedFrames"] as? Int, 1)
            XCTAssertEqual(facts["droppedFrames"] as? Int, 2)
        }
    }

    func testExportFailureDoesNotReplaceObservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = NativePostActionDiagnostics(root: root)
        let frame = try NativePostActionStabilityTests().frame()
        trace.record(frame, phase: "stability", started: 0)
        let result = trace.complete(frame)
        XCTAssertEqual(result.screenshot, frame.screenshot)
        XCTAssertEqual((result.metadata["postActionDiagnostics"] as? [String: Any])?["exported"] as? Bool, false)
    }

    func testFailedCaptureRetainsEarlierFramesAndFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = NativePostActionDiagnostics(root: root)
        trace.record(try NativePostActionStabilityTests().frame(), phase: "stability", started: 0)
        let error = IPhoneUseError("device_locked", "locked")
        trace.record(error, started: 1)
        trace.fail(error)
        let manifest = try jsonObject(Data(contentsOf: trace.directory.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest["outcome"] as? String, "failed")
        XCTAssertEqual(manifest["errorCode"] as? String, "device_locked")
        XCTAssertEqual((manifest["samples"] as? [[String: Any]])?.count, 2)
    }
}
