import Foundation
import CryptoKit

struct CachedAXText {
    let id: String
    let file: URL
    let bytes: Int
    let digest: String

    func matches(_ expected: Data) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard bytes == expected.count, try handle.seekToEnd() == UInt64(bytes) else { return false }
            try handle.seek(toOffset: 0)
            var offset = 0
            while offset < expected.count {
                let part = try handle.read(upToCount: min(64 * 1024, expected.count - offset)) ?? Data()
                guard !part.isEmpty, part == expected.subdata(in: offset..<(offset + part.count)) else { return false }
                offset += part.count
            }
            return try handle.read(upToCount: 1)?.isEmpty ?? true
        } catch { return false }
    }

    func removeFile() throws {
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            let failure = error as NSError
            // A missing cache file is already cleaned up; other filesystem errors remain failures.
            guard failure.domain == NSCocoaErrorDomain, failure.code == NSFileNoSuchFileError else { throw error }
        }
    }
}

extension ObservationCache {
    // Encoded result budget, with space reserved for the host's response envelope.
    static let inlineTextLimit = 128 * 1024
    static let textEnvelopeReserve = 4096
    static let cachedTextLimit = 4
    private static let textReadSize = 32 * 1024

    func deliverText(_ original: [String: Any], entry: Entry) -> [String: Any] {
        guard ((try? jsonData(original).count) ?? Int.max) > Self.inlineTextLimit - Self.textEnvelopeReserve
        else { return original }
        var response = original
        // Frozen output never advertises historical refs=current; each read supplies live validity.
        let text = original["text"] as? String ?? ""
        var document = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().joined(separator: "\n")
        if text.hasPrefix("obs="), entry.capture.metadata["backend"] as? String == "apple-native" {
            document = StandardCompactAX.legend + "\n" + text
        }
        let identity = "observation=\(entry.id) refs=\(entry.validity)"
            + (entry.capture.metadata["sourceTruncated"] as? Bool == true ? "\nsource_missing=true" : "")
        response["text"] = identity
        response["outputDeferred"] = true
        response["sourceTruncated"] = entry.capture.metadata["sourceTruncated"] as? Bool ?? false
        response["axStatus"] = entry.capture.metadata["axStatus"]
        do {
            let output = try cacheText(Data(document.utf8), entry: entry)
            let command = textReadCommand(entry.id, output: output.id, offset: 0)
            response["fullText"] = output.file.path
            response["outputID"] = output.id
            response["totalBytes"] = output.bytes
            response["nextRead"] = command
            response["text"] = """
            \(identity)
            output_deferred=true total_bytes=\(output.bytes); AX content retained in full, not truncated
            full_text=\(quoted(output.file.path))
            more: \(command) (same cached snapshot)
            """
        } catch {
            response["outputError"] = "Could not save full presentation; complete AX remains in snapshot"
            response["text"] = """
            \(identity)
            output_deferred=true output_error=full_text_write_failed; complete AX remains in snapshot
            snapshot=\(quoted(original["snapshot"] ?? NSNull())); inspect this cached observation to retry output
            """
        }
        return response
    }

    private func cacheText(_ data: Data, entry: Entry) throws -> CachedAXText {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var outputs = textOutputs[entry.id, default: []]
        if let index = outputs.firstIndex(where: { $0.digest == digest }) {
            let output = outputs.remove(at: index)
            if output.matches(data) {
                outputs.append(output)
                textOutputs[entry.id] = outputs
                return output
            }
            try output.removeFile()
            // Retire the broken token before writing its replacement, even if that write fails.
            textOutputs[entry.id] = outputs
        }
        let id = "t\(nextTextOutputID)"
        nextTextOutputID += 1
        let file = entry.directory.appendingPathComponent("ax-output-\(id).txt")
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw IPhoneUseError("output_write_failed", "Could not save complete AX text") }
        let output = CachedAXText(id: id, file: file, bytes: data.count, digest: digest)
        do {
            if outputs.count == Self.cachedTextLimit {
                try outputs[0].removeFile()
                outputs.removeFirst()
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        outputs.append(output)
        textOutputs[entry.id] = outputs
        return output
    }

    func inspectText(_ reference: ObservationReference, outputID: String, byteOffset: Int) throws -> [String: Any] {
        guard reference.node == nil, byteOffset >= 0 else {
            throw IPhoneUseError("invalid_output_read", "Use an observation and a nonnegative UTF-8 byte offset")
        }
        guard let entry = entries.first(where: { $0.id == reference.observation }) else {
            throw IPhoneUseError("observation_unavailable", "Snapshot is no longer cached")
        }
        guard let output = textOutputs[entry.id]?.first(where: { $0.id == outputID }) else {
            throw IPhoneUseError("output_unavailable", "Text output is no longer cached; inspect the cached source")
        }
        guard byteOffset <= output.bytes else {
            throw IPhoneUseError("invalid_offset", "Byte offset exceeds this cached text output")
        }
        let handle = try FileHandle(forReadingFrom: output.file)
        defer { try? handle.close() }
        guard try handle.seekToEnd() == UInt64(output.bytes) else {
            throw IPhoneUseError("output_read_failed", "Cached text size changed")
        }
        try handle.seek(toOffset: UInt64(byteOffset))
        // One-byte lookahead distinguishes a read boundary from an incomplete scalar at EOF.
        let data = try handle.read(upToCount: Self.textReadSize + 1) ?? Data()
        guard data.count == min(Self.textReadSize + 1, output.bytes - byteOffset) else {
            throw IPhoneUseError("output_read_failed", "Cached text is incomplete")
        }
        guard data.first.map({ $0 & 0xC0 != 0x80 }) ?? true else {
            throw IPhoneUseError("invalid_offset", "Offset must be a UTF-8 scalar boundary in intact cached text")
        }
        return try encodedTextChunk(data, entry: entry, output: output, byteOffset: byteOffset)
    }

    private func encodedTextChunk(
        _ data: Data, entry: Entry, output: CachedAXText, byteOffset: Int
    ) throws -> [String: Any] {
        var length = min(Self.textReadSize, data.count)
        while length >= 0 {
            var end = length
            while end > 0, end < data.count, data[end] & 0xC0 == 0x80 {
                end -= 1
            }
            // At EOF end == data.count: malformed trailing bytes must fail, never be trimmed to empty success.
            let bytes = Array(data.prefix(end))
            guard end > 0 || data.isEmpty, let content = Self.exactUTF8(bytes) else {
                throw IPhoneUseError("output_read_failed", "Cached text is not valid UTF-8")
            }
            let response = textChunk(content, entry: entry, output: output, offset: byteOffset)
            if try jsonData(response).count <= Self.inlineTextLimit - Self.textEnvelopeReserve {
                return response
            }
            guard end > 1 else { break }
            length = end / 2
        }
        throw IPhoneUseError("output_read_failed", "Could not encode this cached text segment")
    }

    private static func exactUTF8(_ bytes: [UInt8]) -> String? {
        guard var content = String(bytes: bytes, encoding: .utf8) else { return nil }
        // Foundation may consume one leading BOM. Restore that scalar, including on macOS 13,
        // and require exact bytes so no decoding repair or normalization can silently change content.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), content.utf8.count == bytes.count - 3 {
            content = "\u{FEFF}" + content
        }
        return content.utf8.elementsEqual(bytes) ? content : nil
    }

    private func textChunk(
        _ content: String, entry: Entry, output: CachedAXText, offset: Int
    ) -> [String: Any] {
        let next = offset + content.utf8.count
        var response: [String: Any] = [
            "observation": entry.id, "refs": entry.validity, "outputID": output.id,
            "fullText": output.file.path, "totalBytes": output.bytes, "byteOffset": offset,
            "bytesReturned": content.utf8.count, "outputComplete": next == output.bytes, "content": content
        ]
        var text = """
        observation=\(entry.id) refs=\(entry.validity)
        cached_output=\(output.id) byte_offset=\(offset) bytes_returned=\(content.utf8.count)\
         total_bytes=\(output.bytes)
        \(content)
        """
        if next < output.bytes {
            let command = textReadCommand(entry.id, output: output.id, offset: next)
            response["nextByteOffset"] = next
            response["nextRead"] = command
            text += "\nmore: \(command) (same cached snapshot)"
        }
        response["text"] = text
        return response
    }

    private func textReadCommand(_ observation: String, output: String, offset: Int) -> String {
        "inspect \(observation) --output \(output) --byte-offset \(offset)"
    }
}
