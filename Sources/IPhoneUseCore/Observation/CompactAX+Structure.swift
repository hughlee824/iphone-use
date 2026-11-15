import Foundation

extension CompactAX {
    // Only collapse recognized layout wrappers, never arbitrary unknown controls or cells.
    static func isRedundantStructure(_ node: AXNode, children: [AXNode]) -> Bool {
        guard node.role == "unknown", children.count == 1,
              node.label.isEmpty, node.identifier.isEmpty, node.value == nil,
              node.enabled == nil, !(node.attributes["keyboardFocus"] is Bool),
              (node.attributes["hint"] as? String ?? "").isEmpty,
              let native = node.attributes["nativeAttributes"] as? [String: Any],
              let type = native["5003"] as? String else { return false }
        let wrappers: Set<String> = [
            "UITransitionView", "UIDropShadowView", "UILayoutContainerView",
            "UINavigationTransitionView", "UIViewControllerWrapperView",
            "_UISplitViewControllerAdaptiveColumnContainerView", "_UISplitViewControllerAdaptiveColumnView"
        ]
        guard wrappers.contains(type) else { return false }
        // Unrecognized semantic fields or incomplete children are not evidence of a redundant wrapper.
        let knownFields: Set<String> = [
            "index", "parent", "ref", "role", "label", "identifier", "value", "hint", "frame",
            "enabled", "keyboardFocus", "visible", "nativeAttributes", "nativeElement",
            "attributeSource", "externalProcessReference", "reportedChildCount"
        ]
        guard Set(node.attributes.keys).isSubset(of: knownFields),
              node.attributes["externalProcessReference"] as? Bool != true,
              (node.attributes["reportedChildCount"] as? Int ?? 1) == 1,
              let frame = node.attributes["frame"] as? NSDictionary,
              let childFrame = children[0].attributes["frame"] as? NSDictionary,
              frame.isEqual(childFrame) else { return false }
        let knownNative: Set<String> = ["2001", "2002", "2003", "2004", "2006", "2025", "3003", "5003", "5004", "5019"]
        guard Set(native.keys).isSubset(of: knownNative),
              let traits = native["2004"] as? NSNumber else { return false }
        let childNative = children[0].attributes["nativeAttributes"] as? [String: Any]
        // Never discard traits unique to the wrapper, even when its class looks structural.
        return traits.uint64Value == 0 || traits == childNative?["2004"] as? NSNumber
    }
}
