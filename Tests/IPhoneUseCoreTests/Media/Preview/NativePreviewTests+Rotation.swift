import XCTest
import CoreImage
@testable import IPhoneUseCore

extension NativePreviewTests {
    func testTaggedRunnerPreviewDoesNotRebindForAsynchronousXCTestOrientation() throws {
        try withPreviewReceiver(profiles: [1: 0x93]) { receiver, send in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try SessionPaths.secureDirectory(root)
            defer { try? FileManager.default.removeItem(at: root) }
            let connection = RunnerRecordingConnectionStub()
            connection.previewVideo = receiver
            connection.previewDisplayOverride = try previewDisplay(backlight: "activeOn")
            var probes = 0
            let owner = RunnerNativeRecording(
                root: root, cancellation: NativeCancellation(),
                previewGeometry: {
                    probes += 1
                    return RunnerPreviewGeometry(width: 12, height: 18, orientation: 8)
                }, connect: { connection })
            defer { _ = owner.close() }
            let started = try owner.startPreview(options: .init(port: 0))
            send(1)
            let published = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in owner.previewStatus["rotation"] as? String == "rot90" },
                object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 2), .completed)
            let before = probes
            XCTAssertTrue(owner.previewTick(), "Published rotation invalidates observations")
            XCTAssertFalse(owner.previewTick())
            XCTAssertEqual(probes, before, "A differently timed XCTest snapshot cannot override this frame")
            XCTAssertEqual(connection.previewRefreshes, 0)
            XCTAssertEqual(owner.previewStatus["generation"] as? String, started["generation"] as? String)
        }
    }

    func testTaggedRotationsKeepReceiverGenerationAndHTTPFramesAvailable() throws {
        try withPreviewReceiver(profiles: [1: 0x90, 2: 0x93, 3: 0x92, 4: 0x90]) { receiver, send in
            let preview = try NativePreview(port: 0)
            defer { preview.close() }
            let bound = try previewDisplay(backlight: "activeOn")
            preview.attach(receiver, display: bound)
            let generation = preview.status()["generation"] as? String
            let url = try XCTUnwrap(URL(string: preview.url + "frame"))
            for (index, rotation) in ["rot0", "rot90", "rot270", "rot0"].enumerated() {
                send(UInt8(index + 1))
                let published = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        preview.status()["encodedFrames"] as? Int == index + 1
                    }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 2), .completed)
                XCTAssertEqual(preview.status()["generation"] as? String, generation)
                XCTAssertEqual(preview.status()["rotation"] as? String, rotation)
                XCTAssertTrue(preview.queue.sync { preview.receiver === receiver })
                XCTAssertEqual(preview.takeRotationChange(), index > 0)
                XCTAssertFalse(preview.takeRotationChange())
                let response = try get(url)
                XCTAssertEqual(response.0, 200)
                let image = try XCTUnwrap(CGImageSourceCreateWithData(response.1 as CFData, nil))
                let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
                XCTAssertEqual(pixels.width, rotation == "rot0" ? 12 : 18)
                XCTAssertEqual(pixels.height, rotation == "rot0" ? 18 : 12)
            }
        }
    }
}

extension NativePreviewResolutionTests {
    func testFrameRotationPreservesPixelsWithStaleCoreDeviceAxes() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for (width, height) in [(64, 128), (32, 48)] {
            let pixels = try pixels(activeWidth: width, activeHeight: height)
            var frame = NativeVideoSnapshot.Frame(
                image: .init(pixels: pixels, nativeWidth: 48, nativeHeight: 96,
                             activeWidth: width, activeHeight: height),
                firstPacketAt: 1, completedAt: 2, timestamp: 1)
            for rotation in ["rot0", "rot90", "rot270"] {
                frame.displayRotation = nil
                let expected = try NativePreview.encode(frame, display: display(rotation), context: context)
                frame.displayRotation = rotation
                for bound in ["rot0", "rot90", "rot270"] {
                    XCTAssertEqual(
                        try NativePreview.encode(frame, display: display(bound), context: context), expected)
                }
            }
            frame.displayRotation = nil
            XCTAssertNil(NativePreviewGeometry.continuousDisplay(
                frame: frame, bound: try display(), current: try display()))
            frame.displayRotation = "rot90"
            let different = try NativeDisplay([
                "displays": [["primary": true, "displayId": 2, "bounds": [[0, 0], [48, 96]],
                              "pointScale": 1, "nativeOrientation": "rot0", "currentOrientation": "rot90"]]
            ])
            XCTAssertNil(NativePreviewGeometry.continuousDisplay(
                frame: frame, bound: try display(), current: different))
            frame.displayRotation = "rot180"
            XCTAssertThrowsError(try NativePreview.encode(frame, display: display()))
        }
    }
}
