import Foundation
import IPhoneUseRunnerSupport

// A responder token is meaningful only within the same AX reader lease and foreground application.
struct NativeTextResponder: Equatable {
    let lease: String
    let bundle: String
    let pid: Int
    let objectID: String
    let role: String
    let identifier: String
    let field: ScreenRect

    init?(_ capture: CapturedObservation, selecting selected: AXNode? = nil) {
        let metadata = capture.metadata
        guard metadata["axStatus"] as? String == "available", metadata["sourceTruncated"] as? Bool != true,
            let cleanup = metadata["axCleanup"] as? [String: Any],
            let connection = cleanup["connectionLease"] as? [String: Any],
            let lease = connection["generation"] as? String, UUID(uuidString: lease) != nil,
            let bundle = metadata["axApplicationBundleId"] as? String, !bundle.isEmpty else { return nil }
        let matches: [AXNode]
        if let selected, selected.attributes["attributeSource"] as? String == "axp-native-snapshot",
            let token = selected.attributes["nativeElement"] as? [String: Any],
            let pid = token["pid"] as? Int, let identity = token["objectID"] as? String {
            matches = capture.nodes.filter {
                let element = $0.attributes["nativeElement"] as? [String: Any]
                return element?["pid"] as? Int == pid && element?["objectID"] as? String == identity
            }
        } else if selected == nil {
            matches = capture.nodes.filter { $0.attributes["keyboardFocus"] as? Bool == true }
        } else { return nil }
        guard matches.count == 1, let node = matches.first,
            ["text_field", "search_field", "text_view"].contains(node.role),
            node.attributes["externalProcessReference"] as? Bool != true, node.enabled != false,
            node.attributes["visible"] as? Bool != false,
            let element = node.attributes["nativeElement"] as? [String: Any],
            let pid = element["pid"] as? Int, pid > 0, let objectID = element["objectID"] as? String,
            let number = UInt64(objectID), number > 0, let field = Self.rect(node) else { return nil }
        self.lease = lease; self.bundle = bundle; self.pid = pid
        self.objectID = objectID; role = node.role; identifier = node.identifier; self.field = ScreenRect(field)
    }

    func sameEditor(as other: Self?) -> Bool {
        guard let other else { return false }
        return lease == other.lease && bundle == other.bundle && pid == other.pid
            && objectID == other.objectID && role == other.role && identifier == other.identifier
    }

    func visibleField(on screen: ScreenRect) -> ScreenRect? {
        guard field.valid, screen.valid else { return nil }
        let clipped = ScreenRect(field.cgRect.intersection(screen.cgRect))
        return clipped.valid ? clipped : nil
    }

    func hasVisibleFocus(in capture: CapturedObservation, on screen: ScreenRect) -> Bool {
        guard let current = NativeTextResponder(capture), current.visibleField(on: screen) != nil else { return false }
        return sameEditor(as: current)
    }

    static func rect(_ node: AXNode) -> CGRect? {
        (node.attributes["frame"] as? [String: Any]).flatMap(AXPSnapshot.rect)
    }
}
