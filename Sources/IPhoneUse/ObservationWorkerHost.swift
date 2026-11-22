import ArgumentParser
import IPhoneUseCore

struct ObservationWorkerHost: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_observation-worker", shouldDisplay: false)
    @Option var device: String
    @Option var kind: String
    @Option var generation: String
    mutating func run() throws { try NativeObservationHost.run(device: device, kind: kind, generation: generation) }
}

struct KeyboardTunnelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_keyboard-tunnel", shouldDisplay: false)
    @Option var device: String
    mutating func run() throws { try KeyboardTunnelHost.run(device: device) }
}
