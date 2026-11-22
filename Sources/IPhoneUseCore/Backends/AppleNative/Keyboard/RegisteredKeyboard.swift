import Foundation
import CoreFoundation

// One registration attempt per lease. A lost create reply can leave a surface on
// the device. Retiring its connection is safe, guessing a service to remove isn't.
final class RegisteredKeyboard {
    private let open: () throws -> NativeTransport
    static let requestedID: UInt64 = 0x100002001
    private let product = "iPhone-use keyboard " + UUID().uuidString
    private var transport: NativeTransport?
    private var attempted = false
    private(set) var registrationMayExist = false
    private(set) var serviceID: UInt64?

    init(open: @escaping () throws -> NativeTransport) {
        self.open = open
    }

    private func envelope(_ payload: [String: Any]) -> [String: Any] {
        ["featureIdentifier": NativeHIDAdapter.feature, "messageType": "Request", "payload": payload]
    }

    func prepare() throws -> UInt64 {
        if let serviceID { return serviceID }
        guard !attempted else {
            throw IPhoneUseError("native_keyboard_unavailable", "RSD registration already attempted; reconnect")
        }
        attempted = true
        let channel = try open()
        transport = channel
        do {
            let before = try inventory(channel)
            guard !before.contains(where: { identifier($0["_ServiceID"]) == Self.requestedID }) else {
                throw IPhoneUseError("native_keyboard_collision", "Requested keyboard identity is already in use")
            }
            registrationMayExist = true
            let response = try channel.request(envelope(["createService": ["_0": descriptor]]), timeout: 5)
            guard response["error"] == nil else { throw KeyboardXPC.invalid }
            let id: UInt64
            if let assigned = response["serviceID"] {
                guard let valid = identifier(assigned) else { throw KeyboardXPC.invalid }
                id = valid
            } else { id = Self.requestedID }
            guard !before.contains(where: { identifier($0["_ServiceID"]) == id }) else { throw KeyboardXPC.invalid }
            Thread.sleep(forTimeInterval: 0.3)
            guard owns(id, in: try inventory(channel)) else {
                throw IPhoneUseError("native_keyboard_ownership_unknown", "Device did not list the registered keyboard")
            }
            serviceID = id
            return id
        } catch { channel.cancel(); throw error }
    }

    func send(_ report: Data) throws {
        guard let transport, let serviceID else { throw KeyboardXPC.invalid }
        try transport.send(envelope(["send": ["_0": report, "_1": nativeUInt(serviceID)]]), timeout: 3)
    }

    func close() -> [String: Any] {
        let required = registrationMayExist
        var facts: [String: Any] = ["keyboardServiceSource": "rsd_registered", "keyboardRemovalRequired": required]
        defer { transport?.cancel(); transport = nil; serviceID = nil }
        if let transport, let serviceID {
            do {
                let current = try inventory(transport)
                if owns(serviceID, in: current) {
                    try transport.send(envelope(["removeService": ["_0": nativeUInt(serviceID)]]), timeout: 3)
                    let remaining = try inventory(transport)
                    registrationMayExist = remaining.contains { identifier($0["_ServiceID"]) == serviceID }
                } else if !current.contains(where: { identifier($0["_ServiceID"]) == serviceID }) {
                    registrationMayExist = false
                }
            } catch { facts["keyboardRemoveError"] = String(describing: error) }
        }
        facts["keyboardRemoveAcknowledged"] = !registrationMayExist
        return facts
    }

    private func inventory(_ channel: NativeTransport) throws -> [[String: Any]] {
        let response = try channel.request(envelope(["connectedServices": [:]]), timeout: 4)
        guard let services = response["connectedServices"] as? [[String: Any]],
            services.allSatisfy({ identifier($0["_ServiceID"]) != nil }) else { throw KeyboardXPC.invalid }
        return services
    }
    private func identifier(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let id = UInt64(number.stringValue), id > 0 else { return nil }
        return id
    }
    private func owns(_ id: UInt64, in inventory: [[String: Any]]) -> Bool {
        let matches = inventory.filter { identifier($0["_ServiceID"]) == id }
        return matches.count == 1 && matches[0]["Product"] as? String == product
    }

    private var descriptor: [String: Any] {
        // Generic Desktop / Keyboard, six keycodes, eight modifiers and five LED outputs.
        let report = Data([
            0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7,
            0x15, 0x00, 0x25, 0x01, 0x95, 0x08, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01,
            0x75, 0x08, 0x81, 0x01, 0x05, 0x07, 0x19, 0x00, 0x29, 0xff, 0x15, 0x00,
            0x26, 0xff, 0x00, 0x95, 0x06, 0x75, 0x08, 0x81, 0x00, 0x05, 0x08, 0x19,
            0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x91,
            0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0xc0
        ])
        let usages = ["DeviceUsagePage": 1, "DeviceUsage": 6]
        let storage: [String: Any] = [
            "Manufacturer": ["string": "iPhone-use"], "Product": ["string": product],
            "VendorID": ["int": 0], "ProductID": ["int": 1], "Transport": ["string": "USB"],
            "PrimaryUsagePage": ["int": 1], "PrimaryUsage": ["int": 6],
            "DeviceUsagePairs": ["array": [["dictionary": usages.mapValues { ["int": $0] }]]],
            "ReportDescriptor": ["data": report], "UniversalControlVirtualService": ["bool": true],
            "_ServiceID": ["uint": nativeUInt(Self.requestedID)]
        ]
        return [
            "Product": product, "VendorID": 0, "ProductID": 1, "PrimaryUsagePage": nativeUInt(1),
            "PrimaryUsage": nativeUInt(6), "DeviceUsagePairs": [usages], "_ServiceID": nativeUInt(Self.requestedID),
            "_CoreDevice_codablePropertyStorage": storage
        ]
    }
}
