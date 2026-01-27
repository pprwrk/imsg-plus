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
  case chatNotFound(String)
  case messageNotFound(String)
  case operationFailed(String)
  
  public var description: String {
    switch self {
    case .frameworkNotAvailable:
      return "IMCore framework not available. Advanced features require SIP disabled."
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
  
  private var handle: UnsafeMutableRawPointer?
  private var registryClass: AnyObject.Type?
  private var sharedRegistry: AnyObject?
  private let queue = DispatchQueue(label: "imsg.imcore.bridge")
  
  public private(set) var isAvailable: Bool = false
  
  private init() {
    loadFramework()
  }
  
  private func loadFramework() {
    let frameworkPath = "/System/Library/PrivateFrameworks/IMCore.framework/IMCore"
    
    guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
      return
    }
    
    self.handle = handle
    
    guard let registryClass = objc_getClass("IMChatRegistry") as? AnyObject.Type else {
      return
    }
    
    self.registryClass = registryClass
    
    let sharedSelector = NSSelectorFromString("sharedInstance")
    guard registryClass.responds(to: sharedSelector) else {
      return
    }
    
    self.isAvailable = true
  }
  
  public func setTyping(for handle: String, typing: Bool) async throws {
    guard isAvailable else {
      throw IMCoreBridgeError.frameworkNotAvailable
    }
    
    throw IMCoreBridgeError.operationFailed("""
      Typing indicators require IMCore framework access.
      This feature is not yet fully implemented due to Swift/Objective-C bridging limitations.
      Consider using AppleScript as an alternative approach.
      """)
  }
  
  public func markAsRead(handle: String) async throws {
    guard isAvailable else {
      throw IMCoreBridgeError.frameworkNotAvailable
    }
    
    throw IMCoreBridgeError.operationFailed("""
      Read receipts require IMCore framework access.
      This feature is not yet fully implemented due to Swift/Objective-C bridging limitations.
      Consider using AppleScript as an alternative approach.
      """)
  }
  
  public func sendTapback(
    to handle: String,
    messageGUID: String,
    type: TapbackType
  ) async throws {
    guard isAvailable else {
      throw IMCoreBridgeError.frameworkNotAvailable
    }
    
    throw IMCoreBridgeError.operationFailed("""
      Tapback reactions require IMCore framework access.
      This feature is not yet fully implemented due to Swift/Objective-C bridging limitations.
      Consider using AppleScript as an alternative approach.
      """)
  }
  
  public func checkAvailability() -> (available: Bool, message: String) {
    if isAvailable {
      return (true, """
        IMCore framework detected. Advanced features are partially available.
        Note: Full implementation requires additional Objective-C bridging code.
        """)
    } else {
      return (false, """
        Advanced features unavailable. To enable:
        1. Disable SIP (restart in Recovery Mode, run 'csrutil disable')
        2. Grant Full Disk Access to Terminal
        3. Restart the application
        Basic messaging features will continue to work.
        """)
    }
  }
}