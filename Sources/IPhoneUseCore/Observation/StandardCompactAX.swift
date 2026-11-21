import Foundation

/// A read-only projection. Node references, attributes and action admission belong to the original capture.
enum StandardCompactAX {
    static let legend = "geometry: @x,y,w,h in screen points; origin=top-left; clip=geometric intersection"

    static func number(_ value: CGFloat) -> String {
        let text = String(Double(value))
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func coordinates(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.width, rect.height].map(number).joined(separator: ",")
    }

    static func header(_ capture: CapturedObservation, id: String) -> String {
        let metadata = capture.metadata
        var fields = ["obs=\(id)"]
        if let app = metadata["axApplicationBundleId"] as? String {
            fields.append("ax_app=\(app)")
        }
        if let screen = PresentedAX.rect(metadata["screenFrame"]) {
            fields.append("screen=\(number(screen.width))x\(number(screen.height))pt")
        }
        if metadata["axStatus"] as? String != "available" {
            fields.append("ax=unavailable")
            if let error = metadata["axError"] as? String {
                fields.append("reason=\(quoted(String(error.prefix(256))))")
            }
        }
        if metadata["sourceTruncated"] as? Bool == true { fields.append("truncated=true") }
        if let stability = metadata["postActionStability"] as? [String: Any], stability["stable"] as? Bool == false {
            fields.append("stable=false")
        }
        if !capture.nodes.isEmpty { fields.append("[eN?]=AX visibility unknown") }
        return fields.joined(separator: " ")
    }

    static func lines(_ capture: CapturedObservation, id: String) -> [String] {
        let projection = PresentedAX.project(capture)
        let tabs = AXTabOwnership(capture.nodes, selected: projection.indices)
        let nodes = presentationRoles(capture.nodes, tabs: tabs)
        let screen = PresentedAX.rect(capture.metadata["screenFrame"])
        let layout = AXListLayout(nodes, selected: projection.indices, screen: screen, tabs: tabs)
        let collection = capture.metadata["axCollection"] as? [String: Any]
        var lines = [header(capture, id: id)]
        if let omitted = collection?["omittedSupplementalCandidateCount"] as? Int, omitted > 0 {
            lines.append("ax_omitted_supplemental_candidates=\(omitted)")
        }
        return lines + CompactAX.render(nodes, including: layout.selected, layout: layout)
    }

    private static func presentationRoles(_ nodes: [AXNode], tabs: AXTabOwnership) -> [AXNode] {
        let parents = Set(nodes.compactMap(\.parent))
        return nodes.map { node in
            let traits = AXPresentationTraits(node)
            let role: String
            if tabs.bars.contains(node.index) {
                role = "tab_bar"
            } else if tabs.owner[node.index] != nil {
                role = "tab"
            } else if node.role == "unknown", traits.contains(.staticText), !traits.contains(.button),
                      !(node.attributes["visible"] is Bool), !node.label.isEmpty, !parents.contains(node.index),
                      (node.attributes["reportedChildCount"] as? Int ?? 0) == 0 {
                role = "text"
            } else {
                return node
            }
            return AXNode(index: node.index, parent: node.parent, role: role, attributes: node.attributes)
        }
    }
}
