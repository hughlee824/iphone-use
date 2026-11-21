import XCTest
@testable import IPhoneUseCore

extension ObservationTests {
    func testOutputWriteFailureKeepsSnapshotAndDoesNotClaimCompleteText() throws {
        let (cache, _) = try cache()
        let blocked = cache.directory.appendingPathComponent("o1/ax-output-t1.txt")
        try SessionPaths.secureDirectory(cache.directory)
        try SessionPaths.secureDirectory(blocked.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let result = try cache.store(largeTextCapture(String(repeating: "文", count: 60000)))
        XCTAssertEqual(result["axStatus"] as? String, "available")
        XCTAssertEqual(result["refs"] as? String, "current")
        XCTAssertNotNil(result["outputError"])
        XCTAssertNil(result["outputID"])
        XCTAssertNil(result["fullText"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result["snapshot"] as? String)))
        let retry = try cache.inspect(ObservationReference("o1:e1"), offset: 0)
        XCTAssertNil(retry["outputError"])
        XCTAssertEqual(retry["observation"] as? String, "o1")
        XCTAssertNotNil(retry["fullText"])
    }

    func testDamagedCachedFileFailsWithoutLoopingOrReturningPartialSuccess() throws {
        let (cache, _) = try cache()
        let result = try cache.store(largeTextCapture(String(repeating: "文", count: 60000)))
        let path = try XCTUnwrap(result["fullText"] as? String)
        let id = try XCTUnwrap(result["outputID"] as? String)
        let reference = try ObservationReference("o1")
        try Data([0xFF]).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try cache.inspectText(reference, outputID: id, byteOffset: 0))
        try Data(repeating: 0xFF, count: 32 * 1024).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try cache.inspectText(reference, outputID: id, byteOffset: 0))
    }
}
