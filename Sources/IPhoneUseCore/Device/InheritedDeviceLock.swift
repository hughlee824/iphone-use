import Foundation
import Darwin

// Helpers receive a duplicate of the host's default-root flock through stdin. A dup shares
// the open file description, so host death cannot release ownership while a helper can write.
// Never LOCK_UN this descriptor: that would unlock it for the host and all other duplicates.
enum InheritedDeviceLock {
    static func validate(device: String, descriptor: Int32 = STDIN_FILENO) throws {
        guard device.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            throw IPhoneUseError("invalid_device_id", "Invalid inherited device identity")
        }
        var actualInfo = stat(), expectedInfo = stat()
        guard fstat(descriptor, &actualInfo) == 0, actualInfo.st_mode & S_IFMT == S_IFREG,
              actualInfo.st_uid == getuid() else { throw invalid() }
        // Check before open: a closed stdin must not be replaced by our verification fd.
        let path = SessionPaths.defaultRoot.appendingPathComponent("device-\(device).lock").path
        let expected = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard expected >= 0 else { throw invalid() }
        defer { Darwin.close(expected) }
        guard fstat(expected, &expectedInfo) == 0,
              actualInfo.st_dev == expectedInfo.st_dev, actualInfo.st_ino == expectedInfo.st_ino,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw invalid() }
        // The inherited descriptor remains open for the entire helper process, including reply
        // publication and framework cleanup. Only the related notification tool may inherit it.
    }

    private static func invalid() -> IPhoneUseError {
        IPhoneUseError(
            "ax_automation_owner_unavailable", "AX helper requires the selected device's inherited control lock")
    }
}
