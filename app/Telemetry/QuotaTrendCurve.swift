import Foundation

struct QuotaCurvePoint: Equatable {
    let time: Double
    let value: Double
}

struct QuotaCurveSegment {
    let start: QuotaCurvePoint
    let control1: QuotaCurvePoint
    let control2: QuotaCurvePoint
    let end: QuotaCurvePoint
}

/// Shape-preserving cubic Hermite interpolation (PCHIP), in time/percent units.
/// This is drawing geometry only: it passes through the actual samples and
/// never overshoots adjacent values. Call separately for each observed segment
/// so offline gaps, resets and plan boundaries are never joined.
enum QuotaTrendCurve {
    static func make(_ points: [QuotaHistoryPoint]) -> [QuotaCurveSegment] {
        guard points.count >= 2,
              points.allSatisfy({ $0.time.isFinite && (0...100).contains($0.remaining) }),
              zip(points, points.dropFirst()).allSatisfy({ $0.time < $1.time }) else { return [] }
        let h = zip(points, points.dropFirst()).map { $1.time - $0.time }
        let slopes = points.indices.dropLast().map { Double(points[$0 + 1].remaining - points[$0].remaining) / h[$0] }
        var tangents = Array(repeating: 0.0, count: points.count)
        if points.count == 2 {
            tangents = [slopes[0], slopes[0]]
        } else {
            func endpoint(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
                let slope = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
                if d0 == 0 || slope.sign != d0.sign { return 0 }
                if d0.sign != d1.sign && abs(slope) > 3 * abs(d0) { return 3 * d0 }
                return slope
            }
            tangents[0] = endpoint(h[0], h[1], slopes[0], slopes[1])
            let last = h.count - 1
            tangents[points.count - 1] = endpoint(h[last], h[last - 1], slopes[last], slopes[last - 1])
            for i in 1..<(points.count - 1) {
                let left = slopes[i - 1], right = slopes[i]
                if left == 0 || right == 0 || left.sign != right.sign { continue }
                let w1 = 2 * h[i] + h[i - 1], w2 = h[i] + 2 * h[i - 1]
                tangents[i] = (w1 + w2) / (w1 / left + w2 / right)
            }
        }
        return points.indices.dropLast().map { i in
            let a = points[i], b = points[i + 1], third = h[i] / 3
            return QuotaCurveSegment(
                start: QuotaCurvePoint(time: a.time, value: Double(a.remaining)),
                control1: QuotaCurvePoint(time: a.time + third, value: Double(a.remaining) + tangents[i] * third),
                control2: QuotaCurvePoint(time: b.time - third, value: Double(b.remaining) - tangents[i + 1] * third),
                end: QuotaCurvePoint(time: b.time, value: Double(b.remaining)))
        }
    }
}
