import XCTest
import CoreImage
@testable import IPhoneUseCore

extension NativePreviewResolutionTests {

    func testPostBindValidationAcceptsOnlySameSurfaceAndMatchingFrame() throws {
        var frame = NativeVideoSnapshot.Frame(
            image: .init(pixels: try pixels(activeWidth: 64, activeHeight: 128), nativeWidth: 48, nativeHeight: 96),
            firstPacketAt: 1, completedAt: 2, timestamp: 1)
        for rotation in ["rot0", "rot90", "rot180", "rot270"] {
            let current = try display(rotation)
            XCTAssertEqual(try NativePreviewGeometry.revalidatedDisplay(
                frame: frame, bound: display("rot90"), current: current), current)
        }
        frame.displayRotation = "rot90"
        XCTAssertThrowsError(try NativePreviewGeometry.revalidatedDisplay(
            frame: frame, bound: display("rot90"), current: display("rot180")))
        XCTAssertThrowsError(try NativePreviewGeometry.revalidatedDisplay(
            frame: nil, bound: display(), current: display()))
        let other = try NativeDisplay(["displays": [[
            "primary": true, "displayId": 2, "bounds": [[0, 0], [48, 96]],
            "pointScale": 1, "nativeOrientation": "rot0", "currentOrientation": "rot90"
        ]]])
        XCTAssertThrowsError(try NativePreviewGeometry.revalidatedDisplay(
            frame: frame, bound: display(), current: other))
        frame.displayRotation = nil
        XCTAssertThrowsError(try NativeSnapshotImage.validateGeometry(frame, display: display("rot180")),
                             "Preview support must not change the native input/recording contract")
    }

    func testNegotiatedSmallerCanvasIsPreviewOnly() throws {
        let buffer = try pixels(activeWidth: 48, activeHeight: 96)
        let frame = NativeVideoSnapshot.Frame(
            image: .init(pixels: buffer, nativeWidth: 48, nativeHeight: 96),
            firstPacketAt: 1, completedAt: 2, timestamp: 1)
        func screen(_ width: Int, _ height: Int) throws -> NativeDisplay {
            try NativeDisplay([
                "backlightState": "activeOn", "displays": [[
                    "primary": true, "displayId": 2, "bounds": [[0, 0], [width, height]],
                    "pointScale": 1, "currentOrientation": "rot0", "nativeOrientation": "rot0"
                ]]
            ])
        }
        let size = try NativeSnapshotImage.validateGeometry(
            frame, display: screen(96, 192), allowReducedResolution: true, allowScaledCanvas: true)
        XCTAssertEqual(size.width, 48)
        XCTAssertEqual(size.height, 96)
        XCTAssertThrowsError(try NativeSnapshotImage.validateGeometry(frame, display: screen(96, 192)))
        XCTAssertThrowsError(try NativeSnapshotImage.validateGeometry(
            frame, display: screen(96, 160), allowReducedResolution: true, allowScaledCanvas: true))
        XCTAssertThrowsError(try NativeSnapshotImage.validateGeometry(
            frame, display: screen(24, 48), allowReducedResolution: true, allowScaledCanvas: true))
    }

    func testReducedGeometryPreservesFreshnessBarrierAndRejectsConflicts() throws {
        let buffer = try pixels(activeWidth: 32, activeHeight: 48)
        let reduced = NativeDecodedVideoFrame(
            pixels: buffer, nativeWidth: 48, nativeHeight: 96,
            activeWidth: 32, activeHeight: 48)
        let stream = NativeVideoSnapshot(decode: { _ in reduced }, resetDecoder: {})
        let receiver = try NativeRTPReceiver(
            deviceAddress: "::1", captureSnapshots: true, makeSnapshots: { stream })
        defer { receiver.close() }
        let start = ProcessInfo.processInfo.systemUptime
        stream.receive(geometryPacket(1, profile: 0x92), at: start)
        let frame = try XCTUnwrap(
            stream.frame(
                after: start, timeout: 0.4,
                includeReducedResolution: true, cancellation: NativeCancellation()))
        XCTAssertNoThrow(
            try NativeSnapshotImage.validateGeometry(
                frame, display: display("rot270"), allowReducedResolution: true))
        XCTAssertThrowsError(
            try NativeSnapshotImage.validateGeometry(
                frame, display: display("rot90"), allowReducedResolution: true))
        XCTAssertThrowsError(
            try stream.rejectConflictingGeometry(display("rot90")),
            "Reduced frames retain half-turn conflict evidence")
        XCTAssertNil(
            try receiver.snapshot(
                after: start, timeout: 0, includeReducedResolution: true,
                cancellation: NativeCancellation()),
            "The socket barrier must exclude already decoded reduced frames")
        XCTAssertNil(
            try stream.frame(
                after: frame.completedAt + 1, timeout: 0,
                includeReducedResolution: true, cancellation: NativeCancellation()))
        XCTAssertNil(try stream.frame(after: start, timeout: 0, cancellation: NativeCancellation()))
        // Broken references cannot leave geometry usable, even when the last
        // valid reduced frame was very recent.
        stream.receive(geometryPacket(2, timestamp: 1), at: ProcessInfo.processInfo.systemUptime)
        let done = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                stream.status()["pendingBytes"] as? Int == 0
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 2), .completed)
        XCTAssertEqual(stream.status()["timestampRejections"] as? Int, 1)
        XCTAssertNil(
            try stream.frame(
                after: start, timeout: 0, includeReducedResolution: true, cancellation: NativeCancellation()))
        stream.close()
        XCTAssertNil(
            try stream.frame(
                after: start, timeout: 0, includeReducedResolution: true, cancellation: NativeCancellation()))
    }
}
