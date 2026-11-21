import ArgumentParser
import IPhoneUseCore
import Foundation

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List installed apps, up to 50 per page, without changing the device UI.")
    @OptionGroup var options: SessionOptions
    @Option(help: "Case-insensitive substring of the app name or bundle ID.") var query: String?
    @Option(help: "Offset returned as nextOffset by the previous page.") var offset = 0
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields: [String: Any] = ["offset": offset]
        fields["query"] = query
        try output(evidenceDir: options.evidence.directory) {
            try SessionClient.call(session: session, operation: "apps", fields: fields)
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the selected session backend without renewing idle time.")
    @OptionGroup var options: SessionOptions
    mutating func run() throws {
        let session = try options.requiredSession()
        try output(evidenceDir: options.evidence.directory) {
            try SessionClient.call(session: session, operation: "status")
        }
    }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bring an app to the foreground and renew the session.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Installed app bundle identifier returned by apps.") var bundleID: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput,
            evidenceDir: options.evidence.directory
        ) {
            try SessionClient.call(session: session, operation: "open", fields: ["bundleId": bundleID])
        }
    }
}

struct Terminate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Terminate the specified app and confirm it has stopped. Unsaved app state may be lost.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Exact installed app bundle identifier returned by apps.") var bundleID: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput,
            evidenceDir: options.evidence.directory
        ) {
            try SessionClient.call(session: session, operation: "terminate", fields: ["bundleId": bundleID])
        }
    }
}

struct Relaunch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Confirm the app has stopped, then launch it once. Inspect the screenshot for page readiness.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Exact installed app bundle identifier returned by apps. Unsaved app state may be lost.")
    var bundleID: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput,
            evidenceDir: options.evidence.directory
        ) {
            try SessionClient.call(session: session, operation: "relaunch", fields: ["bundleId": bundleID])
        }
    }
}

struct Disconnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Finish admitted commands and release the session.")
    @OptionGroup var options: SessionOptions
    mutating func run() throws {
        let session = try options.requiredSession()
        try output(evidenceDir: options.evidence.directory) {
            try SessionClient.call(session: session, operation: "disconnect")
        }
    }
}

struct Observe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture a screenshot and available AX with a new observation ID.",
        discussion: """
        Compact AX omits unknown states: absent enabled or keyboard_focus does not mean true or false.\
         Known enabled states appear as enabled=true or disabled. Indentation follows the nearest retained\
         ancestor after folding redundant layout wrappers. Inspect preserves full captured attributes and\
         original hierarchy. Neither omitted states nor visible content prove actionability.
        """)
    @OptionGroup var options: SessionOptions
    mutating func run() throws {
        let session = try options.requiredSession()
        try output(compact: true, evidenceDir: options.evidence.directory) {
            try SessionClient.call(session: session, operation: "observe")
        }
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Read or search a cached observation or subtree without recapturing or renewing references.",
        discussion:
            """
            Use --query to search all captured nodes before pagination, including nodes omitted from observe's\
             text.\u{20}
            """
                + """
                Matches include references, frames in screen points and parent references. Search does not\
                 prove visibility or clickability.\u{20}
                """
                + "A truncated source may omit the target; inspect cannot fetch missing source data. "
                + "For an already known element, inspect its reference directly instead of paging the whole tree. "
                + "Oversized results provide a full text file and --output/--byte-offset continuation. "
                + "Byte offsets address UTF-8 scalar boundaries; concatenate content fields to recover the exact text."
    )
    @OptionGroup var options: SessionOptions
    @Argument(help: "Observation or element reference, such as o1 or o1:e2.") var reference: String
    @Option(
        help:
            """
            Case-insensitive substring of label, identifier, value or role; 1–256 UTF-8 bytes, no control\
             characters or blank-only text.
            """
    ) var query: String?
    @Option(help: "Node offset, or match offset with --query, returned by the previous inspect page.")
    var offset = 0
    @Option(name: .customLong("output"),
            help: "Cached oversized output ID returned by observe or inspect; observation reference only.")
    var outputID: String?
    @Option(help: "UTF-8 byte offset returned with --output; requires --output; no --query or nonzero --offset.")
    var byteOffset: Int?
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields: [String: Any] = ["reference": reference, "offset": offset]
        fields["query"] = query
        try output(compact: outputID == nil, evidenceDir: options.evidence.directory) {
            if let output = outputID {
                guard query == nil, offset == 0,
                      reference.range(of: "^o[1-9][0-9]*$", options: .regularExpression) != nil,
                      output.range(of: "^t[1-9][0-9]*$", options: .regularExpression) != nil,
                      (byteOffset ?? 0) >= 0 else {
                    throw IPhoneUseError("invalid_output_read", "Use --output with an observation and --byte-offset")
                }
                fields["output"] = output
                fields["byteOffset"] = byteOffset ?? 0
            } else if byteOffset != nil {
                throw IPhoneUseError("invalid_output_read", "--byte-offset requires --output")
            }
            let response = try SessionClient.call(session: session, operation: "inspect", fields: fields)
            if let query, response["ok"] as? Bool == true,
                (response["result"] as? [String: Any])?["query"] as? String != query {
                throw IPhoneUseError(
                    "inspect_query_unsupported",
                    """
                    Session host did not confirm this query; disconnect and connect using the current CLI,\
                     then observe again
                    """
                )
            }
            if let output = outputID, response["ok"] as? Bool == true,
               (response["result"] as? [String: Any])?["outputID"] as? String != output {
                throw IPhoneUseError("inspect_output_unsupported", "Session host did not confirm this output ID")
            }
            return response
        }
    }
}

struct Host: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_host", shouldDisplay: false)
    @Option var directory: String
    mutating func run() throws { try runHost(directory: URL(fileURLWithPath: directory, isDirectory: true)) }
}

struct AuthorizationMonitor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_authorization-monitor", shouldDisplay: false)
    @Option var device: String
    mutating func run() throws { try RunnerAuthorizationLog.run(device: device) }
}
