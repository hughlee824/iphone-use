import Foundation

// Presentation policy only; never removes cached nodes or grants input authority.
enum AXKeyboardPresentation {
    static func ordinaryCharacterIndices(_ nodes: [AXNode]) -> Set<Int> {
        let parents = Set(nodes.compactMap(\.parent))
        var inside: Set<Int> = []
        var omitted: Set<Int> = []
        for node in nodes {
            guard let native = node.attributes["nativeAttributes"] as? [String: Any] else { continue }
            let type = native["5003"] as? String
            if type == "UIKeyboardLayoutStar" || node.parent.map({ inside.contains($0) }) == true {
                inside.insert(node.index)
            }
            guard inside.contains(node.index), type == "UIAccessibilityElementKBKey",
                !parents.contains(node.index) else { continue }
            let characters = Array(node.label.unicodeScalars)
            let printable = characters.count == 1 && (33...126).contains(characters[0].value)
            let space = node.label == "space" && node.identifier == "space"
            if printable || space { omitted.insert(node.index) }
        }
        return omitted
    }
}
