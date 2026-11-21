import Foundation

extension AXListLayout {
    static func unnamedButton(of node: AXNode, nodes: [AXNode], confirmed: Set<Int>) -> AXNode? {
        guard node.role == "text", !node.label.isEmpty, !(node.attributes["visible"] is Bool),
              let index = node.parent, confirmed.contains(index) else { return nil }
        let owner = nodes[index]
        guard ["button", "tab"].contains(owner.role), owner.label.isEmpty,
              owner.attributes["visible"] as? Bool == true else { return nil }
        return owner
    }

    static func isNamedControl(_ node: AXNode) -> Bool {
        !node.label.isEmpty && node.attributes["visible"] as? Bool == true
            && (["button", "tab"].contains(node.role) || (node.role == "unknown" && AXPresentationTraits(node)
                .contains(.button)))
    }

    static func plainText(_ node: AXNode, under owner: AXNode) -> Bool {
        guard node.role == "text", !node.label.isEmpty, !(node.attributes["visible"] is Bool),
              node.identifier.isEmpty, node.enabled == nil, !(node.attributes["keyboardFocus"] is Bool),
              !(AXPresentationTraits(node).contains(.button)) else { return false }
        guard let value = node.value else { return true }
        guard let text = value as? String else { return false }
        return text == node.label || text == owner.value as? String
    }

    mutating func removeCoveredText(_ groups: [Int: [Int]], nodes: [AXNode]) {
        for (owner, fields) in groups {
            let control = nodes[owner]
            let parts = fields.map { nodes[$0].label }
            if [", ", ","].contains(where: { parts.joined(separator: $0) == control.label }) {
                selected.subtract(fields)
            } else {
                selected.subtract(fields.filter {
                    nodes[$0].label == control.label || nodes[$0].label == control.value as? String
                })
            }
        }
    }

    // A composite can repeat text from its clipped descendants in its own AX label or value.
    // Keep the original references, but let individually located children supply that text.
    static func incompleteAggregates(_ nodes: [AXNode], context: AXListContext) -> Set<Int> {
        var partialRows = Set<Int>()
        var incomplete = Set<Int>()
        var unavailableChild = Set<Int>()
        let parents = Set(nodes.compactMap(\.parent))
        for node in nodes where context.row[node.index] == node.index {
            let frame = PresentedAX.rect(node.attributes["frame"])
            if context.unlocatedRow[node.index] || frame.map(context.bounds[node.index].contains) != true {
                partialRows.insert(node.index)
            }
        }
        for node in nodes.reversed() {
            let index = node.index
            guard let row = context.row[index], partialRows.contains(row) else { continue }
            // A hidden, empty image leaf contributes no text to an ancestor's label.
            if context.hidden[index], node.role == "image", node.label.isEmpty, node.value == nil,
               !parents.contains(index), (node.attributes["reportedChildCount"] as? Int ?? 0) == 0 { continue }
            let frame = PresentedAX.rect(node.attributes["frame"])
            let clipped = frame.map { !context.bounds[index].contains($0) } ?? true
            if clipped || unavailableChild.contains(index) || index == row {
                if index == row || parents.contains(index) || (node.attributes["reportedChildCount"] as? Int ?? 0) > 0 {
                    incomplete.insert(index)
                }
                if let parent = node.parent, index != row { unavailableChild.insert(parent) }
            }
        }
        return incomplete
    }

    // Intersect every intermediate container on the way from the owning row to an image.
    // A missing frame breaks this chain. A system-confirmed image needs no such inference.
    static func unknownImageBounds(_ nodes: [AXNode], context: AXListContext) -> [Int: AXListViewport] {
        var path = Array(repeating: AXListViewport(.null), count: nodes.count)
        var result: [Int: AXListViewport] = [:]
        for node in nodes {
            guard let row = context.row[node.index] else { continue }
            let inherited = row == node.index ? context.bounds[row]
                : (node.parent.map { path[$0] } ?? AXListViewport(.null))
            path[node.index] = inherited.intersection(PresentedAX.rect(node.attributes["frame"]) ?? .null)
            if node.role == "image", !(node.attributes["visible"] is Bool) {
                result[node.index] = path[node.index]
            }
        }
        return result
    }
}
