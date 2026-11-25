import Foundation

// A serial, session-owned client for the two RemoteXPC HTTP/2 streams on one HID or pasteboard port.
// Only the root stream carries our requests. A timeout or malformed response retires the socket.
final class KeyboardServiceConnection: NativeTransport {
    let socket: RunnerSocket
    private var nextID: UInt64 = 1
    private var buffers: [UInt32: Data] = [:]
    private var connectionWindow = 65535
    private var streamWindow = 65535
    private var initialWindow = 65535
    private var receivedSettings = false
    private var expected: KeyboardServiceReply?
    private var closed = false

    init(socket: RunnerSocket) throws {
        self.socket = socket
        do { try handshake() } catch { cancel(); throw error }
    }

    private func network<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func frame(_ type: UInt8, flags: UInt8 = 0, stream: UInt32 = 0, body: Data = Data()) throws {
        let size = network(UInt32(body.count)).dropFirst()
        try socket.write(Data(size) + [type, flags] + network(stream) + body)
    }

    private func handshake() throws {
        try socket.write(Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8))
        try frame(4, body: network(UInt16(3)) + network(UInt32(100)) + network(UInt16(4)) + network(UInt32(1048576)))
        try frame(8, body: network(UInt32(1048576 - 65535)))
        try frame(1, flags: 4, stream: 1)
        try data(KeyboardXPC.wrapper(flags: 1, message: [:]))
        try frame(1, flags: 4, stream: 3)
        try data(KeyboardXPC.wrapper(flags: 0x0201))
        let initial = try KeyboardXPC.wrapper(flags: 0x400001)
        try frame(0, stream: 3, body: initial)
        connectionWindow -= initial.count
        while !receivedSettings { _ = try receive(reply: nil) }
    }

    private func data(_ body: Data) throws {
        var offset = 0
        while offset < body.count {
            let size = min(16384, body.count - offset, connectionWindow, streamWindow)
            if size <= 0 { _ = try receive(reply: nil); continue }
            try frame(0, stream: 1, body: body.subdata(in: offset..<offset + size))
            connectionWindow -= size; streamWindow -= size; offset += size
        }
    }

    private func submit(_ message: [String: Any], reply: Bool, timeout: TimeInterval) throws -> UInt64 {
        guard !closed else { throw IPhoneUseError("native_keyboard_closed", "RSD keyboard connection closed") }
        socket.deadline = ProcessInfo.processInfo.systemUptime + timeout
        while socket.hasPendingInput || buffers.values.contains(where: { !$0.isEmpty }) { _ = try receive(reply: nil) }
        let id = nextID
        nextID += 2
        try data(KeyboardXPC.wrapper(flags: reply ? 0x10101 : 0x101, id: id, message: message))
        return id
    }
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        do {
            let shape = try KeyboardServiceReply(request: message)
            var outgoing = message
            if message["command"] as? String == "SET", outgoing["sourceMetadata"] == nil {
                outgoing["sourceMetadata"] = NSNull()
            }
            let id = try submit(outgoing, reply: true, timeout: timeout)
            expected = shape
            defer { expected = nil }
            while true { if let answer = try receive(reply: id) { return answer } }
        } catch { cancel(); throw error }
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        do { _ = try submit(message, reply: false, timeout: timeout) } catch { cancel(); throw error }
    }
    func cancel() {
        if closed { return }
        closed = true; socket.close()
    }
    deinit { cancel() }

    private func receive(reply: UInt64?) throws -> [String: Any]? {
        let header = try socket.read(count: 9)
        let size = Int(header[0]) << 16 | Int(header[1]) << 8 | Int(header[2])
        guard size <= 16384 else { throw KeyboardXPC.invalid }
        let stream = UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self) })
        let body = try socket.read(count: size), flags = header[4]
        switch header[3] {
        case 0:
            guard [1, 3].contains(stream), flags == 0 else { throw KeyboardXPC.invalid }
            if size > 0 {
                try frame(8, body: network(UInt32(size)))
                try frame(8, stream: stream, body: network(UInt32(size)))
            }
            return try messages(body, stream: stream, reply: reply)
        case 1:
            guard [1, 3].contains(stream), flags == 4 else { throw KeyboardXPC.invalid }
        case 4, 6: try connectionControl(type: header[3], flags: flags, stream: stream, body: body)
        case 8: try updateWindow(body, stream: stream)
        case 3, 7: throw IPhoneUseError("native_keyboard_closed", "Device closed the RSD keyboard connection")
        default: break // HTTP/2 extensions cannot carry an XPC reply.
        }
        return nil
    }

    private func connectionControl(type: UInt8, flags: UInt8, stream: UInt32, body: Data) throws {
        guard stream == 0, flags <= 1 else { throw KeyboardXPC.invalid }
        if type == 4 {
            if flags == 0 {
                try settings(body); receivedSettings = true; try frame(4, flags: 1)
            } else if !body.isEmpty { throw KeyboardXPC.invalid }
        } else {
            guard body.count == 8 else { throw KeyboardXPC.invalid }
            if flags == 0 { try frame(6, flags: 1, body: body) }
        }
    }
    private func settings(_ body: Data) throws {
        guard body.count.isMultiple(of: 6) else { throw KeyboardXPC.invalid }
        for offset in stride(from: 0, to: body.count, by: 6) {
            let key = UInt16(bigEndian: body.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            })
            if key == 4 {
                let new = UInt32(bigEndian: body.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset + 2, as: UInt32.self)
                })
                guard new <= Int32.max else { throw KeyboardXPC.invalid }
                streamWindow += Int(new) - initialWindow; initialWindow = Int(new)
            }
        }
    }
    private func updateWindow(_ body: Data, stream: UInt32) throws {
        guard body.count == 4 else { throw KeyboardXPC.invalid }
        let increase = Int(UInt32(bigEndian: body.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) & 0x7fffffff)
        guard increase > 0 else { throw KeyboardXPC.invalid }
        if stream == 0 { connectionWindow += increase }
        if stream == 1 { streamWindow += increase }
        guard connectionWindow <= Int32.max, streamWindow <= Int32.max else { throw KeyboardXPC.invalid }
    }

    private func response(
        reader: inout KeyboardXPC.Reader, end: Int, stream: UInt32, flags: UInt32, matchesID: Bool
    ) throws -> [String: Any]? {
        let correlated = flags & 0x20000 != 0 && matchesID
        // Some services deliver their answer as a new root-channel message.
        // Only accept the expected operation on this exclusive, serial connection.
        let rootMessage = stream == 1 && flags & 0x30100 == 0x100
        guard correlated || rootMessage else { return nil }
        guard try reader.integer(UInt32.self) == 0x42133742, try reader.integer(UInt32.self) == 5,
            let value = try reader.object() as? [String: Any], reader.offset == end else { throw KeyboardXPC.invalid }
        return correlated || expected?.matches(value) == true ? value : nil
    }

    private func messages(_ data: Data, stream: UInt32, reply: UInt64?) throws -> [String: Any]? {
        var bytes = buffers.removeValue(forKey: stream) ?? Data()
        bytes += data
        var answer: [String: Any]?
        while bytes.count >= 24 {
            var reader = KeyboardXPC.Reader(bytes: bytes)
            guard try reader.integer(UInt32.self) == 0x29b00b92 else { throw KeyboardXPC.invalid }
            let flags = try reader.integer(UInt32.self), size = try reader.integer(UInt64.self)
            let id = try reader.integer(UInt64.self)
            guard size <= KeyboardXPC.limit else { throw KeyboardXPC.invalid }
            let end = 24 + Int(size)
            if end > bytes.count { break }
            if size > 0, let reply, let value = try response(
                reader: &reader, end: end, stream: stream, flags: flags, matchesID: id == reply) {
                guard answer == nil else { throw KeyboardXPC.invalid }
                answer = value
            }
            bytes = Data(bytes.dropFirst(end))
        }
        buffers[stream] = bytes
        return answer
    }
}
