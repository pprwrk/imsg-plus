import Foundation

@main
struct IMsgCLI {
  static func main() async {
    let router = CommandRouter()
    let status = await router.run()
    if status != 0 {
      exit(status)
    }
  }
}
