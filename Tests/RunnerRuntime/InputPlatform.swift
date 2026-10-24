// Test-only platform objects. Compile alongside the unchanged Runner input source;
// none of these objects, event callbacks or fake AX identities ship in the Runner.
import Foundation
import CoreGraphics
import IPhoneUseRunnerSupport

struct XCUIKeyboardKey: RawRepresentable {
    let rawValue: String
    static let `return` = Self(rawValue: "return"), delete = Self(rawValue: "delete")
    static let leftArrow = Self(rawValue: "left"), rightArrow = Self(rawValue: "right")
    static let upArrow = Self(rawValue: "up"), downArrow = Self(rawValue: "down")
    static let tab = Self(rawValue: "tab")
}
struct TestModifiers: OptionSet {
    let rawValue: Int
    static let shift = Self(rawValue: 1), command = Self(rawValue: 2)
}
enum TestInputEvent: Equatable {
    case tap, doubleTap, longPress
    case text(String)
    case key(String, TestModifiers)
}
struct XCUIGestureVelocity: RawRepresentable { let rawValue: CGFloat }
final class XCUIElementSnapshot {
    let element: XCUIElement
    let children: [XCUIElementSnapshot]
    let value: Any?
    let frame: CGRect
    let elementType: XCUIElement.ElementType
    init(_ element: XCUIElement) {
        self.element = element
        children = element.children.map(Self.init)
        value = element.value; frame = element.frame; elementType = element.elementType
    }
}
class XCUIElement {
    enum ElementType: UInt { case any, textView, textField, secureTextField, searchField }
    let identity = NSUUID()
    var children: [XCUIElement] = []
    var value: Any? = "old"
    var focused = false
    var removed = false
    private(set) var inputEvents: [TestInputEvent] = []
    var onEvent: (String) -> Void = { _ in }
    var elementType: ElementType { checkAlive(); return .textView }
    var isEnabled: Bool { checkAlive(); return true }
    var isHittable: Bool { checkAlive(); return true }
    var frame: CGRect { checkAlive(); return CGRect(x: 0, y: 0, width: 390, height: 844) }
    func checkAlive() { precondition(!removed, "Runner queried an element after navigation removed it") }
    func descendants(matching: ElementType) -> XCUIElement { self }
    func tap() { inputEvents.append(.tap); onEvent("tap") }
    func doubleTap() { inputEvents.append(.doubleTap); onEvent("double-tap") }
    func press(forDuration: Double) { inputEvents.append(.longPress); onEvent("long-press") }
    func typeText(_ text: String) { inputEvents.append(.text(text)); onEvent(text) }
    func typeKey(_ key: String, modifierFlags: TestModifiers) {
        inputEvents.append(.key(key, modifierFlags)); onEvent(key)
    }
    func coordinate(withNormalizedOffset: CGVector) -> TestCoordinate { TestCoordinate() }
}
struct TestCoordinate {
    let screenPoint = CGPoint(x: 100, y: 100)
    func press(forDuration: Double, thenDragTo: Self, withVelocity: XCUIGestureVelocity,
               thenHoldForDuration: Double) { preconditionFailure("Unexpected gesture") }
}
final class TestAlerts {
    var count: Int { 0 }
    var firstMatch: XCUIElement { preconditionFailure("Unexpected alert") }
}
final class XCUIApplication: XCUIElement {
    enum State { case runningForeground }
    let alerts = TestAlerts()
    var state: State { .runningForeground }
    init(bundleIdentifier: String) {}
}
final class XCUIDevice {
    enum Button { case home }
    static let shared = XCUIDevice()
    func press(_ button: Button) { preconditionFailure("Unexpected Home") }
}
struct CommandError: Error {
    let code: String
    init(_ code: String, requiresObservation: Bool = false, message: String? = nil) { self.code = code }
}
enum RunnerAXBinding {
    static func keyboardFocus(of element: XCUIElement) throws -> NSNumber {
        element.checkAlive(); return NSNumber(value: element.focused)
    }
    static func identity(of snapshot: XCUIElementSnapshot) throws -> NSObject { snapshot.element.identity }
    static func bind(snapshot: XCUIElementSnapshot, query: XCUIElement) throws -> Any { snapshot.element }
}
@MainActor
final class LiveSessionTests {
    var inputSessionUncertain = false
    var currentApp: XCUIApplication?
    var currentBundleID: String? = "fixture"
    var observedReferences = RunnerAXReferences<NSObject>()
    var commandReferences = RunnerAXReferences<NSObject>()
    var inputAction: RunnerInputAction?
    var postInputContext: ScreenContext?
    var postInputTextFields: [ScreenRect] = []
    var executionStarted = false
    var events = 0
    var failEvent = false
    var failSnapshotAfterEvent = false
    func freshSnapshot(_ element: XCUIElement) throws -> XCUIElementSnapshot {
        if failSnapshotAfterEvent && events > 0 { throw CommandError("snapshot_unavailable") }
        return XCUIElementSnapshot(element)
    }
    func event(_ body: () -> Void) throws {
        executionStarted = true; events += 1
        body()
        if failEvent { throw CommandError("xctest_error") }
    }
    func screenContext(app: XCUIApplication, root: XCUIElement) -> ScreenContext {
        // Input tests never use pixels or geometry to decide target identity.
        ScreenContext(screen: ScreenRect(app.frame), scope: ScreenRect(root.frame),
                      orientation: 1, keyboardCount: 1)
    }
    func performGesture(_ command: [String: Any], kind: String, app: XCUIApplication,
                        root: XCUIElement) throws -> [String: Any] { preconditionFailure("Unexpected gesture") }
}
