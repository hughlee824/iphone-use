import XCTest
@testable import IPhoneUseCore

final class StandardCompactAXTests: XCTestCase {
    func node(
        _ index: Int, _ parent: Int?, _ kind: (String, String),
        _ label: String, _ span: (Int, Int), visible: Bool? = nil, identifier: String = ""
    ) -> AXNode {
        var fields: [String: Any] = [
            "label": label, "identifier": identifier, "nativeAttributes": ["5003": kind.1],
            "frame": ["x": 0, "y": span.0, "width": 100, "height": span.1]
        ]
        fields["visible"] = visible
        return AXNode(index: index, parent: parent, role: kind.0, attributes: fields)
    }

    func capture(_ nodes: [AXNode]) -> CapturedObservation {
        CapturedObservation(nodes: nodes, metadata: [
            "backend": "apple-native", "axStatus": "available", "axApplicationBundleId": "fixture.app",
            "screenFrame": ["x": 0, "y": 0, "width": 100, "height": 200],
            "axCollection": ["strategy": "full_tree_candidate_visibility_keyboard_batch_v1"]
        ], screenshot: Data())
    }

    func control(
        _ index: Int, _ parent: Int?, _ role: String, _ label: String, traits: UInt64, visible: Bool? = true
    ) -> AXNode {
        let base = node(index, parent, (role, "Fixture"), label, (175, 25), visible: visible)
        var fields = base.attributes
        fields["nativeAttributes"] = ["2004": traits]
        return AXNode(index: index, parent: parent, role: role, attributes: fields)
    }

    func testTabBarUsesContainerAndDirectButtonTraits() {
        let source = capture([
            control(0, nil, "group", "", traits: 0x200008000, visible: nil),
            control(1, 0, "unknown", "Home", traits: 0x210000009),
            control(2, 0, "unknown", "Library", traits: 0x210000001),
            control(3, 0, "text", "Status", traits: 0x8),
            control(4, 0, "group", "Actions", traits: 0),
            control(5, 4, "button", "Edit", traits: 0x9),
            control(6, nil, "group", "Hidden", traits: 0x8000, visible: false),
            control(7, 6, "button", "Hidden child", traits: 0x1)
        ])
        XCTAssertEqual(Array(StandardCompactAX.lines(source, id: "o1").dropFirst(2)), [
            "  [e1?] tab_bar @0,175,100,25",
            "    [e2] tab \"Home\" selected=true @0,175,100,25",
            "    [e3] tab \"Library\" @0,175,100,25",
            "    [e4] text \"Status\" @0,175,100,25",
            "    [e5] group \"Actions\" @0,175,100,25",
            "      [e6] button \"Edit\" @0,175,100,25"
        ])
    }

    func testToolbarButtonsWithSameTraitsAndGeometryRemainButtons() {
        let source = capture([
            control(0, nil, "toolbar", "Actions", traits: 0x200000000),
            control(1, 0, "button", "Home", traits: 0x210000009),
            control(2, 0, "button", "Library", traits: 0x210000001)
        ])
        XCTAssertEqual(Array(StandardCompactAX.lines(source, id: "o1").dropFirst(2)), [
            "  [e1] toolbar \"Actions\" @0,175,100,25",
            "    [e2] button \"Home\" @0,175,100,25",
            "    [e3] button \"Library\" @0,175,100,25"
        ])
    }

    func testRowOwnershipDeduplicationStatesAndClipping() {
        let source = capture([
            node(0, nil, ("window", "UIWindow"), "", (0, 200)),
            node(1, 0, ("table", "UITableView"), "", (0, 200)),
            node(2, 1, ("text", "UILabel"), "Search", (0, 20), visible: true),
            node(3, 1, ("unknown", "UITableViewCellAccessibilityElement"),
                 "Name,未読,Part 1, part 2,通知をミュート", (20, 60)),
            node(4, 3, ("image", "UIImageView"), "Avatar", (23, 15)),
            node(5, 3, ("text", "UILabel"), "Name", (23, 20)),
            node(6, 3, ("text", "UILabel"), "Name", (23, 20)),
            node(7, 3, ("text", "UILabel"), "Part 1, part 2", (50, 20)),
            node(8, 3, ("image", "UIImageView"), "", (25, 10)),
            node(9, 3, ("image", "UIImageView"), "", (50, 10), identifier: "decoration"),
            node(10, 1, ("unknown", "UITableViewCellAccessibilityElement"), "Name,Secret", (158, 60)),
            node(11, 10, ("text", "UILabel"), "Name", (160, 20)),
            node(12, 10, ("text", "UILabel"), "Secret", (188, 20)),
            node(13, 1, ("unknown", "UITableViewCellAccessibilityElement"), "Offscreen", (218, 60)),
            node(14, 13, ("text", "UILabel"), "Recycled frame", (25, 20)),
            node(15, 0, ("group", "UITabBar"), "", (175, 25)),
            node(16, 15, ("button", "UIButton"), "Tab", (175, 25), visible: true),
            node(17, 3, ("text", "UILabel"), "Hidden", (25, 20), visible: false)
        ])
        let lines = StandardCompactAX.lines(source, id: "o2")
        XCTAssertEqual(lines.first, "obs=o2 [eN?]=AX visibility unknown")
        XCTAssertTrue(lines.contains("    [e4?] row \"未読,通知をミュート\" @0,20,100,60"))
        XCTAssertTrue(lines.contains("      [e5?] image \"Avatar\" @0,23,100,15"))
        XCTAssertTrue(lines.contains("    [e11?] row @0,158,100,60 clip=0,158,100,17"))
        XCTAssertTrue(lines.contains("      [e12?] text \"Name\" @0,160,100,20 clip=0,160,100,15"))
        XCTAssertEqual(lines.filter { $0.contains("\"Name\"") }.count, 2)
        for missing in ["[e7?]", "Secret", "Recycled frame", "Hidden", "Offscreen"] {
            XCTAssertFalse(lines.contains { $0.contains(missing) })
        }
    }

    func testRowLabelOnlySubtractsUnambiguousWholeChildText() {
        let remaining = AXListLayout.remainingLabel
        XCTAssertEqual(remaining("Luc,Non lu,Bonjour, Marie,Silencieux", ["Luc", "Bonjour, Marie"]),
                       "Non lu,Silencieux")
        XCTAssertEqual(remaining("阿青,免打扰,收到了，谢谢,昨天", ["阿青", "收到了，谢谢", "昨天"]), "免打扰")
        XCTAssertEqual(remaining("News,Newsletter", ["News"]), "Newsletter")
        XCTAssertEqual(remaining("Read,Read,Text", ["Read", "Text"]), "Read,Read,Text")
        XCTAssertEqual(remaining("A,B,C", ["A,B", "B,C"]), "A,B,C")
        XCTAssertEqual(remaining("A • B • Épinglé", ["A", "B"]), "A • B • Épinglé")
    }

    func testClippedCandidateRowDoesNotExposeAggregateValueOrUnlocatedChildren() {
        let cell = node(1, 0, ("cell", "UITableViewCell"), "Visible,Private", (175, 60), visible: true)
        var attributes = cell.attributes
        attributes["value"] = "Private status"
        let source = capture([
            node(0, nil, ("table", "UITableView"), "", (0, 200), visible: true),
            AXNode(index: 1, parent: 0, role: cell.role, attributes: attributes),
            AXNode(index: 2, parent: 1, role: "text", attributes: ["label": "Unlocated", "visible": true])
        ])
        XCTAssertEqual(Array(StandardCompactAX.lines(source, id: "o1").suffix(1)),
                       ["    [e2] row @0,175,100,60 clip=0,175,100,25"])
    }

    func testCustomTopBarRequiresHeaderAndVisibleControlOutsideNavigationContent() {
        let title = node(2, 1, ("group", "Custom"), "Title", (10, 15))
        var fields = title.attributes
        fields["nativeAttributes"] = ["2004": 0x10000]
        let nodes = [
            node(0, nil, ("window", "UIWindow"), "", (0, 200)),
            node(1, 0, ("group", "Custom"), "", (8, 22)),
            AXNode(index: 2, parent: 1, role: title.role, attributes: fields),
            node(3, 1, ("button", "UIButton"), "Menu", (10, 15), visible: true),
            node(4, 0, ("unknown", "UINavigationTransitionView"), "", (0, 200)),
            node(5, 4, ("table", "UITableView"), "", (0, 200), visible: true)
        ]
        let lines = StandardCompactAX.lines(capture(nodes), id: "o1")
        XCTAssertTrue(lines.contains("  [e3?] group \"Title\" @0,10,100,15"))
        XCTAssertTrue(lines.contains("  [e6] table @0,0,100,200 clip=0,30,100,170"))
        var noHeader = nodes
        noHeader[2] = title
        XCTAssertTrue(StandardCompactAX.lines(capture(noHeader), id: "o1").contains("  [e6] table @0,0,100,200"))
        var noControl = nodes
        noControl[3] = node(3, 1, ("button", "UIButton"), "Menu", (10, 15), visible: false)
        XCTAssertTrue(StandardCompactAX.lines(capture(noControl), id: "o1").contains("  [e6] table @0,0,100,200"))
    }

    func testRowWithIdenticalTitleKeepsOneReadableChild() {
        let source = capture([
            node(0, nil, ("table", "UITableView"), "", (0, 200)),
            node(1, 0, ("cell", "UITableViewCell"), "One title", (20, 60), visible: true),
            node(2, 1, ("text", "UILabel"), "One title", (24, 30))
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertTrue(lines.contains("    [e2] row @0,20,100,60"))
        XCTAssertTrue(lines.contains("      [e3?] text \"One title\" @0,24,100,30"))
        XCTAssertEqual(lines.filter { $0.contains("One title") }.count, 1)
    }

    func testSelectedAlertInAnotherWindowDoesNotExposeBackgroundList() {
        let source = capture([
            node(0, nil, ("window", "UIWindow"), "", (0, 200)),
            node(1, 0, ("table", "UITableView"), "", (0, 200)),
            node(2, 1, ("cell", "UITableViewCell"), "", (10, 80)),
            node(3, 2, ("text", "UILabel"), "Background", (30, 20)),
            node(4, nil, ("window", "UIWindow"), "", (0, 200)),
            node(5, 4, ("button", "UIButton"), "Allow", (80, 35), visible: true)
        ])
        XCTAssertEqual(StandardCompactAX.lines(source, id: "o1").dropFirst(2), ["  [e6] button \"Allow\" @0,80,100,35"])
    }

    func testScreenshotOnlyHeaderIncludesKnownFailureAndUnstableState() {
        var metadata = capture([]).metadata
        metadata.removeValue(forKey: "axApplicationBundleId")
        metadata["foregroundBundleId"] = "unrelated.foreground"
        metadata["axStatus"] = "unavailable"
        metadata["axError"] = "root changed"
        metadata["postActionStability"] = ["stable": false]
        let source = CapturedObservation(nodes: [], metadata: metadata, screenshot: Data())
        XCTAssertEqual(StandardCompactAX.lines(source, id: "o3"), [
            "obs=o3 ax=unavailable reason=\"root changed\" stable=false"
        ])
    }

    func testAppRootUsesAXSourceAndCapturedScreenOriginWhenKnown() {
        let nodes = [node(0, nil, ("button", ""), "Continue", (20, 20), visible: true)]
        var metadata = capture(nodes).metadata
        metadata["foregroundBundleId"] = "other.app"
        metadata["screenFrame"] = ["x": 0, "y": 10, "width": 200, "height": 100]
        func lines() -> [String] {
            StandardCompactAX.lines(CapturedObservation(nodes: nodes, metadata: metadata, screenshot: Data()), id: "o4")
        }
        XCTAssertEqual(lines(), ["obs=o4", "[app] fixture.app @0,10,200,100",
                                 "  [e1] button \"Continue\" @0,20,100,20"])
        metadata.removeValue(forKey: "axApplicationBundleId")
        XCTAssertEqual(lines()[1], "[app] @0,10,200,100")
        metadata.removeValue(forKey: "screenFrame")
        XCTAssertEqual(lines()[1], "[app]")
    }

    func testHeaderIgnoresFilteredUnknownNodesAndMarkerLikeTextInLabels() {
        let source = capture([
            node(0, nil, ("table", ""), "", (0, 200), visible: true),
            node(1, 0, ("cell", ""), "Outside", (210, 20)),
            node(2, nil, ("text", ""), "Literal [e123?]", (20, 20), visible: true)
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertEqual(lines, [
            "obs=o1",
            "[app] fixture.app @0,0,100,200",
            "  [e1] table @0,0,100,200",
            "  [e3] text \"Literal [e123?]\" @0,20,100,20"
        ])
    }

    func testStandaloneArchiveHasLegendAndSameBodyAsLiveObservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = capture([node(0, nil, ("text", "UILabel"), "Sample", (10, 20), visible: true)])
        let result = try ObservationCache(directory: directory).store(source)
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertFalse(text.contains(StandardCompactAX.legend))
        XCTAssertTrue(text.contains("\nscreenshot="))
        let export = EvidenceArchive.render(["ok": true, "result": result], directory: directory)
        let path = try XCTUnwrap((export["artifacts"] as? [String: String])?["compactAX"])
        let document = try String(contentsOfFile: path, encoding: .utf8)
        let live = StandardCompactAX.lines(source, id: "o1")
        XCTAssertEqual(document.components(separatedBy: "\n"),
                       [try XCTUnwrap(live.first), StandardCompactAX.legend] + live.dropFirst() + [""])
        XCTAssertEqual(StandardCompactAX.legend, "@x,y,w,h = absolute screen points from top-left; "
            + "clip = bounds after geometric clipping (| separates regions)")
    }
}
