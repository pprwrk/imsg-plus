import Foundation

public enum TapbackType: Int, Sendable {
  case love = 2000
  case thumbsUp = 2001
  case thumbsDown = 2002
  case haha = 2003
  case emphasis = 2004
  case question = 2005
  
  case removeLove = 3000
  case removeThumbsUp = 3001
  case removeThumbsDown = 3002
  case removeHaha = 3003
  case removeEmphasis = 3004
  case removeQuestion = 3005
  
  public var displayName: String {
    switch self {
    case .love, .removeLove: return "love"
    case .thumbsUp, .removeThumbsUp: return "thumbsup"
    case .thumbsDown, .removeThumbsDown: return "thumbsdown"
    case .haha, .removeHaha: return "haha"
    case .emphasis, .removeEmphasis: return "emphasis"
    case .question, .removeQuestion: return "question"
    }
  }
  
  public static func from(string: String, remove: Bool = false) -> TapbackType? {
    let offset = remove ? 1000 : 0
    switch string.lowercased() {
    case "love", "heart": return TapbackType(rawValue: 2000 + offset)
    case "thumbsup", "like": return TapbackType(rawValue: 2001 + offset)
    case "thumbsdown", "dislike": return TapbackType(rawValue: 2002 + offset)
    case "haha", "laugh": return TapbackType(rawValue: 2003 + offset)
    case "emphasis", "exclaim", "!!": return TapbackType(rawValue: 2004 + offset)
    case "question", "?": return TapbackType(rawValue: 2005 + offset)
    default: return nil
    }
  }
}

public enum IMCoreBridgeError: Error, CustomStringConvertible {
  case frameworkNotAvailable
  case helperNotFound
  case helperExecutionFailed(String)
  case chatNotFound(String)
  case messageNotFound(String)
  case operationFailed(String)
  
  public var description: String {
    switch self {
    case .frameworkNotAvailable:
      return "IMCore framework not available. Advanced features require SIP disabled."
    case .helperNotFound:
      return "imsg-helper binary not found. Build with: cd Sources/IMsgHelper && make"
    case .helperExecutionFailed(let error):
      return "Helper execution failed: \(error)"
    case .chatNotFound(let id):
      return "Chat not found: \(id)"
    case .messageNotFound(let guid):
      return "Message not found: \(guid)"
    case .operationFailed(let reason):
      return "Operation failed: \(reason)"
    }
  }
}

public final class IMCoreBridge: @unchecked Sendable {
  public static let shared = IMCoreBridge()
  
  private let helperPath: String
  private let queue = DispatchQueue(label: "imsg.imcore.bridge")
  
  public private(set) var isAvailable: Bool = false
  
  private init() {
    // Look for helper binary in multiple locations
    let possiblePaths = [
      ".build/release/imsg-helper",
      ".build/debug/imsg-helper",
      "/usr/local/bin/imsg-helper",
      Bundle.main.bundlePath + "/../imsg-helper"
    ]
    
    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        self.helperPath = path
        self.isAvailable = true
        return
      }
    }
    
    // If not found, use default path
    self.helperPath = ".build/release/imsg-helper"
    self.isAvailable = false
  }
  
  private func callHelper(action: String, params: [String: Any]) async throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: helperPath) else {
      throw IMCoreBridgeError.helperNotFound
    }
    
    let command: [String: Any] = [
      "action": action,
      "params": params
    ]
    
    let jsonData = try JSONSerialization.data(withJSONObject: command, options: [])
    
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: self.helperPath)
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
          try process.run()
          
          // Send JSON command
          inputPipe.fileHandleForWriting.write(jsonData)
          inputPipe.fileHandleForWriting.closeFile()
          
          // Wait for completion
          process.waitUntilExit()
          
          // Read output
          let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
          
          if let response = try? JSONSerialization.jsonObject(with: outputData, options: []) as? [String: Any] {
            if response["success"] as? Bool == true {
              continuation.resume(returning: response)
            } else {
              let error = response["error"] as? String ?? "Unknown error"
              continuation.resume(throwing: IMCoreBridgeError.operationFailed(error))
            }
          } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            continuation.resume(throwing: IMCoreBridgeError.helperExecutionFailed(errorString))
          }
        } catch {
          continuation.resume(throwing: IMCoreBridgeError.helperExecutionFailed(error.localizedDescription))
        }
      }
    }
  }
  
  public func setTyping(for handle: String, typing: Bool) async throws {
    let params = [
      "handle": handle,
      "typing": typing
    ] as [String: Any]
    
    _ = try await callHelper(action: "typing", params: params)
  }
  
  public func markAsRead(handle: String) async throws {
    let params = ["handle": handle]
    _ = try await callHelper(action: "read", params: params)
  }
  
  public func sendTapback(
    to handle: String,
    messageGUID: String,
    type: TapbackType
  ) async throws {
    let params = [
      "handle": handle,
      "guid": messageGUID,
      "type": type.rawValue
    ] as [String: Any]
    
    _ = try await callHelper(action: "react", params: params)
  }
  
  public func checkAvailability() -> (available: Bool, message: String) {
    if !FileManager.default.fileExists(atPath: helperPath) {
      return (false, """
        Helper binary not found. To build:
        1. cd Sources/IMsgHelper
        2. make
        3. Restart imsg
        
        Note: Advanced features require:
        - SIP disabled (for IMCore access)
        - Full Disk Access granted to Terminal
        """)
    }
    
    // Try to check status via helper
    let process = Process()
    process.executableURL = URL(fileURLWithPath: helperPath)
    
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    
    let command = ["action": "status", "params": [:]] as [String: Any]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: command, options: []) else {
      return (false, "Failed to create status check command")
    }
    
    do {
      try process.run()
      inputPipe.fileHandleForWriting.write(jsonData)
      inputPipe.fileHandleForWriting.closeFile()
      process.waitUntilExit()
      
      let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
      if let response = try? JSONSerialization.jsonObject(with: outputData, options: []) as? [String: Any],
         response["success"] as? Bool == true {
        return (true, "IMCore framework loaded. Advanced features available.")
      } else {
        return (false, "IMCore framework not accessible. Ensure SIP is disabled.")
      }
    } catch {
      return (false, "Helper binary exists but failed to execute: \(error.localizedDescription)")
    }
  }
}