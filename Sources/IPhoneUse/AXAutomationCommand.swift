import ArgumentParser
import Foundation
import IPhoneUseCore

struct AXAutomationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_ax-automation", shouldDisplay: false)
    @Option var device: String
    @Option var journal: String
    @Option var token: String
    @Option var enabled: Bool
    @Option var output: String

    mutating func run() throws {
        try AXAutomationHost.run(
            device: device, journal: URL(fileURLWithPath: journal), token: token, enabled: enabled,
            output: URL(fileURLWithPath: output))
    }
}
