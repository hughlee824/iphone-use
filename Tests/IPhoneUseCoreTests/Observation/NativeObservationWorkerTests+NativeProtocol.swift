import Foundation
import XCTest
@testable import IPhoneUseCore

extension NativeObservationWorkerTests {
    private func nativePeer() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-error-\(UUID())")
        try SessionPaths.secureDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("peer")
        let log = directory.appendingPathComponent("compiler.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "clang", "-fobjc-arc", "-framework", "Foundation",
            "-I" + root.appendingPathComponent("Sources/AppleNativeBridge/include").path,
            "-I" + root.appendingPathComponent("Sources/AppleNativeBridge/Observation").path,
            "-I" + root.appendingPathComponent("Sources/AppleNativeBridge/Transport").path,
            root.appendingPathComponent("Sources/AppleNativeBridge/Transport/DTXReadOnlyRequest.m").path,
            root.appendingPathComponent("Sources/AppleNativeBridge/AXP/AXPCollection.m").path,
            root.appendingPathComponent("Sources/AppleNativeBridge/AXP/AXPArchive.m").path,
            root.appendingPathComponent("Sources/AppleNativeBridge/AXP/AXPReceiveQueue.m").path,
            root.appendingPathComponent("Sources/AppleNativeBridge/Observation/ObservationWorker.m").path,
            root.appendingPathComponent("Tests/NativeTransport/ObservationFailureTests.m").path,
            "-o", executable.path
        ]
        compiler.standardOutput = output; compiler.standardError = output
        try compiler.run(); compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            XCTFail(try String(contentsOf: log, encoding: .utf8))
            throw IPhoneUseError("test_compile_failed", "Native test peer did not compile")
        }
        return executable
    }
    func testNativeReportedConnectionFailureRecoversWithoutSecondExplicitRead() throws {
        let executable = try nativePeer()
        let worker = NativeObservationWorker(device: "recover", kind: "ax", executable: executable, arguments: [])
        defer { _ = worker.close() }
        try worker.prewarm()
        // Real native error envelope + real Swift manager: one explicit read must rebuild and succeed.
        let value = try worker.read(cancelled: { false })
        XCTAssertEqual(value["recovered"] as? Bool, true)
        XCTAssertEqual((value["connectionLease"] as? [String: String])?["state"], "current")
        let cleanup = worker.close()
        XCTAssertEqual(cleanup["connectionClosed"] as? Bool, true)
        XCTAssertEqual(cleanup["tunnelClosed"] as? Bool, true)
    }
    func testNativeDTXInterruptionRebuildsAndDiscardsRetiredLateResult() throws {
        let worker = NativeObservationWorker(
            device: "recover_dtx_late", kind: "screenshot", executable: try nativePeer(), arguments: [])
        defer { _ = worker.close() }
        try worker.prewarm()
        let value = try worker.read(cancelled: { false })
        XCTAssertEqual(value["recovered"] as? Bool, true)
        XCTAssertNil(value["stale"])
        let next = try worker.read(cancelled: { false })
        XCTAssertNil(next["stale"])
        let firstLease = try XCTUnwrap(value["connectionLease"] as? [String: String])
        let nextLease = try XCTUnwrap(next["connectionLease"] as? [String: String])
        XCTAssertEqual(firstLease["generation"], nextLease["generation"])
        XCTAssertNotEqual(firstLease["requestID"], nextLease["requestID"])
    }
    func testNativeDTXRecoveryKeepsOriginalDeadlineAndNextReadIsFresh() throws {
        let worker = NativeObservationWorker(
            device: "recover_dtx_deadline", kind: "screenshot", executable: try nativePeer(),
            arguments: [], requestTimeout: 1)
        defer { _ = worker.close() }
        try worker.prewarm()
        XCTAssertThrowsError(try worker.read(cancelled: { false })) { error in
            XCTAssertEqual((error as? IPhoneUseError)?.code, "observation_worker_timeout")
        }
        XCTAssertEqual(try worker.read(cancelled: { false })["recovered"] as? Bool, true)
    }
    func testProductionAXDTXDisconnectRecoversAndIsolatesRetiredLateResponse() throws {
        let worker = NativeObservationWorker(
            device: "ax_late", kind: "ax", executable: try nativePeer(), arguments: [])
        defer { _ = worker.close() }
        try worker.prewarm()
        let first = try worker.read(cancelled: { false })
        let second = try worker.read(cancelled: { false })
        for value in [first, second] {
            XCTAssertEqual(value["recovered"] as? Bool, true)
            XCTAssertNil(value["stale"])
        }
        let lhs = try XCTUnwrap(first["connectionLease"] as? [String: String])
        let rhs = try XCTUnwrap(second["connectionLease"] as? [String: String])
        XCTAssertEqual(lhs["generation"], rhs["generation"])
        XCTAssertNotEqual(lhs["requestID"], rhs["requestID"])
    }
    func testProductionAXDTXRecoveryKeepsOriginalDeadline() throws {
        let worker = NativeObservationWorker(
            device: "ax_deadline", kind: "ax", executable: try nativePeer(), arguments: [], requestTimeout: 1)
        defer { _ = worker.close() }
        try worker.prewarm()
        XCTAssertThrowsError(try worker.read(cancelled: { false })) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "observation_worker_timeout")
        }
        XCTAssertEqual(try worker.read(cancelled: { false })["recovered"] as? Bool, true)
    }
    func testProductionAXDTXRefusalsDoNotRebuildWithoutConnectionEvidence() throws {
        for mode in ["ax_unconfirmed", "ax_semantic"] {
            let worker = NativeObservationWorker(
                device: mode, kind: "ax", executable: try nativePeer(), arguments: [])
            defer { _ = worker.close() }
            try worker.prewarm()
            XCTAssertThrowsError(try worker.read(cancelled: { false })) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "observation_service_failed")
            }
            // A retry would have returned recovered and failed the assertion above.
            XCTAssertEqual(try worker.read(cancelled: { false })["recovered"] as? Bool, true)
        }
    }

}
