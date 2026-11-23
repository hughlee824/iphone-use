import Foundation
import CoreGraphics

// Decode AXP facts without adopting XCTest type codes or action identities.
struct AXPSnapshot {
    let nodes: [AXNode]
    let bundle: String
    let screen: CGRect
    let displayID: UInt64
    let displayUniqueID: String?
    let started: Double
    let finished: Double
    let cleanup: [String: Any]
    let collection: [String: Any]

    private struct Entry {
        let record: [String: Any]
        let parent: Int?
        let depth: Int
    }

    static func decode(_ payload: [String: Any], device: String) throws -> AXPSnapshot {
        guard payload["version"] as? Int == 1, payload["deviceID"] as? String == device,
            let cleanup = connectionEvidence(payload),
            payload["rootStable"] as? Bool == true, payload["selectionStable"] as? Bool == true,
            let started = payload["startedAt"] as? Double, started.isFinite,
            let finished = payload["finishedAt"] as? Double, finished.isFinite, finished >= started,
            let display = payload["display"] as? [String: Any], let screen = rect(display),
            let displayID = display["displayID"] as? NSNumber,
            CFGetTypeID(displayID) != CFBooleanGetTypeID(),
            let numericDisplayID = UInt64(displayID.stringValue), numericDisplayID > 0,
            let root = payload["tree"] as? [String: Any],
            let rootElement = root["element"] as? [String: Any],
            let pid = rootElement["pid"] as? Int, pid > 0,
            rootElement["application"] as? Bool == true,
            let rootAttributes = root["attributes"] as? [String: Any],
            let bundle = rootAttributes["3003"] as? String, !bundle.isEmpty
        else { throw invalid() }
        var nodes: [AXNode] = []
        var pending = [Entry(record: root, parent: nil, depth: 0)]
        while let entry = pending.popLast() {
            guard nodes.count < 4096, entry.depth <= 64,
                let element = entry.record["element"] as? [String: Any],
                let childPID = element["pid"] as? Int, childPID > 0,
                let identity = element["objectID"] as? String, UInt64(identity) != nil,
                let children = entry.record["children"] as? [[String: Any]],
                entry.record["childCount"] as? Int == children.count,
                let native = entry.record["attributes"] as? [String: Any],
                childPID == pid || (native["5003"] as? String == "AXRemoteElement" && children.isEmpty)
            else { throw invalid() }
            let index = nodes.count
            var fields = try attributes(native)
            fields["index"] = index
            fields["parent"] = entry.parent as Any? ?? NSNull()
            fields["attributeSource"] = "axp-native-snapshot"
            fields["nativeElement"] = element
            fields["reportedChildCount"] = children.count
            // A remote handle is not a Runner identityToken and never authorizes an action.
            fields["externalProcessReference"] = childPID != pid
            nodes.append(AXNode(index: index, parent: entry.parent, role: role(native), attributes: fields))
            pending += children.reversed().map { Entry(record: $0, parent: index, depth: entry.depth + 1) }
        }
        markTextResponder(payload, pid: pid, nodes: &nodes)
        var collection = try appendSupplements(payload, pid: pid, nodes: &nodes)
        collection["focusHit"] = payload["focusHit"]
        collection["receiveBudget"] = payload["receiveBudget"]
        appendTimingFacts(payload, to: &collection)
        return AXPSnapshot(
            nodes: nodes, bundle: bundle, screen: screen, displayID: numericDisplayID,
            displayUniqueID: display["displayUniqueID"] as? String, started: started, finished: finished,
            cleanup: cleanup, collection: collection)
    }

    private static func markTextResponder(_ payload: [String: Any], pid: Int, nodes: inout [AXNode]) {
        guard let responder = payload["textResponder"] as? [String: Any], responder["pid"] as? Int == pid,
            let objectID = responder["objectID"] as? String, let number = UInt64(objectID), number > 0 else { return }
        let matches = nodes.indices.filter { index in
            let element = nodes[index].attributes["nativeElement"] as? [String: Any]
            return element?["pid"] as? Int == pid && element?["objectID"] as? String == objectID
        }
        guard matches.count == 1, let index = matches.first else { return }
        let node = nodes[index]
        guard ["text_field", "text_view", "search_field"].contains(node.role) else { return }
        var fields = node.attributes
        fields["keyboardFocus"] = true
        nodes[index] = AXNode(index: index, parent: node.parent, role: node.role, attributes: fields)
    }

    private static func appendTimingFacts(_ payload: [String: Any], to collection: inout [String: Any]) {
        collection["stageTimingsMs"] = timingFacts(payload["stageTimingsMs"], allowed: [
            "ax.display_before", "ax.hit_before", "ax.root_before", "ax.tree",
            "ax.frontmost_before", "ax.frontmost_after", "ax.root_after", "ax.hit_after", "ax.display_after",
            "ax.structure_ack", "ax.structure_wait", "ax.structure_unpack"
        ])
        collection["collectionTimingsMs"] = timingFacts(payload["collectionTimingsMs"], allowed: [
            "ax.structure", "ax.structure_read", "ax.structure_export", "ax.candidates",
            "ax.keyboard_visibility", "ax.candidate_visibility"
        ])
    }

    static func timingFacts(_ value: Any?, allowed: [String]) -> [String: Double] {
        guard let values = value as? [String: Any] else { return [:] }
        var result: [String: Double] = [:]
        for key in allowed {
            guard let number = values[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, (0...120_000).contains(number.doubleValue) else { continue }
            result[key] = number.doubleValue
        }
        return result
    }

    private static func connectionEvidence(_ payload: [String: Any]) -> [String: Any]? {
        if let cleanup = payload["cleanup"] as? [String: Any],
            cleanup["connectionClosed"] as? Bool == true, cleanup["tunnelClosed"] as? Bool == true {
            return cleanup
        }
        guard let lease = payload["connectionLease"] as? [String: Any], lease["state"] as? String == "current",
            let generation = lease["generation"] as? String, UUID(uuidString: generation) != nil,
            let request = lease["requestID"] as? String, UUID(uuidString: request) != nil else { return nil }
        return ["deferredToSession": true, "connectionLease": lease]
    }

    static func attributes(_ native: [String: Any]) throws -> [String: Any] {
        var fields: [String: Any] = ["nativeAttributes": native, "enabled": NSNull(), "keyboardFocus": NSNull()]
        for (source, target) in [("2001", "label"), ("5019", "identifier"), ("2002", "hint")] {
            if let value = native[source], !(value is NSNull) {
                guard let string = value as? String else { throw invalid() }
                fields[target] = string
            }
        }
        if let value = native["2006"] {
            guard value is NSNull || value is String || value is NSNumber else { throw invalid() }
            fields["value"] = value
        }
        if native["2025"] is NSNull {
            fields["candidateVisibilityUnknown"] = true
        } else if let value = native["2025"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw invalid()
            }
            fields["visible"] = value
        }
        if let frame = native["2003"] as? [String: Any], let geometry = rect(frame) {
            fields["frame"] = ["x": geometry.minX, "y": geometry.minY,
                               "width": geometry.width, "height": geometry.height]
        } else {
            fields["frame"] = NSNull()
            fields["frameUnavailable"] = true
        }
        return fields
    }

    static func rect(_ value: [String: Any]) -> CGRect? {
        func number(_ key: String) -> Double? {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        guard let originX = number("x"), let originY = number("y"),
            let width = number("width"), let height = number("height"),
            [originX, originY, width, height].allSatisfy(\.isFinite), width > 0, height > 0
        else { return nil }
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    static func role(_ attributes: [String: Any]) -> String {
        if attributes["5003"] as? String == "UIKeyboardLayoutStar" { return "keyboard" }
        if attributes["5003"] as? String == "UIAccessibilityElementKBKey" { return "key" }
        // Exact reported UIKit superclass only; custom class names are not behavioral evidence.
        let roles = ["UIApplication": "application", "UIWindow": "window", "UIView": "group",
                     "UILabel": "text", "UIButton": "button", "UISwitch": "switch",
                     "UITextField": "text_field", "UISearchBarTextField": "search_field",
                     "UITextView": "text_view", "UITableView": "table", "UITableViewCell": "cell",
                     "UICollectionView": "collection_view", "UICollectionViewCell": "cell",
                     "UIScrollView": "scroll_view", "UIImageView": "image"]
        return roles[attributes["5004"] as? String ?? ""] ?? "unknown"
    }

    static func invalid() -> IPhoneUseError {
        IPhoneUseError("axp_invalid_snapshot", "AXP returned an incomplete or invalid observation")
    }
}
