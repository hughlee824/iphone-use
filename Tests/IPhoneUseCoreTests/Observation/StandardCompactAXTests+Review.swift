import XCTest
@testable import IPhoneUseCore

extension StandardCompactAXTests {
    func testPaneNavigationBarDoesNotCropSiblingListInSameWindow() {
        let source = capture([
            node(0, nil, ("window", "UIWindow"), "", (0, 200)),
            node(1, 0, ("table", ""), "", (0, 60), visible: true),
            node(2, 1, ("cell", ""), "", (10, 30)),
            node(3, 2, ("text", ""), "Upper title", (14, 16), visible: true),
            node(4, 0, ("group", ""), "Lower pane", (60, 140)),
            node(5, 4, ("unknown", "UINavigationBar"), "", (60, 30)),
            node(6, 5, ("button", ""), "Tools", (65, 20), visible: true),
            node(7, 4, ("table", ""), "", (60, 140), visible: true),
            node(8, 4, ("table", ""), "", (50, 30), visible: true)
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertTrue(lines.contains { $0.contains("[e4] text \"Upper title\"") })
        XCTAssertTrue(lines.contains { $0.contains("[e8] table @0,60,100,140 clip=0,90,100,110") })
        XCTAssertTrue(lines.contains { $0.contains("[e9] table @0,50,100,30 clip=0,50,100,10") })
    }

    func testUnlocatedRowKeepsLocatedConfirmedChildOnly() {
        let source = capture([
            node(0, nil, ("table", ""), "", (0, 200), visible: true),
            AXNode(index: 1, parent: 0, role: "cell", attributes: ["label": "Whole row summary"]),
            node(2, 1, ("text", ""), "Verified title", (30, 20), visible: true),
            node(3, 1, ("text", ""), "Unverified title", (55, 20)),
            node(4, 1, ("text", ""), "Outside", (205, 20), visible: true)
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertTrue(lines.contains("      [e3] text \"Verified title\" @0,30,100,20"))
        XCTAssertTrue(lines.contains("    [e2?] row"))
        for absent in ["Unverified", "Whole row", "Outside"] { XCTAssertFalse(lines.contains { $0.contains(absent) }) }
    }

    func testClippedCompositeKeepsLocatedTextWithoutExposingAggregate() {
        let source = capture([
            node(0, nil, ("table", ""), "", (0, 200), visible: true),
            node(1, 0, ("cell", ""), "Name,Private", (180, 60), visible: true),
            AXNode(index: 2, parent: 1, role: "button", attributes: ["label": "Name,Private", "value": "Private",
                "visible": true, "frame": ["x": 0, "y": 180, "width": 100, "height": 60]]),
            node(3, 2, ("text", ""), "Name", (183, 15)),
            node(4, 2, ("text", ""), "Private", (213, 15))
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertFalse(lines.contains { $0.contains("Private") })
        XCTAssertTrue(lines.contains { $0.contains("[e4?] text \"Name\"") })
    }

    func testRepeatedFieldsKeepControlOwnershipAndDistinctExposedAreas() {
        let source = capture([
            node(0, nil, ("table", ""), "", (0, 200), visible: true),
            node(1, 0, ("cell", ""), "", (20, 70)),
            node(2, 1, ("button", ""), "", (20, 20), visible: true),
            node(3, 2, ("text", ""), "Read", (20, 60)),
            node(4, 1, ("button", ""), "", (60, 20), visible: true),
            node(5, 4, ("text", ""), "Read", (20, 60)),
            node(6, 1, ("group", ""), "", (20, 20)),
            node(7, 6, ("image", ""), "Indicator", (20, 60)),
            node(8, 1, ("group", ""), "", (60, 20)),
            node(9, 8, ("image", ""), "Indicator", (20, 60)),
            node(10, 1, ("button", ""), "", (20, 20), visible: true),
            node(11, 10, ("text", ""), "Read", (20, 60))
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertEqual(lines.filter { $0.contains("text \"Read\"") }.count, 3)
        XCTAssertEqual(lines.filter { $0.contains("image \"Indicator\"") }.count, 2)
        XCTAssertTrue(lines.contains { $0.contains("[e6?]") && $0.hasSuffix("clip=0,60,100,20") })
    }

    func testHiddenUnlocatedDecorationKeepsVisibleButtonNameInPartialRow() {
        let source = capture([
            node(0, nil, ("table", ""), "", (0, 200), visible: true),
            node(1, 0, ("cell", ""), "", (150, 100), visible: true),
            node(2, 1, ("button", "UIButton"), "Rename", (160, 30), visible: true),
            AXNode(index: 3, parent: 2, role: "image", attributes: ["visible": false])
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertTrue(lines.contains("      [e3] button \"Rename\" @0,160,100,30"))
        XCTAssertFalse(lines.contains { $0.contains("[e4") })
    }

    func testInteriorNavigationBarPreservesConfirmedRowsOnBothSides() {
        let source = capture([
            node(0, nil, ("window", "UIWindow"), "", (0, 200)),
            node(1, 0, ("table", ""), "", (20, 160), visible: true),
            node(2, 1, ("cell", ""), "", (24, 26), visible: true),
            node(3, 2, ("text", ""), "Upper", (26, 18), visible: true),
            node(4, 1, ("cell", ""), "", (110, 26), visible: true),
            node(5, 4, ("text", ""), "Lower", (112, 18), visible: true),
            node(6, 1, ("cell", ""), "Covered", (70, 20), visible: true),
            node(7, 6, ("text", ""), "Covered", (72, 14), visible: true),
            node(8, 0, ("unknown", "UINavigationBar"), "", (70, 20)),
            node(9, 8, ("button", ""), "Tools", (70, 16), visible: true)
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertTrue(lines.contains("  [e2] table @0,20,100,160 clip=0,20,100,50|0,90,100,90"))
        XCTAssertTrue(lines.contains("      [e4] text \"Upper\" @0,26,100,18"))
        XCTAssertTrue(lines.contains("      [e6] text \"Lower\" @0,112,100,18"))
        XCTAssertFalse(lines.contains { $0.contains("Covered") })
    }

    func testHintOnWrapperStopsTabOwnership() {
        let wrapper = control(2, 0, "unknown", "", traits: 0x200000000)
        let source = capture([
            node(0, nil, ("unknown", "UITabBar"), "", (175, 25)),
            control(1, 0, "button", "Home", traits: 9),
            AXNode(index: 2, parent: 0, role: wrapper.role,
                   attributes: wrapper.attributes.merging(["hint": "Open editing actions"]) { _, new in new }),
            control(3, 2, "button", "Delete", traits: 1)
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertTrue(lines.contains { $0.contains("tab \"Home\" selected=true") })
        XCTAssertTrue(lines.contains { $0.contains("button \"Delete\"") })
    }
}
