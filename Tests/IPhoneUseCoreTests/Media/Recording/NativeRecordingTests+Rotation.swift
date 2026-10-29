import XCTest
@testable import IPhoneUseCore

extension NativeRecordingTests {
    func testFrameRotationEndsSegmentBeforeWritingChangedAxesAndRetainsPreview() throws {
        for shared in [false, true] {
            let dir = try root(), units = Array(try fixture(dir).prefix(4)), source = RecordingSource()
            let snapshots = shared ? fixtureSnapshots() : nil
            defer { snapshots?.close() }
            if let snapshots {
                source.setVideoHandler { snapshots.receive($0, at: ProcessInfo.processInfo.systemUptime) }
            }
            let recorder = fixtureRecorder(root: dir)
            defer { _ = recorder.close() }
            let started = try recorder.start(
                duration: 30, receiver: source, mediaID: "unchanged", rotation: "rot0", snapshots: snapshots)
            packets(units, to: source, rotationProfiles: [
                units[0].timestamp: 0x90, units[1].timestamp: 0x90,
                units[2].timestamp: 0x93, units[3].timestamp: 0x93
            ])
            let ended = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !recorder.isActive }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 5), .completed)
            let result = try recorder.stop(id: XCTUnwrap(started["recordingID"] as? String))
            XCTAssertEqual(result["stopReason"] as? String, "display_changed")
            XCTAssertEqual(result["writtenFrames"] as? Int, 2)
            XCTAssertEqual(result["fileValidated"] as? Bool, true)
            XCTAssertEqual(source.attached, shared)
            if let snapshots {
                XCTAssertEqual(snapshots.previewFrame()?.displayRotation, "rot90")
                XCTAssertEqual(snapshots.status()["closed"] as? Bool, false)
            }
        }
    }
}
