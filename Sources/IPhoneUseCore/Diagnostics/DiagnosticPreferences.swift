import Foundation

public enum DiagnosticLevel: String, Codable, CaseIterable {
    case debug, info, warn, error

    func admits(_ level: Self) -> Bool {
        Self.allCases.firstIndex(of: level)! >= Self.allCases.firstIndex(of: self)!
    }
}

public struct DiagnosticPreferences: Codable, Equatable {
    public var level: DiagnosticLevel = .info
    public var captureEvidence = true
    public var historyDays = 7
    public var evidenceHours = 24
    public var evidenceMiB = 100

    public init() {}

    func validate() throws {
        guard (1...365).contains(historyDays), (1...8760).contains(evidenceHours),
            (1...4096).contains(evidenceMiB) else {
            throw IPhoneUseError("invalid_configuration", "Use 1–365 days, 1–8760 hours and 1–4096 MiB")
        }
    }

    public static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        update: ((inout Self) throws -> Void)? = nil
    ) throws -> Self {
        try ModeConfiguration(environment: environment).diagnostics(update: update)
    }
}

/// The file stores overrides. CLI replies still encode all effective values.
struct DiagnosticOverrides: Codable {
    var level: DiagnosticLevel?
    var captureEvidence: Bool?
    var historyDays: Int?
    var evidenceHours: Int?
    var evidenceMiB: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case level, captureEvidence, historyDays, evidenceHours, evidenceMiB
    }

    init(_ settings: DiagnosticPreferences) {
        let defaults = DiagnosticPreferences()
        level = settings.level == defaults.level ? nil : settings.level
        captureEvidence = settings.captureEvidence == defaults.captureEvidence ? nil : settings.captureEvidence
        historyDays = settings.historyDays == defaults.historyDays ? nil : settings.historyDays
        evidenceHours = settings.evidenceHours == defaults.evidenceHours ? nil : settings.evidenceHours
        evidenceMiB = settings.evidenceMiB == defaults.evidenceMiB ? nil : settings.evidenceMiB
    }

    var effective: DiagnosticPreferences {
        var settings = DiagnosticPreferences()
        if let level { settings.level = level }
        if let captureEvidence { settings.captureEvidence = captureEvidence }
        if let historyDays { settings.historyDays = historyDays }
        if let evidenceHours { settings.evidenceHours = evidenceHours }
        if let evidenceMiB { settings.evidenceMiB = evidenceMiB }
        return settings
    }
}
