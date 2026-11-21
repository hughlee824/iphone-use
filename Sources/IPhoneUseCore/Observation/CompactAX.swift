import Foundation
import CoreGraphics

enum CompactAX {
    static func render(_ nodes: [AXNode], including: Set<Int>? = nil) -> [String] {
        render(nodes, including: including, layout: nil).lines
    }

    static func render(
        _ nodes: [AXNode], including: Set<Int>?, layout: AXListLayout?
    ) -> (lines: [String], hasUnknownVisibility: Bool) {
        var children = Array(repeating: [Int](), count: nodes.count)
        for node in nodes { if let parent = node.parent { children[parent].append(node.index) } }
        var kept: [Int] = []
        var ancestor: [Int: Int] = [:]
        var depths: [Int: Int] = [:]
        var signatures: [Int: Set<String>] = [:]
        for node in nodes {
            let nearest = node.parent.flatMap { ancestor[$0] }
            // When the row label is moved to its child, compare against the label actually rendered.
            let namedAncestor = nearest.flatMap { index -> AXNode? in
                if let layout {
                    if layout.incompleteContent.contains(index) || layout.rowLabels[index] != nil { return nil }
                    if node.role == "text", !(node.attributes["visible"] is Bool),
                       !AXListLayout.plainText(node, under: nodes[index]) { return nil }
                }
                return nodes[index]
            }
            var keep = shouldKeep(node, nearest: namedAncestor, children: children[node.index].map { nodes[$0] })
            if let including, !including.contains(node.index) { keep = false }
            // Only fold identical generic container siblings, never equally named controls.
            if node.role == "group", node.identifier.isEmpty,
               !(node.attributes["keyboardFocus"] is Bool), let parent = node.parent {
                var signature = node.attributes
                signature.removeValue(forKey: "index")
                signature.removeValue(forKey: "parent")
                let key = quoted(signature)
                if signatures[parent, default: []].contains(key),
                    children[node.index].allSatisfy({
                        nodes[$0].role == "group" && nodes[$0].label.isEmpty && nodes[$0].value == nil
                            && nodes[$0].enabled == true
                    }) {
                    keep = false
                }
                signatures[parent, default: []].insert(key)
            }
            if keep {
                depths[node.index] = nearest.map { (depths[$0] ?? 0) + 1 } ?? 0
                ancestor[node.index] = node.index
                kept.append(node.index)
            } else {
                ancestor[node.index] = nearest
            }
        }
        let names = Dictionary(grouping: kept, by: { "\(nodes[$0].role):\(nodes[$0].label)" })
        var hasUnknownVisibility = false
        let lines = kept.map { index in
            let node = nodes[index]
            let unknown = layout != nil && !(node.attributes["visible"] is Bool)
            hasUnknownVisibility = hasUnknownVisibility || unknown
            return renderNode(node, depth: depths[index] ?? 0, names: names, layout: layout, unknownVisibility: unknown)
        }
        return (lines, hasUnknownVisibility)
    }

    private static func shouldKeep(_ node: AXNode, nearest: AXNode?, children: [AXNode]) -> Bool {
        if isRedundantStructure(node, children: children) { return false }
        if node.attributes["keyboardFocus"] is Bool { return true }
        let generic = ["group", "application", "window"].contains(node.role)
        var keep =
            !generic || !node.label.isEmpty || !node.identifier.isEmpty || node.value != nil
            || node.enabled == false
            || (children.isEmpty && node.enabled == nil && node.attributes["frame"] is [String: Any])
        if node.role == "application" { keep = false }
        if generic, !children.isEmpty, node.enabled != false, node.value == nil, node.identifier.isEmpty,
            children.contains(where: { $0.label == node.label }) {
            keep = false
        }
        if let nearest, node.role == "text", node.enabled != false, node.label == nearest.label,
            node.value == nil || (node.value as? String) == node.label {
            keep = false
        }
        if let nearest, node.role == "web_view", nearest.role == "web_view",
            node.label.isEmpty, node.identifier.isEmpty, node.value == nil, node.enabled != false {
            keep = false
        }
        return keep
    }

    private static func renderNode(
        _ node: AXNode, depth: Int, names: [String: [Int]], layout: AXListLayout?, unknownVisibility: Bool
    ) -> String {
        let row = layout?.rows.contains(node.index) == true
        let marker = unknownVisibility ? "?" : ""
        let incomplete = layout?.incompleteContent.contains(node.index) == true
        let indent = String(repeating: "  ", count: layout == nil ? depth : depth + 1)
        var line = indent + "[\(node.ref)\(marker)] \(row ? "row" : node.role)"
        let label = incomplete ? "" : (layout?.rowLabels[node.index] ?? node.label)
        if !label.isEmpty { line += " \(quoted(label))" }
        if layout != nil, node.role == "tab", AXPresentationTraits(node).contains(.selected) {
            line += " selected=true"
        }
        let input = ["text_field", "secure_text_field", "text_view", "search_field"].contains(node.role)
        let value = input ? node.attributes["value"] : node.value
        if !incomplete, let value, !(value is NSNull), input || (value as? String) != node.label {
            line += " ax_value=\(quoted(value))"
        }
        if !incomplete, !node.identifier.isEmpty,
            node.label.isEmpty || names["\(node.role):\(node.label)", default: []].count > 1 {
            line += " id=\(quoted(node.identifier))"
        }
        if node.enabled == false { line += " disabled" }
        if node.enabled == true { line += " enabled=true" }
        if let focus = node.attributes["keyboardFocus"] as? Bool {
            line += " keyboard_focus=\(focus)"
        }
        if let layout, let rect = PresentedAX.rect(node.attributes["frame"]) {
            line += " @" + StandardCompactAX.coordinates(rect)
            if let clip = layout.clips[node.index] {
                line += " clip=" + clip.bands.map(StandardCompactAX.coordinates).joined(separator: "|")
            }
        }
        return line
    }
}
