import XCTest
@testable import IPhoneUseCore

extension HostTests {
    func testOutputSegmentsDoNotRecaptureOrChangeReferenceValidity() throws {
        let backend = ControlledBackend()
        backend.captureOverride = CapturedObservation(nodes: [
            AXNode(index: 0, parent: nil, role: "text", attributes: ["label": String(repeating: "文😀", count: 30000)])
        ], metadata: ["axStatus": "available"], screenshot: try screenPNG())
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        let observed = try call(paths, session: session, op: "observe")
        let output = try XCTUnwrap((observed["result"] as? [String: Any])?["outputID"] as? String)
        let fields: [String: Any] = ["reference": "o1", "offset": 0, "output": output, "byteOffset": 0]
        for extra: [String: Any] in [
            ["reference": "o1:e1"], ["offset": 1], ["query": "文"], ["output": "../../file"],
            ["byteOffset": -1], ["byteOffset": "0"], ["output": NSNull()]
        ] {
            let invalid = try call(
                paths, session: session, op: "inspect", fields: fields.merging(extra) { _, new in new })
            XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? String, "invalid_output_read")
        }
        let chunk = try call(paths, session: session, op: "inspect", fields: fields)
        XCTAssertEqual((chunk["result"] as? [String: Any])?["outputID"] as? String, output)
        XCTAssertEqual((chunk["result"] as? [String: Any])?["refs"] as? String, "current")
        _ = try call(paths, session: session, op: "observe")
        let stale = try call(paths, session: session, op: "inspect", fields: fields)
        XCTAssertEqual((stale["result"] as? [String: Any])?["refs"] as? String, "superseded")
        XCTAssertEqual(backend.observeCount, 2)
        XCTAssertEqual(backend.actionCount, 0)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }
}
