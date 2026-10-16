import Foundation

/// Developer subcommands. They run inside the signed bundle so they share the
/// app's audio capture permission. Only these may print call content.
enum DevCommands {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        default:
            print("usage: Xlate --dev <command>")
            return 64
        }
    }
}
