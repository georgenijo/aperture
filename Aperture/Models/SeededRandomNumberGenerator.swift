import Foundation

/// SplitMix64 is small, fast, and fully specified. A stored seed therefore
/// produces the same processing choices on every launch and architecture.
struct SeededRandomNumberGenerator: RandomNumberGenerator, Codable, Hashable, Sendable {
  private(set) var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }

  mutating func unitInterval() -> Double {
    // Use the upper 53 bits so every returned value is exactly representable.
    Double(next() >> 11) * 0x1.0p-53
  }

  mutating func value(in range: ClosedRange<Double>) -> Double {
    range.lowerBound + unitInterval() * (range.upperBound - range.lowerBound)
  }

  mutating func chance(_ probability: Double) -> Bool {
    unitInterval() < min(max(probability, 0), 1)
  }
}
