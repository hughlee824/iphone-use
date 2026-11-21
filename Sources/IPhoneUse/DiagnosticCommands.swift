import ArgumentParser
import Foundation
import IPhoneUseCore

struct Diagnostics: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Configure local history, export a feedback bundle or prune expired diagnostics.",
        subcommands: [Config.self, Export.self, Clean.self])

    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show preferences or set defaults for new hosts.")
        @Option(help: "debug, info (default), warn or error.") var level: String?
        @Option(help: "Retain screenshots and AX separately from logging: on (default) or off.") var evidence: String?
        @Option var historyDays: Int?
        @Option var evidenceHours: Int?
        @Option(name: .customLong("evidence-mib"), help: "Maximum retained PNG and AX payload in MiB.")
        var evidenceMiB: Int?

        func run() throws {
            try output {
                let modify = level != nil || evidence != nil || historyDays != nil || evidenceHours != nil
                    || evidenceMiB != nil
                let settings = try DiagnosticPreferences.configured(update: modify ? { preferences in
                    if let level {
                        guard let value = DiagnosticLevel(rawValue: level) else {
                            throw ValidationError("Use debug, info, warn or error")
                        }
                        preferences.level = value
                    }
                    if let evidence {
                        guard ["on", "off"].contains(evidence) else { throw ValidationError("Use on or off") }
                        preferences.captureEvidence = evidence == "on"
                    }
                    if let historyDays { preferences.historyDays = historyDays }
                    if let evidenceHours { preferences.evidenceHours = evidenceHours }
                    if let evidenceMiB { preferences.evidenceMiB = evidenceMiB }
                } : nil)
                return ["ok": true, "result": try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))]
            }
        }
    }

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Export one session locally, even after disconnect.")
        @OptionGroup var options: SessionOptions
        @Flag var lastSession = false
        @Option(help: "New ZIP file path.") var outputFile: String
        @Flag(help: "Include private screen images and AX contents in the archive.") var includeEvidence = false
        @Option(help: "Include a particular observation or guard frame. May be repeated.") var frame: [String] = []
        func run() throws {
            let session = options.session
            guard (session != nil) != lastSession else {
                throw ValidationError("Choose --session or --last-session")
            }
            try output {
                ["ok": true, "result": try DiagnosticHistory.export(
                    session: session, destination: URL(fileURLWithPath: outputFile),
                    selection: .init(includeEvidence: includeEvidence, references: frame))]
            }
        }
    }

    struct Clean: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Preview expired history eligible for removal.")
        @Flag(help: "Remove expired diagnostics from confirmed finished sessions.") var apply = false
        func run() throws { try output { ["ok": true, "result": try DiagnosticHistory.clean(apply: apply)] } }
    }
}
