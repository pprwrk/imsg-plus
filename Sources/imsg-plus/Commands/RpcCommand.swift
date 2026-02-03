import Commander
import Foundation
import IMsgCore

enum RpcCommand {
  static let spec = CommandSpec(
    name: "rpc",
    abstract: "Run JSON-RPC over stdin/stdout",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions(),
        flags: [
          .make(
            label: "noAutoRead", names: [.long("no-auto-read")],
            help: "Disable automatic read receipts"),
          .make(
            label: "noAutoTyping", names: [.long("no-auto-typing")],
            help: "Disable automatic typing indicators on send"),
        ]
      )
    ),
    usageExamples: [
      "imsg rpc",
      "imsg rpc --db ~/Library/Messages/chat.db",
      "imsg rpc --no-auto-read",
      "imsg rpc --no-auto-typing",
    ]
  ) { values, runtime in
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try MessageStore(path: dbPath)
    let autoRead: Bool? = values.flag("noAutoRead") ? false : nil
    let autoTyping: Bool? = values.flag("noAutoTyping") ? false : nil
    let server = RPCServer(
      store: store,
      verbose: runtime.verbose,
      autoRead: autoRead,
      autoTyping: autoTyping
    )
    try await server.run()
  }
}
