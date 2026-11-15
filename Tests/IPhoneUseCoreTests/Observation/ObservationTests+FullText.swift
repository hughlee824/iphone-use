import XCTest
@testable import IPhoneUseCore

extension ObservationTests {
    func largeTextCapture(_ value: String, count: Int = 1) throws -> CapturedObservation {
        let nodes = (0..<count).map { index in
            AXNode(index: index, parent: nil, role: "text_field", attributes: [
                "index": index, "parent": NSNull(), "label": "Field \(index)", "value": value,
                "enabled": false, "keyboardFocus": false
            ])
        }
        return CapturedObservation(nodes: nodes, metadata: ["axStatus": "available"], screenshot: try screenPNG())
    }

    func readAllText(_ result: [String: Any], cache: ObservationCache) throws -> Data {
        let id = try XCTUnwrap(result["outputID"] as? String)
        let reference = try ObservationReference(XCTUnwrap(result["observation"] as? String))
        var data = Data(), offset = 0
        repeat {
            let chunk = try cache.inspectText(reference, outputID: id, byteOffset: offset)
            XCTAssertLessThan(try jsonData(chunk).count, ObservationCache.inlineTextLimit)
            XCTAssertEqual(chunk["byteOffset"] as? Int, offset)
            let content = try XCTUnwrap(chunk["content"] as? String)
            data.append(Data(content.utf8))
            if chunk["outputComplete"] as? Bool == true { break }
            let next = try XCTUnwrap(chunk["nextByteOffset"] as? Int)
            guard next > offset else {
                XCTFail("Incomplete output must advance its byte offset")
                return data
            }
            offset = next
        } while offset < (result["totalBytes"] as? Int ?? 0)
        XCTAssertEqual(data.count, result["totalBytes"] as? Int)
        return data
    }

    func testNormalLongAttributesReturnInFullBeyondOldLimits() throws {
        let value = String(repeating: "北京😀e\u{301}\n", count: 800)
        let capture = try largeTextCapture(value)
        let (cache, _) = try cache()
        let observed = try cache.store(capture)
        let text = try XCTUnwrap(observed["text"] as? String)
        XCTAssertGreaterThan(text.utf8.count, 8192)
        XCTAssertTrue(text.contains(quoted(value)))
        XCTAssertNil(observed["outputDeferred"])
        for query: String? in [nil, "Field"] {
            let result = try cache.inspect(ObservationReference("o1"), offset: 0, query: query)
            let nodes = try queryNodes(result)
            XCTAssertEqual(nodes[0]["value"] as? String, value)
            XCTAssertEqual(nodes[0]["enabled"] as? Bool, false)
            XCTAssertNil(nodes[0]["detail_clipped"])
        }
    }

    func testOversizedUnicodeObserveAndInspectReassembleExactlyWithLiveValidity() throws {
        let value = String(repeating: "北京👨‍👩‍👧‍👦e\u{301}\\\"\n", count: 12000)
        let (cache, _) = try cache()
        let observed = try cache.store(largeTextCapture(value))
        XCTAssertEqual(observed["outputDeferred"] as? Bool, true)
        XCTAssertEqual(observed["axStatus"] as? String, "available")
        let file = try XCTUnwrap(observed["fullText"] as? String)
        XCTAssertEqual(try readAllText(observed, cache: cache), try Data(contentsOf: URL(fileURLWithPath: file)))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int, 0o600)
        let document = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(document.contains(quoted(value)))
        XCTAssertFalse(document.contains("refs=current"))
        cache.invalidate("action_pending")
        let id = try XCTUnwrap(observed["outputID"] as? String)
        let part = try cache.inspectText(ObservationReference("o1"), outputID: id, byteOffset: 0)
        XCTAssertEqual(part["refs"] as? String, "action_pending")
        XCTAssertThrowsError(try cache.resolveCurrent(ObservationReference("o1:e1")))
        for query: String? in [nil, "Field"] {
            let detail = try cache.inspect(ObservationReference("o1:e1"), offset: 0, query: query)
            let data = try readAllText(detail, cache: cache)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            let nodes = try queryNodes(["text": text])
            XCTAssertEqual(nodes[0]["value"] as? String, value)
            XCTAssertEqual(nodes[0]["keyboardFocus"] as? Bool, false)
            XCTAssertEqual(nodes[0]["ref"] as? String, "o1:e1")
        }
        let bytes = Array(document.utf8)
        let midScalar = try XCTUnwrap(bytes.firstIndex(where: { $0 & 0xC0 == 0x80 }))
        for offset in [-1, midScalar, bytes.count + 1] {
            XCTAssertThrowsError(try cache.inspectText(ObservationReference("o1"), outputID: id, byteOffset: offset))
        }
        let end = try cache.inspectText(ObservationReference("o1"), outputID: id, byteOffset: bytes.count)
        XCTAssertEqual(end["content"] as? String, "")
        XCTAssertEqual(end["outputComplete"] as? Bool, true)
    }

    func testEscapedControlCharactersRespectEncodedResponseBudget() throws {
        let (cache, _) = try cache()
        let value = String(repeating: "\u{1}\"\\", count: 40000)
        let observed = try cache.store(largeTextCapture(value))
        XCTAssertLessThan(try jsonData(observed).count, ObservationCache.inlineTextLimit)
        let restored = try readAllText(observed, cache: cache)
        XCTAssertTrue(try XCTUnwrap(String(data: restored, encoding: .utf8)).contains(quoted(value)))
    }

    func testOutputsAreBoundedScopedDeduplicatedAndEvictedWithObservation() throws {
        let (cache, _) = try cache()
        let capture = try largeTextCapture(String(repeating: "文", count: 60000), count: 6)
        _ = try cache.store(capture)
        let first = try cache.inspect(ObservationReference("o1:e1"), offset: 0)
        let repeated = try cache.inspect(ObservationReference("o1:e1"), offset: 0)
        XCTAssertEqual(first["outputID"] as? String, repeated["outputID"] as? String)
        for index in 2...6 { _ = try cache.inspect(ObservationReference("o1:e\(index)"), offset: 0) }
        XCTAssertEqual(cache.textOutputs["o1"]?.count, ObservationCache.cachedTextLimit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(first["fullText"] as? String)))
        XCTAssertThrowsError(try cache.inspectText(
            ObservationReference("o1"), outputID: XCTUnwrap(first["outputID"] as? String), byteOffset: 0))
        _ = try cache.store(largeTextCapture("new"))
        let last = try XCTUnwrap(cache.textOutputs["o1"]?.last)
        XCTAssertThrowsError(try cache.inspectText(ObservationReference("o2"), outputID: last.id, byteOffset: 0))
        _ = try cache.store(largeTextCapture("newer"))
        XCTAssertNil(cache.textOutputs["o1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: last.file.path))
        try cache.clear()
        XCTAssertTrue(cache.textOutputs.isEmpty)
    }
}
