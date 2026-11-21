import Foundation

/// Capture-local list ownership and edge bars. A control in another window is not
/// evidence that a background list is exposed.
struct AXListContext {
    var table: [Int?] = []
    var row: [Int?] = []
    var bounds: [AXListViewport] = []
    var hidden: [Bool] = []
    var unlocatedRow = [Bool]()
    var controlOwner = [Int?]()
    var activeTables = Set<Int>()
    private var nav: [Int?] = []
    private var activeBars = Set<Int>()
    private var systemBars = Set<Int>()
    private var headers = Set<Int>()
    private var buttons = Set<Int>()

    init(_ nodes: [AXNode], selected: Set<Int>, screen: CGRect) {

        // Custom chrome may sit beside UIKit’s navigation content rather than inside UINavigationBar.
        let navigationHosts = Set(nodes.compactMap { $0.hasNativeType("UINavigationTransitionView") ? $0.parent : nil })
        for node in nodes {
            record(node, navigationHosts: navigationHosts, selected: selected, screen: screen)
        }
        activeBars = activeBars.intersection(systemBars).union(headers.intersection(buttons))
        let edges = scopedEdges(nodes, selected: selected, screen: screen)
        let confirmed = edges.isEmpty ? [:] : confirmedRowFrames(nodes, selected: selected, screen: screen)
        var inheritedEdges: [[Edge]] = []
        for node in nodes {
            let parent = node.parent
            let outer = node.role == "window" ? [] : (parent.map { inheritedEdges[$0] } ?? [])
            let local = outer.filter { $0.bar != node.index } + (edges[node.index] ?? [])
            inheritedEdges.append(local)
            var clip = parent.map { bounds[$0] } ?? AXListViewport(screen)
            let frame = PresentedAX.rect(node.attributes["frame"])
            let isRow = row[node.index] == node.index
            unlocatedRow.append((isRow && frame == nil) || (parent.map { unlocatedRow[$0] } ?? false))
            controlOwner.append(node.isControlForListFields ? node.index : parent.flatMap { controlOwner[$0] })
            let isList = table[node.index] == node.index
            if let frame, clipsDescendants(node) {
                clip = clip.intersection(frame)
                if isList {
                    for edge in local {
                        clip = clip.excluding(edge.frame, contentBelow: edge.contentBelow,
                                              confirmed: confirmed[node.index] ?? [])
                    }
                }
            }
            bounds.append(clip)
        }
    }

    private mutating func record(_ node: AXNode, navigationHosts: Set<Int>, selected: Set<Int>, screen: CGRect) {
        let parent = node.parent
        let systemBar = node.role == "navigation_bar" || node.hasNativeType("UINavigationBar")
        if systemBar { systemBars.insert(node.index) }
        let frame = PresentedAX.rect(node.attributes["frame"])
        let chrome = node.role == "group" && parent.map(navigationHosts.contains) == true && frame.map {
            !$0.isEmpty && $0.minY >= screen.minY && $0.maxY < screen.midY
                && $0.minX <= screen.minX && $0.maxX >= screen.maxX
        } == true
        nav.append(systemBar || chrome ? node.index : parent.flatMap { nav[$0] })
        let isTable = ["table", "collection_view"].contains(node.role)
        let list = isTable ? node.index : parent.flatMap { table[$0] }
        table.append(list)
        let isRow = list != nil && (node.role == "cell" || node.hasNativeType("UITableViewCellAccessibilityElement")
            || node.hasNativeType("UICollectionViewListCell"))
        let owner = isTable ? nil : (isRow ? node.index : parent.flatMap { row[$0] })
        row.append(owner)
        let concealed = node.attributes["visible"] as? Bool == false || (parent.map { hidden[$0] } ?? false)
        hidden.append(concealed)
        guard !concealed else { return }
        if let bar = nav[node.index], !node.label.isEmpty, AXPresentationTraits(node).contains(.header) {
            headers.insert(bar)
        }
        if selected.contains(node.index), node.attributes["visible"] as? Bool == true {
            if let list { activeTables.insert(list) }
            if let bar = nav[node.index] {
                activeBars.insert(bar)
                if node.role == "button" || AXPresentationTraits(node).contains(.button) { buttons.insert(bar) }
            }
        }
    }

    private struct Edge {
        let bar: Int
        let frame: CGRect
        let contentBelow: Bool
    }

    private func scopedEdges(_ nodes: [AXNode], selected: Set<Int>, screen: CGRect) -> [Int: [Edge]] {
        var edges: [Int: [Edge]] = [:]
        // Only use an edge bar supported by a currently selected control inside it.
        var confirmed = Set<Int>()
        for index in selected where nodes[index].attributes["visible"] as? Bool == true {
            var ancestor = nodes[index].parent
            while let current = ancestor, confirmed.insert(current).inserted { ancestor = nodes[current].parent }
        }
        for index in confirmed.sorted() {
            let node = nodes[index]
            guard let parent = node.parent, !hidden[index], let bar = PresentedAX.rect(node.attributes["frame"]),
                  bar.minX <= screen.minX, bar.maxX >= screen.maxX, !bar.isEmpty else { continue }
            var host = parent
            let contentBelow: Bool
            if activeBars.contains(index) && bar.maxY < screen.midY {
                contentBelow = true
            } else if node.role == "tab_bar" || node.hasNativeType("UITabBar"),
                      bar.maxY >= screen.maxY, bar.minY > screen.midY {
                contentBelow = false
                if node.hasNativeType("UITabBar") {
                    host = Self.tabHost(nodes, parent: parent)
                }
            } else { continue }
            edges[host, default: []].append(Edge(bar: index, frame: bar, contentBelow: contentBelow))
        }
        return edges
    }

    // UIKit may place the bar in its own subtree beside the content it overlays.
    private static func tabHost(_ nodes: [AXNode], parent: Int) -> Int {
        var candidate: Int? = parent
        while let index = candidate {
            let node = nodes[index]
            if node.hasNativeType("_UITabContainerView"), let host = node.parent { return host }
            if node.role == "window" || node.hasNativeType("UILayoutContainerView") { break }
            candidate = node.parent
        }
        return parent
    }

    func isNavigationTitle(_ node: AXNode) -> Bool {
        guard let bar = nav[node.index], activeBars.contains(bar), !node.label.isEmpty else { return false }
        return AXPresentationTraits(node).contains(.header) || (systemBars.contains(bar) && node.role == "text")
    }
}
