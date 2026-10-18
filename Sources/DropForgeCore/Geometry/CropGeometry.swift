import Foundation

/// Crop rectangle maths in unit coordinates for an image of a given pixel size.
public enum CropGeometry {
    public enum Corner: Sendable, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    /// Common ratios offered as chips (width / height). `nil` = free.
    public static let presets: [(String, Double?)] = [
        ("Free", nil), ("Original", -1), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:5", 0.8),
    ]

    /// Largest rect with pixel aspect `ratio`, centred on `rect`'s centre, inside the image.
    public static func apply(ratio: Double, to rect: UnitRect, imageWidth w: Double, imageHeight h: Double) -> UnitRect {
        guard ratio > 0, w > 0, h > 0 else { return rect }
        // In unit space: (uw * w) / (uh * h) = ratio  →  uh = uw * w / (h * ratio)
        let cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2
        var uw = rect.width
        var uh = uw * w / (h * ratio)
        if uh > rect.height {
            uh = rect.height
            uw = uh * h * ratio / w
        }
        // Grow back to the largest size that fits the whole image when the result is tiny.
        let maxW = min(1, h * ratio / w), maxH = min(1, w / (h * ratio))
        if uw < 0.05 { uw = maxW; uh = maxH }
        var x = cx - uw / 2, y = cy - uh / 2
        x = min(max(x, 0), 1 - uw)
        y = min(max(y, 0), 1 - uh)
        return UnitRect(x: x, y: y, width: uw, height: uh)
    }

    public static func moved(_ rect: UnitRect, dx: Double, dy: Double) -> UnitRect {
        UnitRect(x: min(max(rect.x + dx, 0), 1 - rect.width), y: min(max(rect.y + dy, 0), 1 - rect.height),
                 width: rect.width, height: rect.height)
    }

    /// Drags one corner; the opposite corner stays fixed. Keeps `ratio` when given.
    public static func resized(_ rect: UnitRect, corner: Corner, dx: Double, dy: Double, ratio: Double?,
                               imageWidth w: Double, imageHeight h: Double, minimum: Double = 0.02) -> UnitRect {
        var x0 = rect.x, y0 = rect.y, x1 = rect.x + rect.width, y1 = rect.y + rect.height
        switch corner {
        case .topLeft: x0 += dx; y0 += dy
        case .topRight: x1 += dx; y0 += dy
        case .bottomLeft: x0 += dx; y1 += dy
        case .bottomRight: x1 += dx; y1 += dy
        }
        x0 = min(max(x0, 0), 1); x1 = min(max(x1, 0), 1); y0 = min(max(y0, 0), 1); y1 = min(max(y1, 0), 1)
        if x1 - x0 < minimum { if corner == .topLeft || corner == .bottomLeft { x0 = x1 - minimum } else { x1 = x0 + minimum } }
        if y1 - y0 < minimum { if corner == .topLeft || corner == .topRight { y0 = y1 - minimum } else { y1 = y0 + minimum } }
        var r = UnitRect(x: max(0, x0), y: max(0, y0), width: min(1, x1) - max(0, x0), height: min(1, y1) - max(0, y0))
        if let ratio, ratio > 0, w > 0, h > 0 {
            // Height follows width, anchored at the fixed corner.
            var uh = r.width * w / (h * ratio)
            var uw = r.width
            let anchoredTop = corner == .bottomLeft || corner == .bottomRight
            let available = anchoredTop ? 1 - r.y : (r.y + r.height)
            if uh > available { uh = available; uw = uh * h * ratio / w }
            let left = corner == .topRight || corner == .bottomRight ? r.x : r.x + r.width - uw
            let top = anchoredTop ? r.y : r.y + r.height - uh
            r = UnitRect(x: left, y: top, width: uw, height: uh)
        }
        return r
    }

    /// The corner within `tolerance` (unit space) of `point`, if any.
    public static func corner(near point: (Double, Double), of rect: UnitRect, tolerance: Double) -> Corner? {
        let corners: [(Corner, Double, Double)] = [
            (.topLeft, rect.x, rect.y), (.topRight, rect.x + rect.width, rect.y),
            (.bottomLeft, rect.x, rect.y + rect.height), (.bottomRight, rect.x + rect.width, rect.y + rect.height),
        ]
        return corners.first { abs($0.1 - point.0) <= tolerance && abs($0.2 - point.1) <= tolerance }?.0
    }
}
