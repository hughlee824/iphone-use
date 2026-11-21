import Foundation

/// Copies a completed reply's evidence only. Never contacts a device or changes its outcome.
public enum EvidenceArchive {
    public static func render(
        _ response: [String: Any], directory: URL, agentOutput: Bool = false
    ) -> [String: Any] {
        var artifacts: [String: String] = [:]
        var errors: [String] = []
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let folder = directory.standardizedFileURL.appendingPathComponent("iphone-use-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let receipt = folder.appendingPathComponent("receipt.json")
            try write(try jsonData(response), to: receipt)
            artifacts["receipt"] = receipt.path
            let observation = observation(in: response)
            if let text = observation["text"] as? String, text.hasPrefix("obs="),
               let footer = text.range(of: "\nscreenshot=", options: .backwards) {
                let destination = folder.appendingPathComponent("compact-ax.txt")
                let document = StandardCompactAX.legend + "\n" + text[..<footer.lowerBound] + "\n"
                do {
                    try write(Data(document.utf8), to: destination)
                    artifacts["compactAX"] = destination.path
                } catch { errors.append("compactAX: \(error)") }
            }
            if let error = observation["axComparisonEvidenceError"] as? String { errors.append(error) }
            for (key, name) in [("screenshot", "screenshot.png"), ("snapshot", "snapshot.json"),
                                ("axComparisonScreenshot", "ax-before.png"), ("fullText", "ax-output.txt")] {
                guard let source = observation[key] as? String else { continue }
                do {
                    let destination = folder.appendingPathComponent(name)
                    try write(Data(contentsOf: URL(fileURLWithPath: source)), to: destination)
                    artifacts[key] = destination.path
                } catch { errors.append("\(key): \(error)") }
            }
        } catch { errors.append("archive: \(error)") }
        // A storage error must not obscure full execution facts or look like failed phone input.
        var result = agentOutput && errors.isEmpty ? AgentOutput.summarize(response) : response
        result["artifacts"] = artifacts
        if let receipt = artifacts["receipt"] { result["receipt"] = receipt }
        if !errors.isEmpty { result["archiveErrors"] = errors }
        return result
    }

    private static func observation(in response: [String: Any]) -> [String: Any] {
        let action = response["action"] as? [String: Any] ?? response
        if let observed = response["observation"] as? [String: Any]
            ?? action["observation"] as? [String: Any], observed["ok"] as? Bool == true {
            return observed["result"] as? [String: Any] ?? [:]
        }
        if response["ok"] as? Bool == true { return response["result"] as? [String: Any] ?? [:] }
        return [:]
    }

    private static func write(_ data: Data, to path: URL) throws {
        guard FileManager.default.createFile(
            atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw IPhoneUseError("evidence_write_failed", "Could not save \(path.lastPathComponent)")
        }
    }
}
