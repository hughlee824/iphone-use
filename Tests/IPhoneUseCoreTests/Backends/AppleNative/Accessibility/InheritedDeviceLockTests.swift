import Foundation
import Darwin
import XCTest
@testable import IPhoneUseCore

final class InheritedDeviceLockTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inherited-lock-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testDelegatedLeaseExtendsOwnershipAndValidationNeverUnlocksIt() throws {
        let root = try root(), device = "fixture-\(UUID().uuidString)"
        var owner: SessionDeviceLock? = try SessionDeviceLock(root: root, device: device)
        let lease = try XCTUnwrap(owner).inheritedLease(for: device)
        defer { try? lease.close() }
        XCTAssertNotEqual(fcntl(lease.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
        owner = nil
        for _ in 0..<2 {
            try InheritedDeviceLock.validate(device: device, descriptor: lease.fileDescriptor)
            XCTAssertThrowsError(try SessionDeviceLock(root: root, device: device)) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_busy")
            }
        }
        try lease.close()
        XCTAssertNoThrow(try SessionDeviceLock(root: root, device: device))
    }

    func testWrongDeviceAndIndependentOpenCannotBorrowOwnership() throws {
        let root = try root(), device = "fixture-\(UUID().uuidString)", other = "fixture-\(UUID().uuidString)"
        let owner = try SessionDeviceLock(root: root, device: device)
        let otherOwner = try SessionDeviceLock(root: root, device: other)
        let lease = try owner.inheritedLease(for: device)
        defer { try? lease.close() }
        XCTAssertThrowsError(try owner.inheritedLease(for: other))
        XCTAssertThrowsError(try InheritedDeviceLock.validate(device: other, descriptor: lease.fileDescriptor))
        let path = SessionPaths.defaultRoot.appendingPathComponent("device-\(device).lock").path
        let independent = Darwin.open(path, O_RDWR | O_CLOEXEC)
        defer { Darwin.close(independent) }
        XCTAssertGreaterThanOrEqual(independent, 0)
        XCTAssertThrowsError(try InheritedDeviceLock.validate(device: device, descriptor: independent))
        XCTAssertThrowsError(try SessionDeviceLock(root: root, device: device))
        withExtendedLifetime(otherOwner) {}
    }

    func testInvalidDescriptorsFailBeforeOpeningVerificationFile() throws {
        let root = try root(), device = "fixture-\(UUID().uuidString)"
        let owner = try SessionDeviceLock(root: root, device: device)
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        XCTAssertThrowsError(try InheritedDeviceLock.validate(device: device, descriptor: -1))
        XCTAssertThrowsError(try InheritedDeviceLock.validate(
            device: device, descriptor: pipe.fileHandleForReading.fileDescriptor))
        XCTAssertThrowsError(try InheritedDeviceLock.validate(device: "../other", descriptor: -1))
        withExtendedLifetime(owner) {}
    }

    func testControllerDoesNotRetainReleasedSessionOrClaimCleanup() throws {
        let root = try root(), device = "fixture-\(UUID().uuidString)"
        var owner: SessionDeviceLock? = try SessionDeviceLock(root: root, device: device)
        weak var oldOwner = owner
        let controller = AXAutomation(device: device, root: root, ownership: owner)
        owner = nil
        XCTAssertNil(oldOwner)
        controller.start(cancelled: { false })
        XCTAssertEqual(controller.status["state"] as? String, "cleanup_pending")
        XCTAssertEqual(controller.close()["acknowledged"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.journal.path))
    }
}
