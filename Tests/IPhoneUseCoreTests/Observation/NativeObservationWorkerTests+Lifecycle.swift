import Darwin
import Foundation
import XCTest
@testable import IPhoneUseCore

extension NativeObservationWorkerTests {
    func testCloseDoesNotPumpBlockingFoundationTerminationNotification() throws {
        let worker = try worker()
        let finished = DispatchSemaphore(value: 0)
        // Match the host: its main thread is waiting, while a service thread owns Process.
        Thread.detachNewThread {
            defer { finished.signal() }
            do {
                let value = try worker.read(cancelled: { false })
                let pid = try XCTUnwrap(value["pid"] as? Int32)
                let observer = NotificationCenter.default.addObserver(
                    forName: Process.didTerminateNotification, object: nil, queue: nil
                ) { notification in
                    guard (notification.object as? Process)?.processIdentifier == pid else { return }
                    // Bounded reproduction of waitUntilExit executing unrelated run-loop work.
                    Thread.sleep(forTimeInterval: 1.5)
                }
                defer { NotificationCenter.default.removeObserver(observer) }
                let start = ProcessInfo.processInfo.systemUptime
                let cleanup = worker.close()
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
                XCTAssertEqual(cleanup["processExited"] as? Bool, true)
                XCTAssertEqual(cleanup["connectionClosed"] as? Bool, true)
                XCTAssertEqual(kill(pid, 0), -1)
                XCTAssertEqual(errno, ESRCH)
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    func testRepeatedRebuildsAcrossThreadsThenDisconnectReleasesLastProcess() throws {
        let worker = try worker(behavior: "if count == 2: sys.exit(1)")
        for _ in 0..<6 {
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                defer { finished.signal() }
                do {
                    let value = try worker.read(cancelled: { false })
                    XCTAssertEqual(value["count"] as? Int, 1)
                } catch { XCTFail("\(error)") }
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }
        let cleanup = worker.close()
        XCTAssertEqual(cleanup["processExited"] as? Bool, true)
        XCTAssertEqual(cleanup["connectionClosed"] as? Bool, true)
        XCTAssertEqual(cleanup["tunnelClosed"] as? Bool, true)
        XCTAssertEqual(worker.close()["processExited"] as? Bool, true)
        XCTAssertThrowsError(try worker.read(cancelled: { false }))
    }

    func testUnresponsiveWorkerIsKilledAndExitIsConfirmedWithoutInventingServiceCleanup() throws {
        let worker = try worker(
            behavior: "import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN)",
            closeBehavior: "time.sleep(30)")
        let pid = try XCTUnwrap(try worker.read(cancelled: { false })["pid"] as? Int32)
        let start = ProcessInfo.processInfo.systemUptime
        let cleanup = worker.close()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 8)
        XCTAssertEqual(cleanup["processExited"] as? Bool, true)
        XCTAssertEqual(cleanup["connectionClosed"] as? Bool, false)
        XCTAssertEqual(cleanup["tunnelClosed"] as? Bool, false)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
