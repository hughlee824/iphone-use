import XCTest
@testable import IPhoneUseCore

extension AXPObservationTests {
    func testPasteRequestsOneScreenshotAfterAXFinishes() throws {
        let readFinished = DispatchSemaphore(value: 0), image = try screenshot()
        var images = 0
        let result = try AXPObservation.capture(device: "device", generation: "generation", axFirst: true, read: { _ in
            defer { readFinished.signal() }
            return self.payload()
        }, screenshot: {
            XCTAssertEqual(readFinished.wait(timeout: .now()), .success)
            images += 1
            return image
        }, checkCancellation: {})
        XCTAssertEqual(images, 1)
        let timing = try XCTUnwrap(result.metadata["observationAcquisition"] as? [String: Any])
        XCTAssertEqual(timing["strategy"] as? String, "ax_then_screenshot")
        XCTAssertEqual(result.nodes.count, 3)
        XCTAssertNil(result.metadata["postActionStability"])
    }

    func testAXAndScreenshotOverlapAndPublishOnlyAfterBothComplete() throws {
        let image = try screenshot()
        for axFinishesFirst in [false, true] {
            let axEntered = DispatchSemaphore(value: 0), imageEntered = DispatchSemaphore(value: 0)
            let axDone = DispatchSemaphore(value: 0), imageDone = DispatchSemaphore(value: 0)
            let result = try AXPObservation.capture(device: "device", generation: "generation", read: { _ in
                axEntered.signal()
                XCTAssertEqual(imageEntered.wait(timeout: .now() + 2), .success)
                if !axFinishesFirst { XCTAssertEqual(imageDone.wait(timeout: .now() + 2), .success) }
                defer { axDone.signal() }
                return self.payload()
            }, screenshot: {
                imageEntered.signal()
                XCTAssertEqual(axEntered.wait(timeout: .now() + 2), .success)
                if axFinishesFirst { XCTAssertEqual(axDone.wait(timeout: .now() + 2), .success) }
                defer { imageDone.signal() }
                return image
            }, checkCancellation: {})
            XCTAssertEqual(result.nodes.count, 3)
            XCTAssertEqual(result.screenshot, image.screenshot)
            let timing = try XCTUnwrap(result.metadata["observationAcquisition"] as? [String: Any])
            XCTAssertEqual(timing["intervalsOverlap"] as? Bool, true)
        }
    }

    func testScreenshotFailureCancelsAndJoinsAXWithoutPublishingPartialObservation() throws {
        let started = DispatchSemaphore(value: 0), cleaned = NativeCancellation()
        XCTAssertThrowsError(try AXPObservation.capture(device: "device", generation: "generation", read: { cancelled in
            defer { cleaned.cancel() }
            started.signal()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !cancelled(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertTrue(cancelled())
            throw IPhoneUseError("ax_cancelled", "cleanup complete")
        }, screenshot: {
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            throw IPhoneUseError("image_failed", "original screenshot failure")
        }, checkCancellation: {})) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "image_failed")
        }
        XCTAssertTrue(cleaned.isCancelled, "No late AX work may outlive the failed observation")
    }

    func testSessionCancellationAfterImageCancelsAXAndDoesNotPublish() throws {
        let image = try screenshot(), cancellation = NativeCancellation(), cleaned = NativeCancellation()
        let started = DispatchSemaphore(value: 0)
        XCTAssertThrowsError(try AXPObservation.capture(device: "device", generation: "generation", read: { cancelled in
            defer { cleaned.cancel() }
            started.signal()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !cancelled(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertTrue(cancelled())
            return self.payload()
        }, screenshot: {
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            cancellation.cancel()
            return image
        }, checkCancellation: { try cancellation.check() })) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_cancelled")
        }
        XCTAssertTrue(cleaned.isCancelled)
    }

    func testUnavailableAXStillUsesExactlyOneScreenshotAndOneCacheIdentity() throws {
        let image = try screenshot()
        var images = 0
        let result = try AXPObservation.capture(device: "device", generation: "generation", read: { _ in
            throw IPhoneUseError("axp_unavailable", "helper timed out")
        }, screenshot: { images += 1; return image }, checkCancellation: {})
        XCTAssertEqual(images, 1)
        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertEqual(result.metadata["axStatus"] as? String, "unavailable")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ObservationCache(directory: root)
        let response = try cache.store(result)
        XCTAssertEqual(response["observation"] as? String, "o1")
        XCTAssertEqual(response["refs"] as? String, "current")
        XCTAssertNil(response["axComparisonScreenshot"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("observations/o1/ax-before.png").path))
        _ = try cache.store(image)
        XCTAssertThrowsError(try cache.resolveCurrent(ObservationReference("o1:e1")))
    }
}
