import ArgumentParser
import Foundation

struct Upgrade: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upgrade a website installation or show the command for Homebrew.")

    func run() throws {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw ValidationError("Could not locate the running iphone-use executable.")
        }
        let package = executable.deletingLastPathComponent().deletingLastPathComponent()
        // The tap installs the release's bin directory under Cellar/iphone-use/VERSION/libexec.
        if package.lastPathComponent == "libexec",
           package.deletingLastPathComponent().deletingLastPathComponent().path.hasSuffix("/Cellar/iphone-use") {
            print("Run brew upgrade iphone-use to upgrade this Homebrew installation.")
            return
        }
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else {
            throw ValidationError("Set HOME to your absolute home directory.")
        }
        let local = URL(fileURLWithPath: home).appendingPathComponent(".local")
        let releases = local.appendingPathComponent("share/iphone-use/releases").resolvingSymlinksInPath()
        let link = local.appendingPathComponent("bin/iphone-use")
        guard package.deletingLastPathComponent().path == releases.path,
              executable.path == package.appendingPathComponent("bin/iphone-use").path,
              FileManager.default.fileExists(atPath: package.appendingPathComponent(".curl-installed").path),
              link.resolvingSymlinksInPath().path == executable.path else {
            throw ValidationError("Use the original installation method to update this copy of iphone-use.")
        }

        // Download completely before executing. The installer rechecks ownership under its install lock.
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let script = temporary.appendingPathComponent("install.sh").path
        try runTool("/usr/bin/env", ["curl", "-q", "--proto", "=https", "--proto-redir", "=https",
                                     "--fail", "--silent", "--show-error", "--location",
                                     "--output", script, "https://iphone-use.com/install.sh"])
        // An absolute invocation can select this installation even when brew is first on PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = link.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        try runTool("/bin/sh", [script, "--upgrade"], environment: environment)
    }

    private func runTool(_ path: String, _ arguments: [String], environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw ExitCode.failure }
    }
}
