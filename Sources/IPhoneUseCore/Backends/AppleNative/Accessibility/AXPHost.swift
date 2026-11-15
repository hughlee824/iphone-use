import Foundation
import AppleNativeBridge

// MobileDevice/private-framework calls run outside the session host. Its owned process is the
// deadline boundary, including a stuck framework call; process exit closes only its own USB streams.
public enum AXPHost {
    public static func run(device: String) throws {
        var error: NSError?
        guard let value = ASReadAXSnapshot(device, &error) else {
            throw error ?? IPhoneUseError("axp_unavailable", "Native AX snapshot unavailable")
        }
        var data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 12 * 1024 * 1024 else {
            throw IPhoneUseError("axp_output_limit", "Native AX output exceeded its budget")
        }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
