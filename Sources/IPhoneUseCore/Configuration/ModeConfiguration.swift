import IPhoneUseRunnerSupport
import Foundation

public enum ControlMode: String, Codable {
    case standard, runner

    public var backend: String { self == .standard ? "apple-native" : "xctest" }

    /// Implemented command forms, independent of transient device/service readiness.
    var support: [String: Any] {
        let common = [
            "status", "apps", "open", "home", "terminate", "relaunch", "observe", "inspect", "tap",
            "double-tap",
            "long-press", "pinch", "swipe", "type", "press", "disconnect", "record-start", "record-stop",
            "preview"
        ]
        if self == .standard {
            return [
                "operations": common + ["text-prepare", "text-finish"],
                "observationSources": ["screenshot", "available_elements"],
                "actionTargets": [
                    "tap": ["screen_point"], "swipe": ["screen_path"],
                    "type": ["focused_native_editor", "native_editor_reference",
                             "visually_focused_input", "touch_paste_staging"],
                    "press": ["visually_focused_input"]
                ],
                "textModes": ["insert", "replace", "append"],
                "textMethods": ["auto", "keys", "paste", "touch-paste"],
                "touchPasteModes": ["insert"],
                "pressKeys": NativePressKey.allCases.map(\.rawValue)
            ]
        }
        return [
            "operations": common + ["focus", "clear", "text-finish"],
            "observationSources": ["screenshot", "available_elements"],
            "actionTargets": [
                "tap": ["screen_point", "element"], "swipe": ["screen_path", "element"],
                "double-tap": ["screen_point", "element"], "long-press": ["screen_point", "element"],
                "focus": ["element"], "clear": ["element"],
                "type": ["element", "touch_paste_staging"], "press": ["element"]
            ],
            "textModes": ["insert"], "textMethods": ["touch-paste"],
            "explicitFocus": true, "clearSelection": true, "inputActionVersion": 13,
            "touchPasteModes": ["insert"],
            "pressKeys": RunnerPressKey.allCases.map(\.rawValue)
        ]
    }

    static func parse(_ value: String) throws -> ControlMode {
        guard let mode = ControlMode(rawValue: value) else {
            throw IPhoneUseError("invalid_mode", "Use mode standard or runner")
        }
        return mode
    }
}

public struct ModeSelection {
    public let mode: ControlMode
    public let source: String

    public var result: [String: Any] {
        ["mode": mode.rawValue, "backend": mode.backend, "modeSource": source]
    }
}

/// User preference is resolved once, before starting a host. Running hosts never read it.
public struct ModeConfiguration {
    private struct Document: Codable {
        var version = 1
        var mode: ControlMode
        var diagnostics: DiagnosticOverrides?
    }
    private let directory: URL
    private let legacyRunner: () throws -> Bool
    private var file: URL { directory.appendingPathComponent("config.json") }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let path = environment["IPHONE_USE_CONFIG_DIR"] {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else {
                throw IPhoneUseError(
                    "invalid_configuration_directory",
                    "IPHONE_USE_CONFIG_DIR must be an absolute directory path")
            }
            // An explicitly isolated preference store must not infer its mode
            // from the real user's prepared Runners.
            self.init(directory: URL(fileURLWithPath: path).standardizedFileURL, legacyRunner: { false })
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            directory: home.appendingPathComponent(".iphone-use"),
            legacyRunner: { try RunnerSetup.hasValidLegacyConfiguration() })
    }

    init(directory: URL, legacyRunner: @escaping () throws -> Bool) {
        self.directory = directory
        self.legacyRunner = legacyRunner
    }

    /// Explicit options neither read nor modify defaults, including during migration.
    public func select(mode: String?, backend: String?, xctestrun: String?, nativeEndpointInventory: String?)
        throws
        -> ModeSelection {
        var choices: [(ControlMode, String)] = []
        if let mode { choices.append((try ControlMode.parse(mode), "command_line_mode")) }
        if let backend {
            guard ["apple-native", "xctest"].contains(backend) else {
                throw IPhoneUseError(
                    "unsupported_backend",
                    "Use --backend apple-native or xctest, or --mode standard or runner")
            }
            choices.append((backend == "apple-native" ? .standard : .runner, "command_line_backend"))
        }
        if xctestrun != nil { choices.append((.runner, "command_line_xctestrun")) }
        if nativeEndpointInventory != nil {
            choices.append((.standard, "command_line_native_endpoint_inventory"))
        }
        if let first = choices.first {
            guard choices.allSatisfy({ $0.0 == first.0 }) else {
                throw IPhoneUseError(
                    "mode_conflict",
                    "Conflicting mode/backend options: standard uses apple-native; runner uses xctest and --xctestrun"
                )
            }
            return ModeSelection(mode: first.0, source: first.1)
        }
        return try defaults(persist: true)
    }

    public func get() throws -> [String: Any] {
        var result = try defaults(persist: false).result
        result["configPath"] = file.path
        result["saved"] = FileManager.default.fileExists(atPath: file.path)
        return result
    }

    public func set(mode: String) throws -> [String: Any] {
        let mode = try ControlMode.parse(mode)
        let lock = try configurationLock()
        defer { withExtendedLifetime(lock) {} }
        var document = try read() ?? Document(mode: mode)
        document.mode = mode
        try write(document)
        return [
            "mode": mode.rawValue, "backend": mode.backend, "configPath": file.path,
            "saved": true, "appliesTo": "new_sessions"
        ]
    }

    func diagnostics(update: ((inout DiagnosticPreferences) throws -> Void)?) throws -> DiagnosticPreferences {
        guard let update else { return try read()?.diagnostics?.effective ?? DiagnosticPreferences() }
        let lock = try configurationLock()
        defer { withExtendedLifetime(lock) {} }
        let saved = try read()
        var settings = saved?.diagnostics?.effective ?? DiagnosticPreferences()
        try update(&settings)
        try settings.validate()
        var document = try saved ?? Document(mode: initialSelection().mode)
        document.diagnostics = settings == DiagnosticPreferences() ? nil : DiagnosticOverrides(settings)
        try write(document)
        return settings
    }

    private func defaults(persist: Bool) throws -> ModeSelection {
        if persist {
            let lock = try configurationLock()
            defer { withExtendedLifetime(lock) {} }
            if let mode = try read()?.mode { return ModeSelection(mode: mode, source: "configuration") }
            let selection = try initialSelection()
            try write(Document(mode: selection.mode))
            return selection
        }
        if let mode = try read()?.mode { return ModeSelection(mode: mode, source: "configuration") }
        return try initialSelection()
    }

    private func initialSelection() throws -> ModeSelection {
        let legacy = try legacyRunner()
        return ModeSelection(
            mode: legacy ? .runner : .standard,
            source: legacy ? "legacy_runner_migration" : "default")
    }

    private func read() throws -> Document? {
        let files = FileManager.default
        // attributesOfItem also detects dangling symlinks; missing is distinct from unreadable.
        let attributes: [FileAttributeKey: Any]
        do { attributes = try files.attributesOfItem(atPath: file.path) } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65536
        else {
            throw IPhoneUseError(
                "invalid_configuration",
                "Configuration must be a regular JSON file of at most 64 KiB: \(file.path)")
        }
        do {
            let data = try Data(contentsOf: file)
            let object = try jsonObject(data)
            guard Set(object.keys).isSubset(of: ["version", "mode", "diagnostics"]) else {
                throw IPhoneUseError(
                    "invalid_configuration",
                    "Expected version, mode and optional diagnostics fields")
            }
            if let value = object["diagnostics"] {
                let keys = DiagnosticOverrides.CodingKeys.allCases.map(\.rawValue)
                guard let fields = value as? [String: Any], Set(fields.keys).isSubset(of: keys),
                    !fields.values.contains(where: { $0 is NSNull }) else {
                    throw IPhoneUseError("invalid_configuration", "Invalid diagnostics field in configuration")
                }
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                throw IPhoneUseError("invalid_configuration", "Unsupported configuration version")
            }
            try document.diagnostics?.effective.validate()
            return document
        } catch {
            throw IPhoneUseError(
                "invalid_configuration",
                "Cannot read \(file.path): \(error). Repair the file; no backend was selected")
        }
    }

    private func write(_ document: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func configurationLock() throws -> DeviceLock {
        try SessionPaths.secureDirectory(directory)
        do { return try DeviceLock(root: directory, device: "configuration") } catch {
            throw IPhoneUseError(
                "configuration_busy",
                "Cannot lock configuration; another configuration operation may be active: \(error)")
        }
    }
}
