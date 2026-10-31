import Foundation
import CoreFoundation

struct NativeTouchSurface {
    let id: UInt64
    let displayUniqueID: String?

    static func select(_ services: [[String: Any]], displayUniqueID: String?) throws -> NativeTouchSurface {
        let touchscreens = services.filter {
            ($0["PrimaryUsagePage"] as? NSNumber)?.intValue == 13
                && ($0["PrimaryUsage"] as? NSNumber)?.intValue == 4
                && $0["UniversalControlBuiltIn"] as? Bool == true
        }
        let matches: [[String: Any]]
        if touchscreens.contains(where: { $0["displayUUID"] != nil }) {
            guard let displayUniqueID, !displayUniqueID.isEmpty else {
                throw IPhoneUseError(
                    "native_hid_unsupported", "Touchscreen selection requires the active display identity")
            }
            matches = touchscreens.filter { $0["displayUUID"] as? String == displayUniqueID }
        } else {
            // Older single-screen devices advertise no display UUID. Preserve
            // that contract only when the complete touchscreen set is unique.
            matches = touchscreens
        }
        guard matches.count == 1, let value = matches.first,
            let identifier = value["_ServiceID"] as? NSNumber,
            CFGetTypeID(identifier) != CFBooleanGetTypeID(), identifier.doubleValue > 0,
            identifier.doubleValue.isFinite, identifier.doubleValue.rounded() == identifier.doubleValue,
            identifier.uint64Value > 0 else {
            throw IPhoneUseError("native_hid_unsupported", "No unique built-in touchscreen for the observed display")
        }
        let id = identifier.uint64Value
        guard services.filter({ ($0["_ServiceID"] as? NSNumber)?.uint64Value == id }).count == 1 else {
            throw IPhoneUseError("native_hid_unsupported", "Touchscreen service identity is duplicated")
        }
        return NativeTouchSurface(id: id, displayUniqueID: value["displayUUID"] as? String)
    }
}
