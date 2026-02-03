import Commander
import Foundation
import IMsgCore

enum TypingCommand {
  static let spec = CommandSpec(
    name: "typing",
    abstract: "Control typing indicator for a conversation",
    discussion: """
      Set or clear the typing indicator in a conversation. This shows or hides
      the three dots animation in the recipient's Messages app.

      Note: Requires advanced permissions (SIP disabled) for full functionality.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "handle", names: [.long("handle")],
            help: "Phone number, email, or chat identifier"),
          .make(
            label: "state", names: [.long("state")], help: "on or off to show/hide typing indicator"
          ),
        ]
      )
    ),
    usageExamples: [
      "imsg-plus typing --handle +14155551234 --state on",
      "imsg-plus typing --handle john@example.com --state off",
      "imsg-plus typing --handle chat123456789 --state on",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let handle = values.option("handle") else {
      throw IMsgError.invalidArgument("--handle is required")
    }
    guard let state = values.option("state") else {
      throw IMsgError.invalidArgument("--state is required")
    }

    guard state == "on" || state == "off" else {
      throw IMsgError.invalidArgument("State must be 'on' or 'off'")
    }

    let bridge = IMCoreBridge.shared
    let availability = bridge.checkAvailability()

    if !availability.available {
      print("⚠️  \(availability.message)")
      print("\nTyping indicators require advanced features to be enabled.")
      print("See: https://github.com/steipete/imsg#advanced-features")
      return
    }

    do {
      try await bridge.setTyping(for: handle, typing: state == "on")

      if runtime.jsonOutput {
        let output: [String: Any] = [
          "success": true,
          "handle": handle,
          "typing": state == "on",
          "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        print(JSONSerialization.string(from: output))
      } else {
        let emoji = state == "on" ? "💬" : "✓"
        print("\(emoji) Typing indicator \(state == "on" ? "enabled" : "disabled") for \(handle)")
      }
    } catch let error as IMCoreBridgeError {
      if runtime.jsonOutput {
        let output: [String: Any] = [
          "success": false,
          "error": error.description,
          "handle": handle,
        ]
        print(JSONSerialization.string(from: output))
      } else {
        print("❌ \(error)")
      }
      throw error
    }
  }
}
