import Foundation
import CoreGraphics

/// One segment's geometry. Angles are radians in y-up coordinates (AppKit), 0 = east, counter-clockwise positive.
public struct WheelSegmentGeometry: Sendable, Hashable {
    public let index: Int
    public let ring: Int
    public let startAngle: Double
    public let endAngle: Double
    public let innerRadius: Double
    public let outerRadius: Double

    public var centerAngle: Double { (startAngle + endAngle) / 2 }
    public var midRadius: Double { (innerRadius + outerRadius) / 2 }

    /// Position for the icon/label, relative to the wheel centre.
    public var labelPoint: CGPoint {
        CGPoint(x: cos(centerAngle) * midRadius, y: sin(centerAngle) * midRadius)
    }
}

/// Lays out up to `capacity` segments in one or two rings and answers hit tests.
public struct WheelLayout: Sendable, Hashable {
    public static let innerCapacity = 8
    public static let outerCapacity = 12
    /// Arc width of an outer segment = 360° / outerSlots (unless more items need narrower arcs).
    static let outerSlots = 10
    public static var capacity: Int { innerCapacity + outerCapacity }

    public let count: Int
    public let hubRadius: Double
    public let ringWidth: Double
    public let ringGap: Double
    /// Gap between neighbouring segments, in radians.
    public let segmentGap: Double
    public let segments: [WheelSegmentGeometry]

    public init(count: Int, hubRadius: Double = 58, ringWidth: Double = 78, ringGap: Double = 6, segmentGap: Double = 0.035) {
        self.count = max(0, min(count, Self.capacity))
        self.hubRadius = hubRadius
        self.ringWidth = ringWidth
        self.ringGap = ringGap
        self.segmentGap = segmentGap
        let innerCount = min(self.count, Self.innerCapacity)
        let outerCount = self.count - innerCount
        var segs: [WheelSegmentGeometry] = []
        func ring(_ ringIndex: Int, count n: Int, firstIndex: Int) {
            guard n > 0 else { return }
            let inner = hubRadius + ringGap + Double(ringIndex) * (ringWidth + ringGap)
            // The inner ring is always split evenly. Outer segments keep a fixed arc width and are grouped
            // around the top, so one or two overflow items do not swallow the whole ring.
            let slots = ringIndex == 0 ? n : max(n, Self.outerSlots)
            let span = 2 * Double.pi / Double(slots)
            let firstCenter = ringIndex == 0 ? Double.pi / 2 : Double.pi / 2 + Double(n - 1) * span / 2
            for i in 0..<n {
                // Segment 0 is centred at the top (inner ring); following segments run clockwise.
                let center = firstCenter - Double(i) * span
                let half = span / 2 - (slots > 1 ? segmentGap / 2 : 0)
                segs.append(WheelSegmentGeometry(index: firstIndex + i, ring: ringIndex,
                                                 startAngle: center - half, endAngle: center + half,
                                                 innerRadius: inner, outerRadius: inner + ringWidth))
            }
        }
        ring(0, count: innerCount, firstIndex: 0)
        ring(1, count: outerCount, firstIndex: innerCount)
        segments = segs
    }

    public var ringCount: Int { count > Self.innerCapacity ? 2 : (count > 0 ? 1 : 0) }

    /// Overall radius (for window sizing).
    public var outerRadius: Double {
        hubRadius + ringGap + Double(max(ringCount, 1)) * (ringWidth + ringGap)
    }

    /// Segment under `point` (relative to the centre), or nil for the hub, gaps and outside.
    public func hitTest(_ point: CGPoint) -> Int? {
        let r = hypot(point.x, point.y)
        guard r > hubRadius else { return nil }
        let angle = atan2(Double(point.y), Double(point.x))
        for s in segments where r >= s.innerRadius && r <= s.outerRadius {
            if Self.angle(angle, isBetween: s.startAngle, and: s.endAngle) { return s.index }
        }
        return nil
    }

    public func isInHub(_ point: CGPoint) -> Bool { hypot(point.x, point.y) <= hubRadius }

    static func normalize(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x < 0 { x += 2 * .pi }
        return x
    }

    static func angle(_ a: Double, isBetween start: Double, and end: Double) -> Bool {
        if end - start >= 2 * .pi - 1e-9 { return true }
        let s = normalize(start), e = normalize(end), x = normalize(a)
        return s <= e ? (x >= s && x <= e) : (x >= s || x <= e)
    }

    // MARK: Keyboard

    public enum Direction: Sendable { case left, right, up, down }

    /// Next selection for an arrow key. Right/Down run clockwise, Left/Up counter-clockwise; with two rings,
    /// Up moves to the outer ring and Down to the inner ring at the nearest angle.
    public func move(from current: Int?, _ direction: Direction) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current < count else { return 0 }
        let seg = segments[current]
        let ringSegs = segments.filter { $0.ring == seg.ring }
        let pos = ringSegs.firstIndex { $0.index == current } ?? 0
        if ringCount == 2 {
            switch direction {
            case .up where seg.ring == 0: return nearest(to: seg.centerAngle, ring: 1)
            case .down where seg.ring == 1: return nearest(to: seg.centerAngle, ring: 0)
            default: break
            }
        }
        switch direction {
        case .right, .down: return ringSegs[(pos + 1) % ringSegs.count].index
        case .left, .up: return ringSegs[(pos - 1 + ringSegs.count) % ringSegs.count].index
        }
    }

    func nearest(to angle: Double, ring: Int) -> Int? {
        segments.filter { $0.ring == ring }.min { a, b in
            Self.angularDistance(a.centerAngle, angle) < Self.angularDistance(b.centerAngle, angle)
        }?.index
    }

    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalize(a) - normalize(b))
        return min(d, 2 * .pi - d)
    }
}
