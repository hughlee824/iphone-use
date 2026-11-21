import Foundation

/// A read-only projection. Node references, attributes and action admission belong to the original capture.
enum StandardCompactAX {
    static let legend = "@x,y,w,h = absolute screen points from top-left; "
        + "clip = bounds after geometric clipping (| separates regions)"

    static func standaloneDocument(_ text: String) -> String {
        var document = text
        let headerEnd = document.firstIndex(of: "\n") ?? document.endIndex
        document.insert(contentsOf: "\n" + legend, at: headerEnd)
        return document
    }

    static func number(_ value: CGFloat) -> String {
        let text = String(Double(value))
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func coordinates(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.width, rect.height].map(number).joined(separator: ",")
    }

    private static func header(_ capture: CapturedObservation, id: String, hasUnknownVisibility: Bool) -> String {
        let metadata = capture.metadata
        var fields = ["obs=\(id)"]
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
        let collection = metadata["axCollection"] as? [String: Any]
        if let omitted = collection?["omittedSupplementalCandidateCount"] as? Int, omitted > 0 {
            fields.append("ax_omitted_supplemental_candidates=\(omitted)")
        }
        if hasUnknownVisibility { fields.append("[eN?]=AX visibility unknown") }
        return fields.joined(separator: " ")
    }

    static func lines(_ capture: CapturedObservation, id: String) -> [String] {
        let projection = PresentedAX.project(capture)
        let tabs = AXTabOwnership(capture.nodes, selected: projection.indices)
        let nodes = presentationRoles(capture.nodes, tabs: tabs)
        let screen = PresentedAX.rect(capture.metadata["screenFrame"])
        let layout = AXListLayout(nodes, selected: projection.indices, screen: screen, tabs: tabs)
        let body = CompactAX.render(nodes, including: layout.selected, layout: layout)
        let info = header(capture, id: id, hasUnknownVisibility: body.hasUnknownVisibility)
        guard !nodes.isEmpty || capture.metadata["axStatus"] as? String == "available" else { return [info] }

        var root = "[app]"
        if let app = capture.metadata["axApplicationBundleId"] as? String, !app.isEmpty { root += " " + app }
        if let screen { root += " @" + coordinates(screen) }
        return [info, root] + body.lines
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
