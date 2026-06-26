import Foundation

/// A piecewise-linear mapping from an input (GPU% or temperature °C) to a fan
/// RPM. Points are kept sorted by `x`; evaluation clamps and interpolates.
public struct Curve: Codable, Equatable {
    public struct Point: Codable, Equatable, Identifiable {
        public var id = UUID()
        public var x: Double   // input: percent or °C
        public var rpm: Double
        public init(x: Double, rpm: Double) { self.x = x; self.rpm = rpm }
        // `id` is intentionally excluded so it never appears in persisted JSON.
        enum CodingKeys: String, CodingKey { case x, rpm }
    }

    public var points: [Point]

    public init(points: [Point]) {
        self.points = points.sorted { $0.x < $1.x }
    }

    /// Interpolated RPM for `x`, clamped to the curve's endpoints.
    public func rpm(for x: Double) -> Double {
        guard let first = points.first else { return 0 }
        guard let last = points.last else { return 0 }
        if x <= first.x { return first.rpm }
        if x >= last.x { return last.rpm }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if x <= b.x {
                let t = (x - a.x) / (b.x - a.x)
                return a.rpm + t * (b.rpm - a.rpm)
            }
        }
        return last.rpm
    }
}
