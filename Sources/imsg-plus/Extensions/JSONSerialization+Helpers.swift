import Foundation

extension JSONSerialization {
  static func string(from object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
}
