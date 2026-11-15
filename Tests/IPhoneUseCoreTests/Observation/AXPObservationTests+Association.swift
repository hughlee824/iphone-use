import XCTest
@testable import IPhoneUseCore

extension AXPObservationTests {
    func testChangedContentKeepsAXAndExplainsNonAtomicEvidenceInOutput() throws {
        let initial = try screenshot()
        let changed = CapturedObservation(nodes: [], metadata: initial.metadata,
            screenshot: try screenPNG(patches: [(CGRect(x: 20, y: 180, width: 300, height: 400), [0, 0, 0])]))
        let capture = try AXPObservation.capture(device: "device", generation: "generation",
            read: { _ in self.payload() }, screenshot: { changed }, checkCancellation: {})
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try ObservationCache(directory: root).store(capture)
        let text = try XCTUnwrap(output["text"] as? String)
        XCTAssertTrue(text.contains("ax=available"))
        XCTAssertTrue(text.contains("observation_atomic=false acquisition=parallel_ax_screenshot"))
        XCTAssertTrue(text.contains("atomic=false element_actions=false"))
        XCTAssertEqual(capture.nodes.count, 3)
        XCTAssertEqual(capture.screenshot, changed.screenshot)
    }

    func testIdentityAndGeometryConflictsStillDiscardAXEvenWithChangedPixels() throws {
        let initial = try screenshot()
        for (key, value): (String, Any) in [
            ("displayID", 2),
            ("displayUniqueID", "other"), ("displayRotation", "rot90"),
            ("screenFrame", ["x": 0, "y": 0, "width": 844, "height": 390])
        ] {
            var metadata = initial.metadata; metadata[key] = value
            let capture = try AXPObservation.capture(device: "device", generation: "generation",
                read: { _ in self.payload() }, screenshot: {
                    CapturedObservation(nodes: [], metadata: metadata, screenshot: initial.screenshot)
                }, checkCancellation: {})
            XCTAssertEqual(capture.metadata["axStatus"] as? String, "unavailable", key)
            XCTAssertTrue(capture.nodes.isEmpty, key)
        }
        var wrongDevice = initial.metadata; wrongDevice["deviceID"] = "other"
        XCTAssertThrowsError(try AXPObservation.capture(device: "device", generation: "generation",
            read: { _ in self.payload() }, screenshot: {
                CapturedObservation(nodes: [], metadata: wrongDevice, screenshot: initial.screenshot)
            }, checkCancellation: {}))
    }
}
