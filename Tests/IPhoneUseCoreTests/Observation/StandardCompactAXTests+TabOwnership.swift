import XCTest
@testable import IPhoneUseCore

extension StandardCompactAXTests {
    func testNativeBarOwnsVisibleButtonsAcrossLayoutWrappers() {
        let bar = AXNode(index: 0, parent: nil, role: "unknown", attributes: [
            "nativeAttributes": ["5003": "CustomBar", "5004": "UITabBar"], "label": "Tab Bar",
            "frame": ["x": 0, "y": 175, "width": 100, "height": 25]
        ])
        let source = capture([
            bar,
            control(1, 0, "unknown", "", traits: 0x200000000),
            control(2, 1, "group", "", traits: 0, visible: nil),
            control(3, 2, "unknown", "Inbox", traits: 0x210000009),
            control(4, 2, "button", "", traits: 0x200000001),
            control(5, 4, "text", "Library", traits: 0x40, visible: nil),
            control(6, 2, "button", "Unconfirmed", traits: 1, visible: nil),
            control(7, 2, "button", "Hidden", traits: 1, visible: false)
        ])
        XCTAssertEqual(Array(StandardCompactAX.lines(source, id: "o1").dropFirst()), [
            "[e1?] tab_bar \"Tab Bar\" @0,175,100,25",
            "  [e4] tab \"Inbox\" selected=true @0,175,100,25",
            "  [e5] tab @0,175,100,25",
            "    [e6?] text \"Library\" @0,175,100,25"
        ])
        XCTAssertEqual(source.nodes[3].role, "unknown")
        XCTAssertEqual(source.nodes[3].parent, 2)
    }

    func testBarTraitOnPublishButtonDoesNotCreateBarOrTab() {
        let source = capture([
            node(0, nil, ("unknown", "UITabBar"), "", (175, 25)),
            control(1, 0, "group", "", traits: 0x200000000, visible: nil),
            control(2, 1, "button", "Home", traits: 9),
            control(3, 1, "button", "Publish", traits: 0x200008000),
            control(4, 3, "button", "Attachment", traits: 1),
            control(5, 1, "button", "Release Tag", traits: 0x200008000, visible: nil)
        ])
        XCTAssertEqual(Array(StandardCompactAX.lines(source, id: "o1").dropFirst()), [
            "[e1?] tab_bar @0,175,100,25",
            "  [e3] tab \"Home\" selected=true @0,175,100,25",
            "  [e4] button \"Publish\" @0,175,100,25",
            "    [e5] button \"Attachment\" @0,175,100,25"
        ])
    }

    func testNativeToolbarAndMeaningfulWrappersStopTabOwnership() {
        let source = capture([
            node(0, nil, ("unknown", "UITabBar"), "", (175, 25)),
            control(1, 0, "button", "Inbox", traits: 1),
            node(2, 0, ("unknown", "UIToolbar"), "", (175, 25)),
            control(3, 2, "group", "", traits: 0, visible: nil),
            control(4, 3, "button", "Compose", traits: 9),
            control(5, 0, "group", "Actions", traits: 0),
            control(6, 5, "button", "Rename", traits: 9),
            control(7, 0, "unknown", "", traits: 0x2, visible: nil),
            control(8, 7, "button", "Follow", traits: 9),
            control(9, 0, "group", "", traits: 0, visible: false),
            control(10, 9, "unknown", "Concealed", traits: 9)
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertEqual(lines.filter { $0.contains("] tab ") }.count, 1)
        for label in ["Compose", "Rename", "Follow"] {
            XCTAssertTrue(lines.contains { $0.contains("button " + quoted(label)) })
        }
        XCTAssertFalse(lines.joined().contains("Concealed"))
    }
}
