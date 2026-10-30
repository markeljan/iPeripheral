import Foundation

/// Bounding boxes from LFM3-VL's grounding answers: a JSON array of `{"bbox_2d": [xmin, ymin, xmax, ymax], "label"}`
/// with integers on a 0–1000 grid (Liquid's format), possibly wrapped in prose or a code fence.
public enum Grounding {
    public struct Box: Equatable, Sendable {
        public let label: String
        /// Normalized 0–1, top-left origin.
        public let x, y, w, h: Double
    }

    public static func parse(_ text: String) -> [Box] {
        guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b,
            let items = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let bb = item["bbox_2d"] as? [NSNumber], bb.count == 4 else { return nil }
            let v = bb.map { min(1, max(0, $0.doubleValue / 1000)) }
            guard v[2] > v[0], v[3] > v[1] else { return nil }
            return Box(label: (item["label"] as? String) ?? "", x: v[0], y: v[1], w: v[2] - v[0], h: v[3] - v[1])
        }
    }
}
