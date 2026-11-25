import Foundation
import CoreFoundation
import AppleNativeBridge

// The HID service accepts inline XPC dictionaries. No descriptors, file transfers or out-of-line objects.
enum KeyboardXPC {
    static let invalid = IPhoneUseError("native_keyboard_protocol", "Invalid RemoteXPC keyboard message")
    static let limit = 20 * 1024 * 1024

    static func little<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func wrapper(flags: UInt32, id: UInt64 = 0, message: [String: Any]? = nil) throws -> Data {
        var payload = Data()
        if let message {
            payload = little(UInt32(0x42133742)) + little(UInt32(5))
            payload += try object(message)
        }
        return little(UInt32(0x29b00b92)) + little(flags) + little(UInt64(payload.count)) + little(id) + payload
    }

    private static func padded(_ bytes: Data) -> Data {
        bytes + Data(repeating: 0, count: (4 - bytes.count % 4) % 4)
    }

    private static func object(_ value: Any) throws -> Data {
        func field(_ type: UInt32, _ bytes: Data) -> Data { little(type) + bytes }
        func sized(_ data: Data) -> Data { little(UInt32(data.count)) + data }
        if let map = value as? [String: Any] {
            var body = little(UInt32(map.count))
            for key in map.keys.sorted() {
                body += padded(Data(key.utf8) + [0])
                body += try object(map[key]!)
            }
            return field(0xf000, sized(body))
        }
        if let list = value as? [Any] {
            var body = little(UInt32(list.count))
            for item in list { body += try object(item) }
            return field(0xe000, sized(body))
        }
        if value is NSNull { return field(0x1000, Data()) }
        if let number = value as? ASNativeUnsigned { return field(0x4000, little(number.value)) }
        if let data = value as? Data { return field(0x8000, padded(sized(data))) }
        if let string = value as? String { return field(0x9000, padded(sized(Data(string.utf8) + [0]))) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return field(0x2000, little(UInt32(number.boolValue ? 1 : 0)))
            }
            return field(0x3000, little(number.int64Value))
        }
        throw invalid
    }

    struct Reader {
        var bytes: Data
        var offset = 0

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - offset else { throw KeyboardXPC.invalid }
            defer { offset += count }
            return bytes.subdata(in: offset..<offset + count)
        }
        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            try take(MemoryLayout<T>.size).withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
        private mutating func string(_ count: Int) throws -> String {
            let data = try take(count)
            guard data.last == 0, let value = String(data: data.dropLast(), encoding: .utf8),
                !value.utf8.contains(0) else { throw KeyboardXPC.invalid }
            try skipPadding(count)
            return value
        }
        private mutating func skipPadding(_ count: Int) throws {
            _ = try take((4 - count % 4) % 4)
        }
        mutating func object(depth: Int = 0) throws -> Any {
            guard depth < 32 else { throw KeyboardXPC.invalid }
            switch try integer(UInt32.self) {
            case let scalar where scalar <= 0x7000: return try scalarValue(scalar)
            case 0x8000:
                let count = Int(try integer(UInt32.self)), data = try take(count)
                try skipPadding(count)
                return data
            case 0x9000: return try string(Int(integer(UInt32.self)))
            case 0xa000: return try take(16)
            case 0xe000: return try container(dictionary: false, depth: depth)
            case 0xf000: return try container(dictionary: true, depth: depth)
            default: throw KeyboardXPC.invalid
            }
        }
        private mutating func scalarValue(_ type: UInt32) throws -> Any {
            switch type {
            case 0x1000: return NSNull()
            case 0x2000: return try integer(UInt32.self) != 0
            case 0x3000, 0x7000: return NSNumber(value: try integer(Int64.self))
            case 0x4000: return NSNumber(value: try integer(UInt64.self))
            case 0x5000: return Double(bitPattern: try integer(UInt64.self))
            default: throw KeyboardXPC.invalid
            }
        }
        private mutating func container(dictionary: Bool, depth: Int) throws -> Any {
            let length = Int(try integer(UInt32.self)), end = offset + length
            guard end <= bytes.count else { throw KeyboardXPC.invalid }
            let count = Int(try integer(UInt32.self))
            guard count <= 16384, count <= length / 4 else { throw KeyboardXPC.invalid }
            var map: [String: Any] = [:], list: [Any] = []
            for _ in 0..<count {
                if dictionary {
                    guard offset < end, let nul = bytes[offset..<end].firstIndex(of: 0)
                    else { throw KeyboardXPC.invalid }
                    let key = try string(nul - offset + 1)
                    guard map[key] == nil else { throw KeyboardXPC.invalid }
                    map[key] = try object(depth: depth + 1)
                } else { list.append(try object(depth: depth + 1)) }
            }
            guard offset == end else { throw KeyboardXPC.invalid }
            if dictionary { return map }
            return list
        }
    }
}
