import Foundation
import Darwin

// One session owns one device. An explicitly delegated AX helper can extend that ownership
// beyond host death; the kernel releases the lock after the last duplicate closes.
// Keep the inode: unlinking a lock file can let two hosts lock different inodes.
final class DeviceLock {
    private let descriptor: Int32

    init(root: URL, device: String) throws {
        guard device.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            throw IPhoneUseError("invalid_device_id", "CoreDevice returned an invalid UDID")
        }
        let path = root.appendingPathComponent("device-\(device).lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw IPhoneUseError("device_lock_failed", "Cannot open device lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw IPhoneUseError("device_busy", "This device already has an iPhone-use session")
        }
    }

    func duplicate() throws -> FileHandle {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard copy >= 0 else { throw IPhoneUseError("device_lock_failed", "Cannot delegate device ownership") }
        return FileHandle(fileDescriptor: copy, closeOnDealloc: true)
    }

    deinit { Darwin.close(descriptor) }
}

// Hold the default-root lock as well as any selected-root lock so environment
// overrides cannot let separate sessions control the same device.
final class SessionDeviceLock {
    private let locks: [DeviceLock]
    private let device: String

    init(root: URL, device: String) throws {
        self.device = device
        let defaultRoot = SessionPaths.defaultRoot
        try SessionPaths.secureDirectory(defaultRoot)
        var held = [try DeviceLock(root: defaultRoot, device: device)]
        if root.resolvingSymlinksInPath() != defaultRoot.resolvingSymlinksInPath() {
            held.append(try DeviceLock(root: root, device: device))
        }
        locks = held
    }
    func inheritedLease(for device: String) throws -> FileHandle {
        guard device == self.device else {
            throw IPhoneUseError("ax_automation_owner_unavailable", "Cannot delegate another device's control lock")
        }
        return try locks[0].duplicate()
    }

}
