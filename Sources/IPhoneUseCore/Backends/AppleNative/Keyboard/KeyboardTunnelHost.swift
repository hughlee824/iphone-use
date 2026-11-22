import Foundation
import Darwin
import AppleNativeBridge

// MobileDevice can block inside its C ABI. The child owns only USB/RSD and hands the
// connected HID descriptor to the session. The parent does all service I/O itself.
public enum KeyboardTunnelHost {
    public static func run(device: String, identifier: String, display: UInt64) throws {
        try InheritedDeviceLock.validate(device: device)
        signal(SIGPIPE, SIG_IGN)
        alarm(16)
        let media = KeyboardMediaSession(identifier: identifier, display: display)
        guard ASProvideKeyboardPort(device, { endpoint in
            do { try media.start(endpoint); return nil } catch { return String(describing: error) }
        }, { media.close() }) else {
            throw IPhoneUseError("native_keyboard_tunnel", "RSD keyboard tunnel did not close cleanly")
        }
    }
}

final class KeyboardTunnel {
    private let process = Process()
    private let parent: FileHandle
    private var launched = false
    private var closed = false

    init(device: String, identifier: String, display: UInt64, ownership: SessionDeviceLock) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw IPhoneUseError("native_keyboard_tunnel", "Cannot open keyboard helper socket")
        }
        parent = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let child = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0
        else { throw IPhoneUseError("native_keyboard_tunnel", "Cannot isolate keyboard helper descriptors") }
        let lease = try ownership.inheritedLease(for: device)
        process.executableURL = Bundle.main.executableURL
        process.arguments = [
            "_keyboard-tunnel", "--device", device, "--identifier", identifier, "--display", String(display)
        ]
        process.standardInput = lease
        process.standardOutput = child
        process.standardError = FileHandle.nullDevice
        try process.run()
        launched = true
        try? child.close(); try? lease.close()
    }
    private var exitedCleanly: Bool {
        !launched || (!process.isRunning && process.terminationReason == .exit && process.terminationStatus == 0)
    }

    @discardableResult func close() -> Bool {
        guard !closed else { return exitedCleanly }
        closed = true
        try? parent.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 32
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let cutoff = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < cutoff {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return exitedCleanly
    }
    deinit { close() }

    func open(pasteboard: Bool) throws -> KeyboardServiceConnection {
        guard !closed, process.isRunning, fcntl(parent.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw IPhoneUseError("native_keyboard_tunnel", "Keyboard tunnel has closed")
        }
        try parent.write(contentsOf: Data([pasteboard ? 0x50 : 0x48]))
        var error: NSError?
        let descriptor = ASReceiveKeyboardPort(parent.fileDescriptor, &error)
        guard descriptor >= 0 else {
            throw error ?? IPhoneUseError("native_keyboard_tunnel", "Keyboard service descriptor unavailable")
        }
        let socket = try RunnerSocket(
            ownedDescriptor: descriptor, deadline: ProcessInfo.processInfo.systemUptime + 4, keyboardService: true)
        return try KeyboardServiceConnection(socket: socket)
    }
}
