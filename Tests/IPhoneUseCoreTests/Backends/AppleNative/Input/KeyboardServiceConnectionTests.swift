import XCTest
import Darwin
@testable import IPhoneUseCore

// Local byte-stream peer, independent of the RemoteXPC encoder for its framing
// and handshake expectations. No tunnel, phone or clipboard is accessed.
private struct KeyboardWirePeer {
    let socket: RunnerSocket
    struct Frame {
        let type: UInt8
        let flags: UInt8
        let stream: UInt8
        let body: Data
    }
    func frame() throws -> Frame {
        let header = try socket.read(count: 9)
        let size = Int(header[0]) * 65536 + Int(header[1]) * 256 + Int(header[2])
        return Frame(type: header[3], flags: header[4], stream: header[8], body: try socket.read(count: size))
    }
    func write(_ type: UInt8, stream: UInt8 = 0, bytes: Data = Data()) throws {
        try socket.write(Data([0, UInt8(bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count),
                               type, 0, 0, 0, 0, stream]) + bytes)
    }
    func accept() throws {
        XCTAssertEqual(try socket.read(count: 24), Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8))
        for (type, stream): (UInt8, UInt8) in [(4, 0), (8, 0), (1, 1), (0, 1), (1, 3), (0, 1), (0, 3)] {
            let incoming = try frame()
            XCTAssertEqual(incoming.type, type); XCTAssertEqual(incoming.stream, stream)
        }
        try write(4)
        let ack = try frame()
        XCTAssertEqual(ack.type, 4); XCTAssertEqual(ack.flags, 1)
    }

    func request(id: UInt64) throws -> [String: Any] {
        var incoming = try frame()
        while incoming.type == 8 { incoming = try frame() }
        XCTAssertEqual(incoming.stream, 1)
        XCTAssertEqual(incoming.type, 0)
        var reader = KeyboardXPC.Reader(bytes: incoming.body)
        XCTAssertEqual(try reader.integer(UInt32.self), 0x29b00b92)
        XCTAssertEqual(try reader.integer(UInt32.self), 0x10101)
        XCTAssertEqual(try reader.integer(UInt64.self), UInt64(incoming.body.count - 24))
        XCTAssertEqual(try reader.integer(UInt64.self), id)
        _ = try reader.take(8)
        return try XCTUnwrap(reader.object() as? [String: Any])
    }
}

final class KeyboardServiceConnectionTests: XCTestCase {
    private func pair() throws -> (RunnerSocket, KeyboardWirePeer) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw KeyboardXPC.invalid }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        return (try RunnerSocket(ownedDescriptor: fds[0], deadline: deadline),
                KeyboardWirePeer(socket: try RunnerSocket(ownedDescriptor: fds[1], deadline: deadline)))
    }

    func testHandshakeAndChineseSetWithFragmentedAndUnrelatedMessages() throws {
        let (socket, peer) = try pair(), done = expectation(description: "peer")
        let text = Data("你好".utf8)
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                try peer.accept()
                let request = try peer.request(id: 1)
                XCTAssertEqual(request["command"] as? String, "SET")
                XCTAssertTrue(request["sourceMetadata"] is NSNull)
                let items = try XCTUnwrap(request["items"] as? [[String: Any]])
                let values = try XCTUnwrap(items.first?["data"] as? [String: [String: Data]])
                XCTAssertEqual(values["public.utf8-plain-text"]?["data"], text)
                // A notification and a stale correlated reply cannot satisfy SET.
                try peer.write(0, stream: 1, bytes: KeyboardXPC.wrapper(flags: 0x101, message: ["command": "PUSH"]))
                try peer.write(0, stream: 3, bytes: KeyboardXPC.wrapper(flags: 0x20101, id: 5, message: ["old": 1]))
                let reply = try KeyboardXPC.wrapper(flags: 0x101, message: ["command": "SET_REPLY"])
                try peer.write(0, stream: 1, bytes: reply.prefix(12))
                try peer.write(0, stream: 1, bytes: reply.dropFirst(12))
                let next = try peer.request(id: 3)
                XCTAssertEqual(next["command"] as? String, "PULL")
                try peer.write(0, stream: 3, bytes: KeyboardXPC.wrapper(
                    flags: 0x20101, id: 3, message: ["command": "PULL_REPLY"]))
            } catch { XCTFail(String(describing: error)) }
        }
        let channel = try KeyboardServiceConnection(socket: socket)
        let set = try channel.request([
            "command": "SET", "items": [["data": ["public.utf8-plain-text": ["data": text]]]]
        ], timeout: 2)
        XCTAssertEqual(set["command"] as? String, "SET_REPLY")
        XCTAssertEqual(try channel.request(["command": "PULL"], timeout: 2)["command"] as? String, "PULL_REPLY")
        wait(for: [done], timeout: 2)
    }

    func testLostReplyPoisonsConnectionBeforeNextWrite() throws {
        let (socket, peer) = try pair(), done = expectation(description: "peer")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                try peer.accept()
                _ = try peer.request(id: 1)
                try peer.write(7)
            } catch { XCTFail(String(describing: error)) }
        }
        let channel = try KeyboardServiceConnection(socket: socket)
        XCTAssertThrowsError(try channel.request(["command": "SET"], timeout: 2))
        XCTAssertThrowsError(try channel.send(["unexpected": "replay"], timeout: 2))
        wait(for: [done], timeout: 2)
    }
}
