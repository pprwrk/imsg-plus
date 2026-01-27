import Commander
import Foundation
import IMsgCore

enum ReadCommand {
  static let spec = CommandSpec(
    name: "read",
    abstract: "Mark messages as read and send read receipts",
    discussion: """
      Mark all messages in a conversation as read. This clears the unread
      badge and sends read receipts to the sender if enabled in your
      Messages settings.
      
      Note: Requires advanced permissions (SIP disabled) for full functionality.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "handle", names: [.long("handle")], help: "Phone number, email, or chat identifier"),
          .make(label: "messageGUID", names: [.long("message-guid")], help: "Specific message GUID to mark as read (optional)")
        ]
      )
    ),
    usageExamples: [
      "imsg read --handle +14155551234",
      "imsg read --handle john@example.com",
      "imsg read --handle chat123456789",
      "imsg read --handle +14155551234 --message-guid ABC123-456-789"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }
  
  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let handle = values.option("handle") else {
      throw IMsgError.invalidArgument("--handle is required")
    }
    let messageGUID = values.option("messageGUID")
    
    let bridge = IMCoreBridge.shared
    let availability = bridge.checkAvailability()
    
    if !availability.available {
      print("⚠️  \(availability.message)")
      print("\nRead receipts require advanced features to be enabled.")
      print("See: https://github.com/steipete/imsg#advanced-features")
      return
    }
    
    do {
      if let guid = messageGUID {
        print("Note: Marking specific messages not yet implemented. Marking entire conversation.")
      }
      
      try await bridge.markAsRead(handle: handle)
      
      if runtime.jsonOutput {
        let output: [String: Any] = [
          "success": true,
          "handle": handle,
          "marked_as_read": true,
          "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let guid = messageGUID {
          var mutableOutput = output
          mutableOutput["message_guid"] = guid
          print(JSONSerialization.string(from: mutableOutput))
        } else {
          print(JSONSerialization.string(from: output))
        }
      } else {
        print("✓ Marked messages as read for \(handle)")
        if messageGUID != nil {
          print("  (Entire conversation marked, not just specific message)")
        }
      }
    } catch let error as IMCoreBridgeError {
      if runtime.jsonOutput {
        let output: [String: Any] = [
          "success": false,
          "error": error.description,
          "handle": handle
        ]
        print(JSONSerialization.string(from: output))
      } else {
        print("❌ \(error)")
      }
      throw error
    }
  }
}