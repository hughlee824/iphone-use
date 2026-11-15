import Foundation
import XCTest
import IPhoneUseRunnerSupport
@testable import IPhoneUseCore

extension AXPObservationTests {
    func testSingleScreenshotHasRequestTimingWithoutInventedComparison() throws {
        let image = try screenshot()
        var captures = 0
        let result = try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in self.payload() },
            screenshot: { captures += 1; return image }, checkCancellation: {})
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(result.nodes.count, 3)
        XCTAssertEqual(result.screenshot, image.screenshot)
        XCTAssertNil(result.axComparisonScreenshot)
        XCTAssertNil(result.metadata["axScreenComparison"])
        XCTAssertNil(result.metadata["axScreenConsistent"])
        let timing = try XCTUnwrap(result.metadata["observationAcquisition"] as? [String: Any])
        XCTAssertEqual(timing["strategy"] as? String, "parallel_ax_screenshot")
        XCTAssertEqual(timing["atomic"] as? Bool, false)
        XCTAssertEqual(timing["clock"] as? String, "host_unix_seconds")
        for key in ["ax", "screenshot"] {
            let interval = try XCTUnwrap(timing[key] as? [String: Double])
            XCTAssertLessThanOrEqual(try XCTUnwrap(interval["startedAt"]), try XCTUnwrap(interval["finishedAt"]))
        }
    }

    func testContextDiagnosticsRetainMissingVersusNullAndImageShortCircuit() throws {
        let initial = try screenshot()
        var metadata = initial.metadata
        metadata.removeValue(forKey: "displayUniqueID")
        metadata["sessionGeneration"] = "replacement"
        let changed = CapturedObservation(nodes: [], metadata: metadata, screenshot: Data())
        let comparison = try AXPScreenComparison(initial, changed)
        XCTAssertFalse(comparison.equivalent)
        XCTAssertEqual(comparison.result["contextMismatchKeys"] as? [String], ["sessionGeneration", "displayUniqueID"])
        XCTAssertEqual(comparison.result["afterMissingContextKeys"] as? [String], ["displayUniqueID"])
        XCTAssertEqual(comparison.result["pixelComparisonPerformed"] as? Bool, false)
        XCTAssertNil(comparison.result["pixelComparison"])
        metadata = initial.metadata; metadata["displayUniqueID"] = NSNull()
        let nullDisplay = CapturedObservation(nodes: [], metadata: metadata, screenshot: initial.screenshot)
        XCTAssertTrue(try AXPScreenComparison(nullDisplay, nullDisplay).equivalent)
        XCTAssertThrowsError(try AXPScreenComparison(
            initial, CapturedObservation(nodes: [], metadata: initial.metadata, screenshot: Data())))
    }

    func testFailureAndStaleSnapshotKeepTimingAndRemainDistinct() throws {
        let image = try screenshot()
        let failed = try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in throw IPhoneUseError("timeout", "fixture") },
            screenshot: { image }, checkCancellation: {})
        XCTAssertNotNil(failed.metadata["observationAcquisition"])
        XCTAssertEqual(failed.metadata["axErrorCode"] as? String, "timeout")
        var old = payload(); old["startedAt"] = Date().timeIntervalSince1970 - 60
        let stale = try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in old },
            screenshot: { image }, checkCancellation: {})
        XCTAssertNotNil(stale.metadata["observationAcquisition"])
        XCTAssertEqual(stale.metadata["axErrorCode"] as? String, "axp_context_changed")
    }

    func testLegacyComparisonEvidenceFollowsCacheLifetimeAndExplicitArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try screenshot()
        var capture = try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in self.payload() },
            screenshot: { initial }, checkCancellation: {})
        capture.axComparisonScreenshot = initial.screenshot // Legacy/explicit evidence, not normal capture.
        let cache = ObservationCache(directory: root)
        let response = try cache.store(capture)
        let path = try XCTUnwrap(response["axComparisonScreenshot"] as? String)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), initial.screenshot)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
        let inspected = try cache.inspect(ObservationReference("o1"), offset: 0)
        XCTAssertEqual(inspected["axComparisonScreenshot"] as? String, path)
        let archived = EvidenceArchive.render(
            ["ok": true, "result": response], directory: root.appendingPathComponent("archive"))
        XCTAssertNil(archived["archiveErrors"])
        let saved = try XCTUnwrap((archived["artifacts"] as? [String: String])?["axComparisonScreenshot"])
        XCTAssertNil(try cache.store(initial)["axComparisonScreenshot"])
        _ = try cache.store(capture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: saved)), initial.screenshot)
    }
}
