import XCTest
@testable import IPhoneUseCore

extension ObservationTests {
    // Exercise the real output cache with exact byte boundaries independent of metadata length.
    private func cachedDocument(_ document: String, cache: ObservationCache) throws -> [String: Any] {
        let stored = try cache.store(largeTextCapture("seed"))
        let entry = try XCTUnwrap(cache.entries.last)
        var response = stored
        response["text"] = "observation=\(entry.id) refs=current\n" + document
        let output = cache.deliverText(response, entry: entry)
        XCTAssertEqual(output["outputDeferred"] as? Bool, true)
        return output
    }

    func testFEFFAtSegmentStartAndEOFIsPreservedByteForByte() throws {
        let (cache, _) = try cache()
        let document = "\u{FEFF}" + String(repeating: "a", count: 32765)
            + "\u{FEFF}" + String(repeating: "b", count: 160000) + "\u{FEFF}"
        let output = try cachedDocument(document, cache: cache)
        let id = try XCTUnwrap(output["outputID"] as? String)
        let reference = try ObservationReference("o1")
        let second = try cache.inspectText(reference, outputID: id, byteOffset: 32768)
        let content = try XCTUnwrap(second["content"] as? String)
        XCTAssertEqual(content.unicodeScalars.first?.value, 0xFEFF)
        XCTAssertEqual(second["nextByteOffset"] as? Int, 65536)
        let tail = try cache.inspectText(reference, outputID: id, byteOffset: document.utf8.count - 3)
        XCTAssertEqual(Array((tail["content"] as? String ?? "").utf8), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(tail["outputComplete"] as? Bool, true)
        XCTAssertEqual(try readAllText(output, cache: cache), Data(document.utf8))
    }

    func testValidMultibyteScalarCrossingReadBoundaryRemainsReadable() throws {
        let (cache, _) = try cache()
        let document = String(repeating: "a", count: 32767) + "😀" + String(repeating: "文", count: 60000)
        let output = try cachedDocument(document, cache: cache)
        let id = try XCTUnwrap(output["outputID"] as? String)
        let first = try cache.inspectText(ObservationReference("o1"), outputID: id, byteOffset: 0)
        XCTAssertEqual(first["bytesReturned"] as? Int, 32767)
        XCTAssertEqual(first["nextByteOffset"] as? Int, 32767)
        XCTAssertEqual(try readAllText(output, cache: cache), Data(document.utf8))
    }

    func testIncompleteUTF8AtEOFIsRejectedRatherThanReturningZeroProgress() throws {
        let (cache, _) = try cache()
        let result = try cache.store(largeTextCapture(String(repeating: "文", count: 60000)))
        let file = URL(fileURLWithPath: try XCTUnwrap(result["fullText"] as? String))
        let original = try Data(contentsOf: file)
        let id = try XCTUnwrap(result["outputID"] as? String)
        for suffix: [UInt8] in [[0xE2], [0xE2, 0x82], [0xF0, 0x9F, 0x91]] {
            var corrupted = original
            corrupted.replaceSubrange((original.count - suffix.count)..<original.count, with: suffix)
            try corrupted.write(to: file)
            for offset in [original.count - 64, original.count - suffix.count] {
                XCTAssertThrowsError(try cache.inspectText(
                    ObservationReference("o1"), outputID: id, byteOffset: offset)) { error in
                    XCTAssertEqual((error as? IPhoneUseError)?.code, "output_read_failed")
                }
            }
        }
    }

    func testRetryRebuildsDamagedOrMissingOutputWithoutRevivingReferences() throws {
        for damage in ["short", "same-size", "missing"] {
            let (cache, _) = try cache()
            let observed = try cache.store(largeTextCapture(String(repeating: "文", count: 60000)))
            let snapshot = URL(fileURLWithPath: try XCTUnwrap(observed["snapshot"] as? String))
            let originalSnapshot = try Data(contentsOf: snapshot)
            let reference = try ObservationReference("o1:e1")
            let first = try cache.inspect(reference, offset: 0)
            let oldID = try XCTUnwrap(first["outputID"] as? String)
            let oldFile = URL(fileURLWithPath: try XCTUnwrap(first["fullText"] as? String))
            let expected = try Data(contentsOf: oldFile)
            if damage == "missing" {
                try FileManager.default.removeItem(at: oldFile)
            } else {
                try Data(repeating: 0x61, count: damage == "short" ? 1 : expected.count).write(to: oldFile)
            }
            cache.invalidate("action_pending")
            let retry = try cache.inspect(reference, offset: 0)
            XCTAssertNil(retry["outputError"], damage)
            XCTAssertNotEqual(retry["outputID"] as? String, oldID, damage)
            XCTAssertEqual(retry["refs"] as? String, "action_pending")
            let newFile = URL(fileURLWithPath: try XCTUnwrap(retry["fullText"] as? String))
            XCTAssertEqual(try Data(contentsOf: newFile), expected, damage)
            XCTAssertEqual(try readAllText(retry, cache: cache), expected, damage)
            let permissions = try FileManager.default.attributesOfItem(atPath: newFile.path)[.posixPermissions]
            XCTAssertEqual(permissions as? Int, 0o600)
            XCTAssertThrowsError(try cache.resolveCurrent(reference))
            XCTAssertThrowsError(try cache.inspectText(ObservationReference("o1"), outputID: oldID, byteOffset: 0))
            XCTAssertEqual(try Data(contentsOf: snapshot), originalSnapshot)
            XCTAssertEqual(cache.entries.count, 1)
        }
    }

    func testMissingOldestFileDoesNotBlockEvictionOrFutureOutputs() throws {
        let (cache, _) = try cache()
        _ = try cache.store(largeTextCapture(String(repeating: "文", count: 60000), count: 6))
        for index in 1...3 { _ = try cache.inspect(ObservationReference("o1:e\(index)"), offset: 0) }
        XCTAssertEqual(cache.textOutputs["o1"]?.count, ObservationCache.cachedTextLimit)
        let oldest = try XCTUnwrap(cache.textOutputs["o1"]?.first)
        try FileManager.default.removeItem(at: oldest.file)
        for index in 4...5 {
            let result = try cache.inspect(ObservationReference("o1:e\(index)"), offset: 0)
            XCTAssertNil(result["outputError"])
            XCTAssertEqual(cache.textOutputs["o1"]?.count, ObservationCache.cachedTextLimit)
            XCTAssertFalse(cache.textOutputs["o1"]!.contains { $0.id == oldest.id })
            let file = URL(fileURLWithPath: try XCTUnwrap(result["fullText"] as? String))
            XCTAssertEqual(try readAllText(result, cache: cache), try Data(contentsOf: file))
        }
    }
}
