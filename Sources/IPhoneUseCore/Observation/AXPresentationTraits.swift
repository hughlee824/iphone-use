import Foundation

/// Native AX attribute 2004 contains a bitset. Other, unrelated traits may be present.
struct AXPresentationTraits: OptionSet {
    let rawValue: UInt64
    static let button = Self(rawValue: 0x1)
    static let selected = Self(rawValue: 0x8)
    static let staticText = Self(rawValue: 0x40)
    static let header = Self(rawValue: 0x10000)
    static let tabBar = Self(rawValue: 0x8000)

    init(rawValue: UInt64) { self.rawValue = rawValue }

    init(_ node: AXNode) {
        let native = node.attributes["nativeAttributes"] as? [String: Any]
        guard let number = native?["2004"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let bits = UInt64(exactly: number) else { self = []; return }
        self.init(rawValue: bits)
    }
}

extension AXNode {
    var isControlForListFields: Bool {
        ["button", "tab", "switch", "text_field", "secure_text_field", "search_field", "text_view"].contains(role)
            || AXPresentationTraits(self).contains(.button) || hasNativeType("UIControl")
    }

    func hasNativeType(_ type: String) -> Bool {
        let native = attributes["nativeAttributes"] as? [String: Any]
        return native?["5003"] as? String == type || native?["5004"] as? String == type
    }
}
