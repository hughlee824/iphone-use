import Foundation
import XCTest
@testable import IPhoneUseCore

final class NativeObservationWorkerTests: XCTestCase {
    func worker(behavior: String = "", closeBehavior: String = "",
                requestTimeout: TimeInterval = 16) throws -> NativeObservationWorker {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-worker-\(UUID())")
        try SessionPaths.secureDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("worker.py")
        let source = """
        import json, sys, os, time
        generation = sys.argv[sys.argv.index('--generation') + 1]
        device = sys.argv[sys.argv.index('--device') + 1]
        marker = __file__ + '.starts'
        first = not os.path.exists(marker)
        with open(marker, 'a') as f: f.write(generation + '\\n')
        def emit(value):
            value['generation'] = generation
            print(json.dumps(value), flush=True)
        emit({'event':'ready'})
        count = 0
        for line in sys.stdin:
            command = json.loads(line)
            if command['op'] == 'close':
                \(closeBehavior)
                emit({'event':'closed','cleanup':{'connectionClosed':True,'tunnelClosed':True}})
                break
            count += 1
            \(behavior)
            emit({'event':'result','id':command['id'],
                  'value':{'deviceID':device,'count':count,'pid':os.getpid()}})
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let worker = NativeObservationWorker(
            device: "test", kind: "ax", executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", "-B", script.path], requestTimeout: requestTimeout)
        addTeardownBlock { _ = worker.close() }
        return worker
    }
    func testPrewarmAndReuseKeepConnectionButUseNewRequestIdentity() throws {
        let worker = try worker()
        try worker.prewarm()
        let first = try worker.read(cancelled: { false })
        let second = try worker.read(cancelled: { false })
        XCTAssertEqual(first["pid"] as? Int, second["pid"] as? Int)
        XCTAssertEqual(second["count"] as? Int, 2)
        let lhs = try XCTUnwrap(first["connectionLease"] as? [String: String])
        let rhs = try XCTUnwrap(second["connectionLease"] as? [String: String])
        XCTAssertEqual(lhs["generation"], rhs["generation"])
        XCTAssertNotEqual(lhs["requestID"], rhs["requestID"])
        XCTAssertEqual(worker.close()["tunnelClosed"] as? Bool, true)
        XCTAssertThrowsError(try worker.read(cancelled: { false }))
    }
    func testWrongRequestIsRejectedAndRebuiltWithoutPublishingIt() throws {
        let worker = try worker(behavior: "if first: command['id'] = 'old-request'")
        let value = try worker.read(cancelled: { false })
        XCTAssertEqual(value["count"] as? Int, 1)
        XCTAssertNotEqual((value["connectionLease"] as? [String: String])?["requestID"], "old-request")
        XCTAssertEqual(worker.close()["connectionClosed"] as? Bool, true)
    }
    func testCancelledLateResultCannotPopulateNextRequest() throws {
        let worker = try worker(behavior: "if first: time.sleep(0.3)")
        try worker.prewarm()
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try worker.read(cancelled: { ProcessInfo.processInfo.systemUptime - start > 0.05 }))
        let fresh = try worker.read(cancelled: { false })
        XCTAssertEqual(fresh["count"] as? Int, 1)
    }
    func testDisconnectRevokesPendingReadBeforeTakingTransactionLock() throws {
        let worker = try worker(behavior: "time.sleep(0.3)")
        try worker.prewarm()
        let finished = expectation(description: "cancelled read")
        DispatchQueue.global().async {
            do { _ = try worker.read(cancelled: { false }); XCTFail("Disconnected result was published") } catch { }
            finished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(worker.close()["connectionClosed"] as? Bool, true)
        wait(for: [finished], timeout: 3)
    }
    func testWorkerExitIsRebuiltWithoutKillingTheHostWithSIGPIPE() throws {
        let worker = try worker(behavior: "if first: sys.exit(1)")
        XCTAssertEqual(try worker.read(cancelled: { false })["count"] as? Int, 1)
    }
    func testServiceRejectionIsNotRetriedAndItsCleanupIsRetained() throws {
        let behavior = "if first: emit({'event':'closed','error':'AX semantic request refused',"
            + "'cleanup':{'connectionClosed':True,'tunnelClosed':True}}); break"
        let worker = try worker(behavior: behavior)
        XCTAssertThrowsError(try worker.read(cancelled: { false })) { error in
            XCTAssertEqual((error as? IPhoneUseError)?.code, "observation_service_failed")
        }
        XCTAssertEqual(worker.close()["connectionClosed"] as? Bool, true)
    }
    func testDuoAndUnknownHardwareKeepDisplaySelectedCapture() {
        XCTAssertFalse(NativeScreenshotReader.supports(["productType": "iPhone19,4"]))
        XCTAssertFalse(NativeScreenshotReader.supports([:]))
        XCTAssertTrue(NativeScreenshotReader.supports(["productType": "iPhone13,3"]))
    }

    private var connectionFailure: String {
        "emit({'event':'closed','error':'transport ended','errorKind':'connection',"
            + "'cleanup':{'connectionClosed':True,'tunnelClosed':True}})"
    }
    private func starts(_ worker: NativeObservationWorker) throws -> [String] {
        try String(contentsOfFile: XCTUnwrap(worker.arguments.last) + ".starts", encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
    func testReportedConnectionFailureRebuildsWithinSameRead() throws {
        let worker = try worker(
            behavior: "if first: time.sleep(0.1); \(connectionFailure); break", requestTimeout: 1)
        let value = try worker.read(cancelled: { false })
        let generations = try starts(worker)
        XCTAssertEqual(generations.count, 2)
        XCTAssertEqual((value["connectionLease"] as? [String: String])?["generation"], generations.last)
    }
    func testLateResultAfterReportedFailureCannotEscapeRetiredGeneration() throws {
        let late = "emit({'event':'result','id':command['id'],'value':{'deviceID':device,'stale':True}})"
        let worker = try worker(behavior: "if first: \(connectionFailure); time.sleep(0.1); \(late); break")
        let value = try worker.read(cancelled: { false })
        XCTAssertNil(value["stale"])
        XCTAssertEqual(try starts(worker).count, 2)
        let again = try worker.read(cancelled: { false })
        XCTAssertEqual(again["count"] as? Int, 2)
        XCTAssertNil(again["stale"])
    }
    func testRebuildDoesNotResetOriginalReadDeadline() throws {
        let behavior = "time.sleep(0.6);\n    if first: \(connectionFailure); break"
        let worker = try worker(behavior: behavior, requestTimeout: 1)
        try worker.prewarm()
        XCTAssertThrowsError(try worker.read(cancelled: { false })) { error in
            XCTAssertEqual((error as? IPhoneUseError)?.code, "observation_worker_timeout")
        }
        XCTAssertEqual(try starts(worker).count, 2)
    }
    func testRetirementConsumesDeadlineAndPreventsAnotherStart() throws {
        let worker = try worker(
            behavior: "if first: \(connectionFailure); time.sleep(0.5); break", requestTimeout: 0.3)
        try worker.prewarm()
        XCTAssertThrowsError(try worker.read(cancelled: { false }))
        XCTAssertEqual(try starts(worker).count, 1)
    }
    func testSemanticUnknownAndMissingKindsNeverRetryBasedOnMessage() throws {
        for kind in ["semantic", "failure", "future_kind", ""] {
            let behavior = "emit({'event':'closed','error':'connection timed out','errorKind':'\(kind)',"
                + "'cleanup':{'connectionClosed':True,'tunnelClosed':True}}); break"
            let worker = try worker(behavior: behavior)
            XCTAssertThrowsError(try worker.read(cancelled: { false }))
            XCTAssertEqual(try starts(worker).count, 1)
        }
    }
    func testRepeatedConnectionFailureStopsAfterOneRebuild() throws {
        let worker = try worker(behavior: "\(connectionFailure); break")
        XCTAssertThrowsError(try worker.read(cancelled: { false }))
        XCTAssertEqual(try starts(worker).count, 2)
    }
}
