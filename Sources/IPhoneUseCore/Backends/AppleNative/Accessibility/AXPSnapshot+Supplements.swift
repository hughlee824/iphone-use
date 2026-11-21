import Foundation

extension AXPSnapshot {
    static func appendSupplements(_ payload: [String: Any], pid: Int, nodes: inout [AXNode]) throws -> [String: Any] {
        guard let strategy = payload["collectionStrategy"] else {
            guard payload["supplementalElements"] == nil else { throw invalid() }
            return [:]
        }
        guard strategy as? String == "full_tree_candidate_visibility_keyboard_batch_v1",
            payload["visibilityCoverage"] as? String == "semantic_candidates",
            let candidates = integer(payload["candidateCount"], maximum: 256),
            let batched = integer(payload["keyboardBatchedCandidateCount"], maximum: candidates),
            let supplements = payload["supplementalElements"] as? [[String: Any]],
            supplements.count <= candidates, nodes.count + supplements.count <= 4096
        else { throw invalid() }
        var identities = Set(nodes.compactMap { node -> String? in
            guard let element = node.attributes["nativeElement"] as? [String: Any] else { return nil }
            return identity(element)
        })
        for record in supplements {
            guard let element = record["element"] as? [String: Any], element["pid"] as? Int == pid,
                element["application"] as? Bool == false, let identifier = identity(element),
                identities.insert(identifier).inserted,
                let native = record["attributes"] as? [String: Any],
                let childCount = integer(record["reportedChildCount"], maximum: Int.max),
                record["parent"] is NSNull, record["hierarchyKnown"] as? Bool == false,
                record["childrenTraversed"] as? Bool == false, record["children"] == nil
            else { throw invalid() }
            var fields = try attributes(native)
            guard fields["visible"] is Bool || fields["candidateVisibilityUnknown"] as? Bool == true
            else { throw invalid() }
            fields.merge([
                "index": nodes.count, "parent": NSNull(), "nativeElement": element,
                "reportedChildCount": childCount, "hierarchyKnown": false, "childrenTraversed": false,
                "attributeSource": "axp-semantic-supplement", "externalProcessReference": false
            ]) { _, new in new }
            nodes.append(AXNode(index: nodes.count, parent: nil, role: role(native), attributes: fields))
        }
        let window = try keyboardWindowCounts(payload, candidates: candidates, supplements: supplements.count)
        let unknown = try unknownCandidateCount(nodes, expected: candidates - window.omitted)
        return ["strategy": strategy, "visibilityCoverage": "semantic_candidates",
                "candidateCount": candidates, "unknownVisibilityCandidateCount": unknown,
                "omittedSupplementalCandidateCount": window.omitted, "keyboardWindowMatchedCount": window.matched,
                "keyboardWindowProbed": window.probed, "keyboardBatchedCandidateCount": batched,
                "supplementalNodeCount": supplements.count]
    }

    private struct WindowCounts {
        var probed = false
        var matched = 0
        var omitted = 0
    }

    private static func keyboardWindowCounts(_ payload: [String: Any], candidates: Int, supplements: Int) throws
        -> WindowCounts {
        if payload["keyboardWindowProbed"] == nil, payload["keyboardWindowMatchedCount"] == nil,
           payload["omittedSupplementalCandidateCount"] == nil { return WindowCounts() }
        guard let flag = payload["keyboardWindowProbed"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let matched = integer(payload["keyboardWindowMatchedCount"], maximum: supplements),
              let omitted = integer(payload["omittedSupplementalCandidateCount"], maximum: candidates - supplements),
              flag.boolValue || (matched == 0 && omitted == 0)
        else { throw invalid() }
        return WindowCounts(probed: flag.boolValue, matched: matched, omitted: omitted)
    }

    private static func unknownCandidateCount(_ nodes: [AXNode], expected: Int) throws -> Int {
        var known = Set<String>()
        var unknown = Set<String>()
        for node in nodes {
            guard let element = node.attributes["nativeElement"] as? [String: Any],
                let identifier = identity(element) else { throw invalid() }
            if node.attributes["visible"] is Bool {
                known.insert(identifier)
            } else if node.attributes["candidateVisibilityUnknown"] as? Bool == true {
                unknown.insert(identifier)
            }
        }
        guard known.isDisjoint(with: unknown), known.count + unknown.count == expected else { throw invalid() }
        return unknown.count
    }

    private static func identity(_ element: [String: Any]) -> String? {
        guard let pid = element["pid"] as? Int, pid > 0,
            let identifier = element["objectID"] as? String, UInt64(identifier) != nil else { return nil }
        return "\(pid)/\(identifier)"
    }

    private static func integer(_ value: Any?, maximum: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let integer = Int(number.stringValue), integer >= 0, integer <= maximum else { return nil }
        return integer
    }
}
