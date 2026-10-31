import IPhoneUseRunnerSupport
import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

struct NativeDisplay: Equatable {
    struct Geometry: Equatable {
        let id: UInt64
        let uniqueID: String?
        let width: Double, height: Double, scale: Double
        let rotation: String, nativeRotation: String
        init(_ display: NativeDisplay) {
            id = display.id; width = display.pixelWidth; height = display.pixelHeight
            uniqueID = display.uniqueID
            scale = display.scale; rotation = display.rotation; nativeRotation = display.nativeRotation
        }
    }
    var geometry: Geometry { Geometry(self) }
    let id: UInt64
    let uniqueID: String?
    let pixelWidth: Double
    let pixelHeight: Double
    let scale: Double
    let rotation: String
    let nativeRotation: String
    let backlightOn: Bool
    func screenshotArguments(destination: URL) -> [String] {
        ["device", "capture", "screenshot"]
            + (uniqueID.map { ["--display-unique-id", $0] } ?? [])
            + ["--destination", destination.path]
    }
    var screen: ScreenRect {
        ScreenRect(CGRect(x: 0, y: 0, width: pixelWidth / scale, height: pixelHeight / scale))
    }
    var context: ScreenContext {
        let orientation = ["rot0": 1, "rot90": 4, "rot180": 2, "rot270": 3][rotation] ?? 0
        // Native screenshots have no keyboard/AX count; this placeholder is only for grid
        // comparison. keyboardState is explicitly unknown in the observation metadata.
        return ScreenContext(screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
    }
    init(_ result: [String: Any]) throws {
        guard let displays = result["displays"] as? [[String: Any]] else {
            throw IPhoneUseError("native_display_unavailable", "Display list missing")
        }
        let value = try Self.selectedDisplay(displays)
        guard
            let id = value["displayId"] as? NSNumber, id.uint64Value > 0,
            let bounds = value["bounds"] as? [[NSNumber]], bounds.count == 2,
            bounds.allSatisfy({ $0.count == 2 }),
            bounds[0].map(\.doubleValue) == [0, 0],
            bounds[1].allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue > 0 && $0.doubleValue <= 16384 }
            ),
            let scale = value["pointScale"] as? NSNumber, scale.doubleValue.isFinite, scale.doubleValue >= 1,
            let rotation = value["currentOrientation"] as? String,
            ["rot0", "rot90", "rot180", "rot270"].contains(rotation),
            let native = value["nativeOrientation"] as? String,
            ["rot0", "rot90", "rot180", "rot270"].contains(native)
        else { throw IPhoneUseError("native_display_unavailable", "Unknown active display geometry") }
        let uniqueID = value["uniqueId"] as? String
        if let uniqueID {
            guard !uniqueID.isEmpty, uniqueID.utf8.count <= 256,
                !uniqueID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw IPhoneUseError("native_display_unavailable", "Invalid display identity") }
        }
        guard uniqueID != nil || value["primary"] as? Bool == true else {
            throw IPhoneUseError("native_display_unavailable", "Active display has no screenshot identity")
        }
        // CoreDevice bounds remain in native display axes when the scene rotates;
        // devicectl's PNG is already oriented. Do not rotate or resample that PNG.
        let quarterTurn = ["rot90", "rot270"].contains(rotation) != ["rot90", "rot270"].contains(native)
        self.id = id.uint64Value
        self.uniqueID = uniqueID
        pixelWidth = bounds[1][quarterTurn ? 1 : 0].doubleValue
        pixelHeight = bounds[1][quarterTurn ? 0 : 1].doubleValue
        self.scale = scale.doubleValue
        self.rotation = rotation; nativeRotation = native
        // XCTest can leave an unlocked, visible display dimmed. Both active
        // states are lit; inactive and unknown states still fail closed.
        let backlight = value["backlightState"] as? String
            ?? (displays.count == 1 ? result["backlightState"] as? String : nil)
        backlightOn = value["active"] as? Bool != false
            && ["activeOn", "activeDimmed"].contains(backlight ?? "")
    }

    private static func selectedDisplay(_ displays: [[String: Any]]) throws -> [String: Any] {
        // Older phones add a dormant Wireless display when media capture starts,
        // without activity flags. It is not a second physical touch screen.
        if displays.count > 1, displays.allSatisfy({ $0["active"] == nil }) {
            let integrated = displays.filter { ($0["type"] as? [String: Any])?["integrated"] != nil }
            let dormantWireless = displays.filter {
                ($0["type"] as? [String: Any])?["wireless"] != nil
                    && $0["primary"] as? Bool == false && $0["backlightState"] as? String == "off"
            }
            if integrated.count == 1, integrated[0]["primary"] as? Bool == true,
                integrated.count + dormantWireless.count == displays.count {
                return integrated[0]
            }
        }
        // A foldable's primary display can remain the closed outer screen.
        // Never choose arbitrarily when multiple surfaces are active or changing.
        if displays.count > 1 || displays.contains(where: { $0["active"] != nil }) {
            guard displays.allSatisfy({ $0["active"] is Bool }) else {
                throw IPhoneUseError("native_display_unavailable", "Display activity is incomplete")
            }
            let active = displays.filter { $0["active"] as? Bool == true }
            if active.count == 1 { return active[0] }
            if displays.count == 1, active.isEmpty { return displays[0] }
        } else if displays.count == 1, displays[0]["primary"] as? Bool == true {
            // Older single-screen inventories do not report per-display activity.
            return displays[0]
        }
        throw IPhoneUseError("native_display_unavailable", "Expected one active display")
    }
}
