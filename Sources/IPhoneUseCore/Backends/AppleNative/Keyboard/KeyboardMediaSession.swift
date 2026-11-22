import Foundation
import AppleNativeBridge

// The USB packet pump drains video in place. Only packet counts cross into the keyboard helper.
private final class KeyboardMediaReceiver: NativeMediaReceiver {
    let endpoint: ASKeyboardMediaEndpoint
    var address: String { endpoint.localAddress }
    var port: UInt16 { endpoint.receiverPort }
    private var source: UInt16?
    private var ssrc: UInt32?

    init(_ endpoint: ASKeyboardMediaEndpoint) { self.endpoint = endpoint }

    func configure(_ configuration: [String: Any]) throws {
        guard let source = configuration["SourcePort"] as? NSNumber,
            let port = UInt16(source.stringValue), port > 0,
            let ssrc = configuration["LocalSSRC"] as? NSNumber, let remote = UInt32(ssrc.stringValue)
        else { throw IPhoneUseError("native_media_unsupported", "Invalid RTP source") }
        self.source = port
        self.ssrc = remote
    }

    func health() -> [String: Any] {
        guard let source, let ssrc else { return ["healthy": false] }
        return ["healthy": endpoint.received(fromPort: source, ssrc: ssrc) > 0]
    }
    func close() { source = nil; ssrc = nil }
}

final class KeyboardMediaSession {
    private let identifier: String
    private let display: UInt64
    private var session: NativeMediaSession?

    init(identifier: String, display: UInt64) { self.identifier = identifier; self.display = display }

    func start(_ endpoint: ASKeyboardMediaEndpoint) throws {
        let transport = AppleServiceTransport(channel: AppleRemoteChannel(channel: endpoint.channel))
        let receiver = KeyboardMediaReceiver(endpoint)
        let client = NativeFeatureClient(
            transport: transport, deviceIdentifier: identifier, version: try NativeMediaFactory.coreDeviceVersion())
        let stream = NativeMediaSession(client: client, receiver: receiver)
        session = stream
        let negotiator = try ASMediaNegotiator(error: ())
        try stream.start(displayID: display, deviceAddress: endpoint.deviceAddress, offer: negotiator.offer) {
            try negotiator.acceptAnswer($0)
        }
        let start = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 0.5)
        while receiver.health()["healthy"] as? Bool != true {
            guard ProcessInfo.processInfo.systemUptime < start + 5 else {
                throw IPhoneUseError(
                    "native_media_unhealthy", "No negotiated video RTP received on the keyboard tunnel")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func close() -> Bool {
        guard let session else { return true }
        return session.close()["mediaStopAcknowledged"] as? Bool == true
    }
}
