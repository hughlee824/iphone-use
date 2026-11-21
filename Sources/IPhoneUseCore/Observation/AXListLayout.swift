import Foundation

/// Display-only geometry for standard AX. Expand native list rows only in lists anchored
/// by the current AX selection. Supplemental candidates have no fabricated parent.
struct AXListLayout {
    var selected: Set<Int>
    var rows: Set<Int> = []
    var rowLabels: [Int: String] = [:]
    var incompleteContent = Set<Int>()
    var clips: [Int: AXListViewport] = [:]

    init(_ nodes: [AXNode], selected: Set<Int>, screen: CGRect?, tabs: AXTabOwnership) {
        // Older projections may already contain unknown images. Admit them only through row geometry below.
        self.selected = selected.filter { nodes[$0].role != "image" || nodes[$0].attributes["visible"] is Bool }
        guard let screen, !screen.isEmpty else { return }
        let context = AXListContext(nodes, selected: selected, screen: screen)
        let fieldBounds = Self.unknownImageBounds(nodes, context: context)
        incompleteContent = Self.incompleteAggregates(nodes, context: context)
        var rowFields: [Int: RowFields] = [:]
        var ownerText: [Int: [Int]] = [:]
        for node in nodes {
            let index = node.index
            let frame = PresentedAX.rect(node.attributes["frame"])
            guard admit(node, frame: frame, context: context) else { continue }
            guard !context.hidden[index], let frame, !frame.isEmpty else { continue }
            guard admitButtonLabel(node, frame: frame, nodes: nodes, confirmed: selected,
                                   viewport: context.bounds[index]) else { continue }
            guard let row = context.row[index], index != row, let table = context.table[row],
                  context.activeTables.contains(table), !context.bounds[row].isEmpty else { continue }

            if node.role == "text" || node.role == "image" {
                guard selectField(node, frame: frame, owner: context.controlOwner[index],
                                  fields: &rowFields[row, default: RowFields()], bounds: fieldBounds[index]) else {
                    continue
                }
                self.selected.insert(index)
                if let owner = node.parent, owner != row, self.selected.contains(owner),
                   !incompleteContent.contains(owner),
                   Self.isNamedControl(nodes[owner]), Self.plainText(node, under: nodes[owner]) {
                    ownerText[owner, default: []].append(index)
                }
            }
            if self.selected.contains(index) {
                self.selected.formUnion([row, table])
                rows.insert(row)
            }
        }
        removeCoveredText(ownerText, nodes: nodes)
        finishRowLabels(nodes, fields: rowFields)
        // A bar may be a structural container with no candidate visibility of its own.
        // Only surface it through a retained tab and respect hidden or clipped containers.
        self.selected.subtract(tabs.wrappers)
        self.selected.formUnion(self.selected.compactMap { tabs.owner[$0] })
    }

    private mutating func admit(_ node: AXNode, frame: CGRect?, context: AXListContext) -> Bool {
        let index = node.index
        let row = context.row[index]
        let bounds = context.bounds[index]
        if context.unlocatedRow[index], frame == nil || node.attributes["visible"] as? Bool != true {
            selected.remove(index)
            return false
        }
        let withinListOrTab = row != nil || node.role == "tab" || node.role == "tab_bar"
        let unlocatedInClippedRow = frame == nil && row.flatMap { clips[$0] } != nil
        if withinListOrTab && (bounds.isEmpty || context.hidden[index] || unlocatedInClippedRow) {
            selected.remove(index)
            return false
        }
        guard includeFrame(frame, bounds: bounds, index: index) else { return false }
        if !context.hidden[index], let frame, !frame.isEmpty, context.isNavigationTitle(node) { selected.insert(index) }
        if row == index, selected.contains(index), let table = context.table[index] {
            rows.insert(index)
            selected.insert(table)
        }
        return true
    }

    private mutating func admitButtonLabel(
        _ node: AXNode, frame: CGRect, nodes: [AXNode], confirmed: Set<Int>, viewport: AXListViewport
    ) -> Bool {
        guard let owner = Self.unnamedButton(of: node, nodes: nodes, confirmed: confirmed) else { return true }
        let bounds = PresentedAX.rect(owner.attributes["frame"]) ?? .null
        guard includeFrame(frame, bounds: viewport.intersection(bounds), index: node.index) else { return false }
        selected.insert(node.index)
        return true
    }

    private mutating func selectField(
        _ node: AXNode, frame: CGRect, owner: Int?, fields: inout RowFields, bounds: AXListViewport?
    ) -> Bool {
        guard !node.label.isEmpty || node.value != nil else { return false }
        if let bounds, !includeFrame(frame, bounds: bounds, index: node.index) { return false }
        let key = Field(node, frame: frame, exposed: clips[node.index] ?? AXListViewport(frame), owner: owner)
        guard fields.seen.insert(key).inserted else {
            selected.remove(node.index)
            return false
        }
        if node.role == "text", !node.label.isEmpty { fields.labels.insert(node.label) }
        return true
    }

    private mutating func includeFrame(_ frame: CGRect?, bounds: AXListViewport, index: Int) -> Bool {
        guard let frame else { return true }
        let intersection = bounds.intersection(frame)
        if intersection.isEmpty {
            selected.remove(index)
            return false
        }
        if intersection.bands != [frame] { clips[index] = intersection }
        return true
    }

    private mutating func finishRowLabels(_ nodes: [AXNode], fields: [Int: RowFields]) {
        for row in rows {
            let label = nodes[row].label
            let remaining = incompleteContent.contains(row) ? ""
                : Self.remainingLabel(label, children: fields[row]?.labels ?? [])
            if remaining != label { rowLabels[row] = remaining }
        }
    }

    // Match whole child strings at field boundaries. A child containing commas remains one match.
    // Repeated or overlapping matches cannot uniquely attribute the text to that child.
    static func remainingLabel(_ label: String, children: Set<String>) -> String {
        if children.contains(label) { return "" }
        guard !children.isEmpty, label.contains(",") else { return label }
        let parts = label.components(separatedBy: ",")
        var removed = IndexSet()
        for child in children {
            let words = child.components(separatedBy: ",")
            var match: Range<Int>?
            for start in parts.indices where parts[start] == words[0] && words.count <= parts.count - start {
                let range = start..<(start + words.count)
                guard parts[range].elementsEqual(words) else { continue }
                guard match == nil else { return label }
                match = range
            }
            if let match {
                guard !removed.intersects(integersIn: match) else { return label }
                removed.insert(integersIn: match)
            }
        }
        return parts.indices.filter { !removed.contains($0) }.map { parts[$0] }.joined(separator: ",")
    }

    private struct RowFields {
        var seen = Set<Field>()
        var labels = Set<String>()
    }

    private struct Field: Hashable {
        let role: String
        let label: String
        let value: String
        let identifier: String
        let rect: CGRect
        let exposed: AXListViewport
        let owner: Int?
        let visible: Bool?
        let enabled: Bool?
        let focus: Bool?

        init(_ node: AXNode, frame: CGRect, exposed: AXListViewport, owner: Int?) {
            self.owner = owner
            self.exposed = exposed
            role = node.role
            label = node.label
            value = node.value.map(quoted) ?? ""
            identifier = node.identifier
            visible = node.attributes["visible"] as? Bool
            enabled = node.enabled
            focus = node.attributes["keyboardFocus"] as? Bool
            rect = frame
        }
    }
}
