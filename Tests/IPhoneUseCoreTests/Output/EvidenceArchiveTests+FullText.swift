import Foundation
import XCTest
@testable import IPhoneUseCore

extension EvidenceArchiveTests {
    func testCompleteAXTextIsArchivedWithoutChangingActionFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        let data = Data(String(repeating: "完整😀正文\n", count: 20000).utf8)
        try data.write(to: source)
        let response: [String: Any] = ["ok": false, "action": ["outcome": "unknown"], "observation": [
            "ok": true, "result": ["fullText": source.path, "outputDeferred": true]
        ]]
        let archived = EvidenceArchive.render(response, directory: root, agentOutput: true)
        XCTAssertNil(archived["archiveErrors"])
        XCTAssertEqual((archived["action"] as? [String: Any])?["outcome"] as? String, "unknown")
        let path = try XCTUnwrap((archived["artifacts"] as? [String: String])?["fullText"])
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
    }
}
