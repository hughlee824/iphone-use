import Foundation
import XCTest
@testable import IPhoneUseCore

final class AXPReaderTests: XCTestCase {
    func helper(_ source: String) throws -> AXPReader {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axp-test-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("helper.py")
        try source.write(to: script, atomically: true, encoding: .utf8)
        return AXPReader(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-B", script.path])
    }

    func testHelperResultAndMalformedOutput() throws {
        let reader = try helper("import json; print(json.dumps({'value': 'read-only'}))")
        XCTAssertEqual(try reader.read(device: "test", cancelled: { false })["value"] as? String, "read-only")
        let malformed = try helper("print('not a JSON response')")
        XCTAssertThrowsError(try malformed.read(device: "test", cancelled: { false }))
    }

    func testFailureCancellationAndOutputBudgetAreBounded() throws {
        let failed = try helper("import sys; sys.exit(1)")
        XCTAssertThrowsError(try failed.read(device: "test", cancelled: { false }))
        let sleeping = try helper("import time; time.sleep(60)")
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try sleeping.read(device: "test", cancelled: { true }))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5)
        let excessive = try helper("print('x' * (13 * 1024 * 1024))")
        XCTAssertThrowsError(try excessive.read(device: "test", cancelled: { false }))
    }

    func testUnresponsiveHelperExpiresAtProductionDeadline() throws {
        let sleeping = try helper("import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)")
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try sleeping.read(device: "test", cancelled: { false }))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThanOrEqual(elapsed, 16)
        XCTAssertLessThan(elapsed, 21)
    }

    func testProductionUsesSameNativeExecutableWithoutExternalRuntime() {
        let reader = AXPReader()
        XCTAssertEqual(reader.executable, Bundle.main.executableURL)
        XCTAssertEqual(reader.arguments, ["_axp-observe"])
    }
}
