import Foundation

/// Display-only relationships. Original parents and element references stay in the capture.
struct AXTabOwnership {
    var bars = Set<Int>()
    var owner: [Int: Int] = [:]
    var wrappers = Set<Int>()

    init(_ nodes: [AXNode], selected: Set<Int>) {
        var enclosingBar: [Int?] = []
        for node in nodes {
            let traits = AXPresentationTraits(node)
            let enclosing = node.parent.flatMap { enclosingBar[$0] }
            if Self.isBar(node, traits: traits) {
                enclosingBar.append(node.index)
                continue
            }
            if let enclosing, selected.contains(node.index), node.attributes["visible"] as? Bool == true,
               traits.contains(.button), !traits.contains(.tabBar) {
                bars.insert(enclosing)
                owner[node.index] = enclosing
                var parent = node.parent
                while let index = parent, index != enclosing, wrappers.insert(index).inserted {
                    parent = nodes[index].parent
                }
            }
            enclosingBar.append(enclosing != nil && Self.isWrapper(node, traits: traits) ? enclosing : nil)
        }
    }

    private static func isBar(_ node: AXNode, traits: AXPresentationTraits) -> Bool {
        if node.hasNativeType("UITabBar") { return true }
        return traits.contains(.tabBar) && !traits.contains(.button) && isContainer(node)
    }

    private static func isContainer(_ node: AXNode) -> Bool {
        (node.role == "group" || node.role == "unknown") && !node.hasNativeType("UIToolbar")
            && !node.hasNativeType("UIControl") && !node.hasNativeType("UIButton")
    }

    private static func isWrapper(_ node: AXNode, traits: AXPresentationTraits) -> Bool {
        // Native snapshots also report 0x200000000 on otherwise plain layout views.
        // Additional trait bits may carry meaning, so keep those boundaries.
        isContainer(node) && (traits.isEmpty || traits.rawValue == 0x200000000)
            && node.label.isEmpty && node.identifier.isEmpty && node.value == nil
            && (node.attributes["hint"] as? String ?? "").isEmpty
            && node.enabled == nil && !(node.attributes["keyboardFocus"] is Bool)
    }
}
