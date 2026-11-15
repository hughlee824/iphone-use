import Foundation
import XCTest
@testable import IPhoneUseCore

final class ObservationWorkerOutputTests: XCTestCase {
    func testFramingAndCumulativeTrafficDoNotGrowTheQueue() throws {
        let output = ObservationWorkerOutput()
        let payload = String(repeating: "a", count: 1024 * 1024)
        let data = try jsonData(["payload": payload])
        for _ in 0..<66 {
            output.append(data.prefix(17))
            XCTAssertNil(try output.next())
            output.append(data.dropFirst(17)); output.append(Data([10]))
            XCTAssertEqual(try output.next()?["payload"] as? String, payload)
        }
    }
    func testPartialEOFAndExcessFramesFailClosed() {
        let partial = ObservationWorkerOutput()
        partial.append(Data("{\"value\":".utf8)); partial.finish()
        XCTAssertThrowsError(try partial.next())
        let excessive = ObservationWorkerOutput()
        excessive.append(Data(String(repeating: "{}\n", count: 5).utf8))
        XCTAssertThrowsError(try excessive.next())
    }
    func testSingleOversizeFrameFailsBeforeJSONParsing() {
        let output = ObservationWorkerOutput()
        output.append(Data(repeating: 120, count: ObservationWorkerOutput.maximumFrame + 1))
        XCTAssertThrowsError(try output.next())
    }

    func testEveryUnicodeSplitAndBytewiseFraming() throws {
        let text = "\u{FEFF}中文 👩🏽‍💻\nsecond line"
        var data = try jsonData(["text": text])
        // Compare with the existing JSON decoder; framing must not change its
        // interpretation (including Foundation's treatment of leading U+FEFF).
        let expected = try jsonObject(data)["text"] as? String
        data.append(10)
        for split in 0...data.count {
            let output = ObservationWorkerOutput()
            output.append(data.prefix(split))
            if split < data.count { XCTAssertNil(try output.next()) }
            output.append(data.dropFirst(split))
            XCTAssertEqual(try output.next()?["text"] as? String, expected)
            XCTAssertNil(try output.next())
        }
        let output = ObservationWorkerOutput()
        for byte in data.dropLast() {
            output.append(Data([byte])); XCTAssertNil(try output.next())
        }
        output.append(Data([10]))
        XCTAssertEqual(try output.next()?["text"] as? String, expected)
    }

    func testScanOffsetResetsAfterEachFrameWithNonzeroDataIndices() throws {
        for chunkSize in 1...23 {
            let output = ObservationWorkerOutput()
            let stream = Data((0..<20).map { "{\"index\":\($0)}\n" }.joined().utf8)
            var received = [Int]()
            for offset in stride(from: 0, to: stream.count, by: chunkSize) {
                output.append(stream[offset..<min(offset + chunkSize, stream.count)])
                while let frame = try output.next() { received.append(try XCTUnwrap(frame["index"] as? Int)) }
            }
            XCTAssertEqual(received, Array(0..<20))
            output.finish()
            assertError(output, "observation_worker_closed")
        }
    }

    func testQueueFinishAndMalformedFrameSemantics() throws {
        let output = ObservationWorkerOutput()
        output.append(Data("{}\n{}\n{}\n{}\n".utf8)); output.finish()
        output.append(Data("unexpected".utf8))
        for _ in 0..<4 { XCTAssertNotNil(try output.next()) }
        assertError(output, "observation_worker_closed")
        for suffix in ["{", "\u{FEFF}"] {
            let partial = ObservationWorkerOutput()
            partial.append(Data(("{}\n" + suffix).utf8)); partial.finish()
            assertError(partial, "observation_worker_invalid")
        }
        for invalid in ["", "broken"] {
            let malformed = ObservationWorkerOutput()
            malformed.append(Data((invalid + "\n{}\n").utf8))
            XCTAssertThrowsError(try malformed.next())
            XCTAssertNotNil(try malformed.next())
        }
    }

    func testExactFrameLimitAndAggregateQueueBudget() throws {
        let exact = ObservationWorkerOutput()
        var data = Data("{}".utf8)
        data.append(Data(repeating: 32, count: ObservationWorkerOutput.maximumFrame - 2))
        exact.append(data); XCTAssertNil(try exact.next())
        exact.append(Data([10])); XCTAssertNotNil(try exact.next())
        let oversized = ObservationWorkerOutput()
        oversized.append(data); oversized.append(Data([32, 10]))
        assertError(oversized, "observation_worker_invalid")
        let queued = ObservationWorkerOutput()
        let chunk = Data(repeating: 32, count: 22 * 1024 * 1024)
        for _ in 0..<3 { queued.append(chunk); queued.append(Data([10])) }
        assertError(queued, "observation_worker_invalid")
        queued.append(Data("{}\n".utf8))
        assertError(queued, "observation_worker_invalid")
    }

    private func assertError(_ output: ObservationWorkerOutput, _ code: String) {
        XCTAssertThrowsError(try output.next()) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, code) }
    }
}
