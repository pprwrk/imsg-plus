import Foundation

enum DurationParser {
  static func parse(_ value: String) -> TimeInterval? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let units: [(suffix: String, multiplier: Double)] = [
      ("ms", 0.001),
      ("s", 1),
      ("m", 60),
      ("h", 3600),
    ]
    for unit in units {
      if trimmed.hasSuffix(unit.suffix) {
        let number = String(trimmed.dropLast(unit.suffix.count))
        if let value = Double(number) {
          return value * unit.multiplier
        }
        return nil
      }
    }
    if let value = Double(trimmed) {
      return value
    }
    return nil
  }
}
