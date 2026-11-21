import Foundation
import CoreGraphics

extension PresentedAX {
    // A presentation hint only: never infer native visible, enabled, focus or action validity.
    // Only direct children of original confirmed candidates qualify; additions cannot expand themselves.
    static func childControls(
        _ nodes: [AXNode], selected: Set<Int>, screen: CGRect?, clips: [CGRect?]
    ) -> Set<Int> {
        guard let screen, !screen.isEmpty else { return [] }
        var result: Set<Int> = []
        let parents = Set(nodes.compactMap(\.parent))
        for node in nodes {
            guard node.attributes["candidateVisibilityUnknown"] as? Bool != true,
                  !(node.attributes["visible"] is Bool), !parents.contains(node.index),
                  !["key", "keyboard"].contains(node.role),
                  node.attributes["reportedChildCount"] as? Int == 0,
                  let parentIndex = node.parent, selected.contains(parentIndex),
                  independentControl(node, parent: nodes[parentIndex]),
                  let frame = rect(node.attributes["frame"]), !frame.isEmpty,
                  let parentFrame = rect(nodes[parentIndex].attributes["frame"]),
                  screen.contains(frame), parentFrame.contains(frame),
                  clips[node.index]?.contains(frame) == true else { continue }
            result.insert(node.index)
        }
        return result
    }

    private static func independentControl(_ node: AXNode, parent: AXNode) -> Bool {
        guard parent.attributes["visible"] as? Bool == true,
              !["application", "window", "keyboard"].contains(parent.role),
              !parent.label.isEmpty || !parent.identifier.isEmpty,
              !node.label.isEmpty || !node.identifier.isEmpty,
              node.attributes["externalProcessReference"] as? Bool == false,
              parent.attributes["externalProcessReference"] as? Bool == false,
              let element = node.attributes["nativeElement"] as? [String: Any],
              let parentElement = parent.attributes["nativeElement"] as? [String: Any],
              let pid = element["pid"] as? Int, pid > 0, parentElement["pid"] as? Int == pid,
              let identity = element["objectID"] as? String,
              let parentIdentity = parentElement["objectID"] as? String,
              UInt64(identity) != nil, UInt64(parentIdentity) != nil, identity != parentIdentity
        else { return false }
        let controls: Set<String> = ["button", "switch", "text_field", "secure_text_field", "search_field"]
        if controls.contains(node.role) { return true }
        let native = node.attributes["nativeAttributes"] as? [String: Any]
        // Native UIAccessibilityTraitButton; role may be unknown for a SwiftUI AX node.
        guard let traits = native?["2004"] as? NSNumber,
              CFGetTypeID(traits) != CFBooleanGetTypeID() else { return false }
        return traits.uint64Value & 1 != 0
    }
}
