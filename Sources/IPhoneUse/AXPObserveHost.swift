import ArgumentParser
import IPhoneUseCore

struct AXPObserveHost: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_axp-observe", shouldDisplay: false)
    @Option var device: String
    mutating func run() throws { try AXPHost.run(device: device) }
}
