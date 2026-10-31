import XCTest
import CoreImage
@testable import IPhoneUseCore

extension NativePreviewTests {
    func testViewerDemandIsBoundedExpiresAndUsesLargestActiveWindow() {
        var demand = NativePreviewDemand()
        let first = UUID(), second = UUID()
        func query(_ id: UUID, _ edge: Int) -> [URLQueryItem] {
            [.init(name: "viewer", value: id.uuidString), .init(name: "longEdge", value: String(edge))]
        }
        XCTAssertTrue(demand.update(query: query(first, 1800), now: 0))
        XCTAssertTrue(demand.update(query: query(second, 800), now: 1))
        XCTAssertEqual(demand.longEdge, 1800)
        XCTAssertTrue(demand.update(query: query(first, 600), now: 2))
        XCTAssertEqual(demand.longEdge, 800)
        XCTAssertTrue(demand.update(query: query(second, 0), now: 3))
        XCTAssertEqual(demand.longEdge, 600)
        XCTAssertFalse(demand.update(query: query(first, 999999), now: 3))
        XCTAssertFalse(demand.update(query: [.init(name: "longEdge", value: "NaN")], now: 3))
        XCTAssertEqual(demand.longEdge, 600)
        for _ in 0..<7 { XCTAssertTrue(demand.update(query: query(UUID(), 700), now: 3)) }
        XCTAssertFalse(demand.update(query: query(UUID(), 1000), now: 3))
        demand.expire(now: 8)
        XCTAssertEqual(demand.longEdge, 960)
    }

    func testResizeReencodesQuietScreenWithoutChangingStreamGeneration() throws {
        try withPreviewReceiver { receiver, send in
            let preview = try NativePreview(port: 0)
            defer { preview.close() }
            preview.attach(receiver, display: try previewDisplay(backlight: "activeOn"))
            send(1)
            let encoded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                preview.status()["encodedFrames"] as? Int == 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [encoded], timeout: 2), .completed)
            let generation = preview.status()["generation"] as? String
            let target = preview.url + "frame?viewer=\(UUID().uuidString)&longEdge=6"
            XCTAssertEqual(try get(XCTUnwrap(URL(string: target))).0, 200)
            let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                preview.status()["encodedFrames"] as? Int == 2
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 2), .completed)
            let jpeg = try get(XCTUnwrap(URL(string: target))).1
            let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.height, 6)
            XCTAssertEqual(preview.status()["generation"] as? String, generation)
        }
    }

    func testLateOldResolutionCannotOverwriteNewEncodeOfSameSourceFrame() throws {
        try withPreviewReceiver { receiver, send in
            let started = expectation(description: "old size started"), release = DispatchSemaphore(value: 0)
            let preview = try NativePreview(port: 0, encodeFrame: { _, _, _, edge in
                if edge == 960 { started.fulfill(); _ = release.wait(timeout: .now() + 5) }
                return .init(data: Data(String(edge).utf8))
            })
            defer { release.signal(); preview.close() }
            preview.attach(receiver, display: try previewDisplay(backlight: "activeOn")); send(1)
            wait(for: [started], timeout: 2)
            preview.queue.sync {
                XCTAssertTrue(preview.demand.update(query: [
                    .init(name: "viewer", value: UUID().uuidString), .init(name: "longEdge", value: "1800")
                ], now: ProcessInfo.processInfo.systemUptime))
                preview.refreshResolution()
            }
            let encoded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                preview.status()["encodedFrames"] as? Int == 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [encoded], timeout: 2), .completed)
            release.signal()
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                preview.status()["encodingInFlight"] as? Bool == false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 2), .completed)
            XCTAssertEqual(try get(XCTUnwrap(URL(string: preview.url + "frame"))).1, Data("1800".utf8))
            XCTAssertEqual(preview.status()["encodedFrames"] as? Int, 1)
            XCTAssertEqual(preview.status()["discardedEncodes"] as? Int, 1)
        }
    }
}
