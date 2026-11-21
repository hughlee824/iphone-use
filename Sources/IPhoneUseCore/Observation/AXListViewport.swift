import Foundation

/// Disjoint horizontal bands left by a full-width bar, ordered from top to bottom.
struct AXListViewport: Hashable {
    let bands: [CGRect]

    init(_ frame: CGRect) {
        bands = frame.isEmpty ? [] : [frame]
    }

    private init(bands: [CGRect]) {
        self.bands = bands
    }

    var isEmpty: Bool { bands.isEmpty }

    func contains(_ frame: CGRect) -> Bool {
        bands.contains { $0.contains(frame) }
    }

    func intersection(_ frame: CGRect) -> Self {
        Self(bands: bands.map { $0.intersection(frame) }.filter { !$0.isEmpty })
    }

    func excluding(_ bar: CGRect, contentBelow: Bool, confirmed: [CGRect]) -> Self {
        Self(bands: bands.flatMap { band -> [CGRect] in
            let overlap = band.intersection(bar)
            guard !overlap.isEmpty else { return [band] }
            let above = CGRect(x: band.minX, y: band.minY, width: band.width, height: overlap.minY - band.minY)
            let below = CGRect(x: band.minX, y: overlap.maxY, width: band.width, height: band.maxY - overlap.maxY)
            guard !above.isEmpty, !below.isEmpty else { return [above, below].filter { !$0.isEmpty } }
            // An edge bar usually delimits the content viewport. Only expose the other side
            // when this list has confirmed row content there, beyond the covered band.
            let other = contentBelow ? above : below
            let hasContent = confirmed.contains {
                let exposed = $0.intersection(other)
                return !exposed.isEmpty && (contentBelow ? $0.maxY <= bar.maxY : $0.minY >= bar.minY)
            }
            return hasContent ? [above, below] : [contentBelow ? below : above]
        })
    }
}

extension AXListContext {
    func confirmedRowFrames(_ nodes: [AXNode], selected: Set<Int>, screen: CGRect) -> [Int: [CGRect]] {
        var frames: [Int: [CGRect]] = [:]
        for index in selected {
            guard row[index] != nil, !hidden[index], nodes[index].attributes["visible"] as? Bool == true,
                  let frame = PresentedAX.rect(nodes[index].attributes["frame"]) else { continue }
            var exposed = screen.intersection(frame)
            var lists: [Int] = []
            var ancestor = nodes[index].parent
            while let current = ancestor, !exposed.isEmpty {
                if table[current] == current { lists.append(current) }
                if clipsDescendants(nodes[current]), let bounds = PresentedAX.rect(nodes[current].attributes["frame"]) {
                    exposed = exposed.intersection(bounds)
                }
                ancestor = nodes[current].parent
            }
            if !exposed.isEmpty {
                for list in lists { frames[list, default: []].append(exposed) }
            }
        }
        return frames
    }

    func clipsDescendants(_ node: AXNode) -> Bool {
        table[node.index] == node.index || row[node.index] == node.index
            || ["scroll_view", "web_view", "window", "tab_bar"].contains(node.role)
    }
}
