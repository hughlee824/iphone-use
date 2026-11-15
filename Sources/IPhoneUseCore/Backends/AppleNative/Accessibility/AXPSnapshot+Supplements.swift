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
            guard fields["visible"] is Bool else { throw invalid() }
            fields.merge([
                "index": nodes.count, "parent": NSNull(), "nativeElement": element,
                "reportedChildCount": childCount, "hierarchyKnown": false, "childrenTraversed": false,
                "attributeSource": "axp-semantic-supplement", "externalProcessReference": false
            ]) { _, new in new }
            nodes.append(AXNode(index: nodes.count, parent: nil, role: role(native), attributes: fields))
        }
        let visibleIdentities = Set(nodes.compactMap { node -> String? in
            guard node.attributes["visible"] is Bool,
                let element = node.attributes["nativeElement"] as? [String: Any] else { return nil }
            return identity(element)
        })
        guard visibleIdentities.count == candidates else { throw invalid() }
        return ["strategy": strategy, "visibilityCoverage": "semantic_candidates",
                "candidateCount": candidates, "keyboardBatchedCandidateCount": batched,
                "supplementalNodeCount": supplements.count]
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
