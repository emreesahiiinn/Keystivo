import Foundation

public extension BinaryFloatingPoint {
    /// `Int(self)` that never traps: NaN gives 0, infinities and values beyond
    /// ±2^52 are clamped. For numbers from drivers, settings files and user input.
    nonisolated var safeInt: Int {
        guard !isNaN else { return 0 }
        let limit: Self = 4_503_599_627_370_496 // 2^52, exact in Float and Double
        return Int(Swift.min(Swift.max(self, -limit), limit))
    }

    /// The value, or `fallback` when it is NaN or infinite.
    nonisolated func finite(or fallback: Self) -> Self { isFinite ? self : fallback }
}
