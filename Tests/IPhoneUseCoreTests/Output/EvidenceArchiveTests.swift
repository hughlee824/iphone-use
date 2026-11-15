import Foundation
import XCTest
@testable import IPhoneUseCore

final class EvidenceArchiveTests: XCTestCase {
    func testCopiesEvidenceAndFullReceiptBeyondSourceLifetime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let screenshot = source.appendingPathComponent("capture.png")
        let snapshot = source.appendingPathComponent("snapshot.json")
        let comparison = source.appendingPathComponent("ax-before.png")
        try Data([1, 2, 3]).write(to: screenshot)
        try Data([3, 2, 1]).write(to: comparison)
        try Data("{\"text\":\"private fixture\"}".utf8).write(to: snapshot)
        let observation: [String: Any] = ["ok": true, "result": [
            "screenshot": screenshot.path, "snapshot": snapshot.path, "text": "o2 refs=current",
            "axComparisonScreenshot": comparison.path
        ]]
        let destination = root.appendingPathComponent("evidence")
        var paths = Set<String>()
        for outcome in ["completed", "unknown", "not_dispatched", "prepared"] {
            let response: [String: Any] = [
                "ok": outcome == "completed", "action": [
                    "outcome": outcome, "result": ["preInputChecks": [["stage": "identity", "inTime": true]]]
                ], "observation": observation
            ]
            let rendered = EvidenceArchive.render(response, directory: destination, agentOutput: true)
            XCTAssertNil(rendered["archiveErrors"])
            XCTAssertEqual(rendered["ok"] as? Bool, response["ok"] as? Bool)
            XCTAssertEqual((rendered["action"] as? [String: Any])?["outcome"] as? String, outcome)
            let artifacts = try XCTUnwrap(rendered["artifacts"] as? [String: String])
            let receipt = try XCTUnwrap(artifacts["receipt"])
            XCTAssertTrue(paths.insert(receipt).inserted)
            XCTAssertEqual(try jsonObject(Data(contentsOf: URL(fileURLWithPath: receipt))) as NSDictionary,
                           response as NSDictionary)
            for path in artifacts.values {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
            }
            let folder = URL(fileURLWithPath: receipt).deletingLastPathComponent()
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int,
                           0o700)
        }
        try FileManager.default.removeItem(at: source)
        for path in paths {
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("screenshot.png")), Data([1, 2, 3]))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("ax-before.png")), Data([3, 2, 1]))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("snapshot.json")),
                           Data("{\"text\":\"private fixture\"}".utf8))
        }
    }

    func testArchiveFailureKeepsFullFactsAndExistingDirectoryPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o755])
        let response: [String: Any] = ["ok": true, "outcome": "completed", "result": [
            "screenshot": root.appendingPathComponent("missing.png").path,
            "preInputChecks": [["stage": "identity", "inTime": true]]
        ]]
        let rendered = EvidenceArchive.render(response, directory: root, agentOutput: true)
        XCTAssertNotNil(rendered["archiveErrors"])
        XCTAssertNotNil(rendered["receipt"])
        XCTAssertNil(rendered["agentSummary"])
        XCTAssertEqual(rendered["result"] as? NSDictionary, response["result"] as? NSDictionary)
        XCTAssertEqual(rendered["ok"] as? Bool, true)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o755)
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let failed = EvidenceArchive.render(response, directory: file, agentOutput: true)
        XCTAssertNil(failed["receipt"])
        XCTAssertNotNil(failed["archiveErrors"])
        XCTAssertEqual(failed["result"] as? NSDictionary, response["result"] as? NSDictionary)
        XCTAssertEqual(failed["outcome"] as? String, "completed")
    }

    func testStandaloneObservationAndReceiptOnlyLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("screen.png")
        try Data([4]).write(to: source)
        let observed = EvidenceArchive.render(["ok": true, "result": ["screenshot": source.path]], directory: root)
        XCTAssertNotNil((observed["artifacts"] as? [String: String])?["screenshot"])
        let connected = EvidenceArchive.render(["ok": true, "result": ["mode": "runner"]], directory: root)
        XCTAssertNil(connected["archiveErrors"])
        XCTAssertEqual((connected["artifacts"] as? [String: String])?.count, 1)
    }

    func testMissingComparisonEvidenceDoesNotRewriteActionFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let response: [String: Any] = [
            "ok": false, "action": ["outcome": "unknown"], "observation": [
                "ok": true, "result": ["axComparisonEvidenceError": "fixture write failure"]
            ]
        ]
        let result = EvidenceArchive.render(response, directory: root, agentOutput: true)
        XCTAssertEqual(result["action"] as? NSDictionary, response["action"] as? NSDictionary)
        XCTAssertEqual(result["observation"] as? NSDictionary, response["observation"] as? NSDictionary)
        XCTAssertEqual(result["archiveErrors"] as? [String], ["fixture write failure"])
        XCTAssertNil(result["agentSummary"])
    }
}
