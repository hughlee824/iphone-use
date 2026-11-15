import Foundation
import CoreGraphics

/// A presentation projection only. Full nodes and action identities remain in the cache.
enum PresentedAX {
    struct Projection {
        let indices: Set<Int>
        let hierarchyKnown: Bool
        let geometryKnown: Bool
        let omittedKeyboardCharacters: Int
        let semanticCandidatesOnly: Bool
        let unqueriedChildControls: Int
    }

    static func project(_ capture: CapturedObservation) -> Projection {
        let nodes = capture.nodes
        let keyboardCharacters = AXKeyboardPresentation.ordinaryCharacterIndices(nodes)
        let collection = capture.metadata["axCollection"] as? [String: Any]
        let semanticCandidatesOnly = collection?["strategy"] as? String
            == "full_tree_candidate_visibility_keyboard_batch_v1"
        let screen = rect(capture.metadata["screenFrame"])
        let hierarchyKnown = capture.metadata["snapshotSource"] as? String
            == "explicit_modal_standard_attributes_v1"
        let clippingRoles: Set<String> = ["window", "scroll_view", "collection_view", "table", "web_view"]
        var clips: [CGRect?] = []
        var indices: Set<Int> = []
        for node in nodes {
            var clip = node.parent.flatMap { clips[$0] } ?? screen
            let frame = rect(node.attributes["frame"])
            if clippingRoles.contains(node.role), let frame {
                clip = clip.map { $0.intersection(frame) } ?? frame
            }
            clips.append(clip)
            let native = node.attributes["nativeAttributes"] as? [String: Any]
            let keyboardContext = native?["5003"] as? String == "UIKeyboardLayoutStar"
            // Unknown structural nodes are not called invisible; inspect still has them.
            if semanticCandidatesOnly, !(node.attributes["visible"] is Bool), !keyboardContext { continue }
            if keyboardCharacters.contains(node.index) { continue }
            if node.attributes["visible"] as? Bool == false { continue }
            if let frame, let clip, !frame.intersects(clip) { continue }
            indices.insert(node.index)
        }
        let additions = semanticCandidatesOnly
            ? childControls(nodes, selected: indices, screen: screen, clips: clips) : []
        indices.formUnion(additions)
        // CompactAX retains the original references and connects selected nodes
        // through their nearest retained ancestor; no action target is rewritten.
        return Projection(
            indices: indices, hierarchyKnown: hierarchyKnown, geometryKnown: screen != nil,
            omittedKeyboardCharacters: keyboardCharacters.count, semanticCandidatesOnly: semanticCandidatesOnly,
            unqueriedChildControls: additions.count)
    }

    static func rect(_ raw: Any?) -> CGRect? {
        guard let values = raw as? [String: Any],
            let originX = (values["x"] as? NSNumber)?.doubleValue,
            let originY = (values["y"] as? NSNumber)?.doubleValue,
            let width = (values["width"] as? NSNumber)?.doubleValue,
            let height = (values["height"] as? NSNumber)?.doubleValue,
            [originX, originY, width, height].allSatisfy(\.isFinite), width >= 0, height >= 0
        else { return nil }
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}
