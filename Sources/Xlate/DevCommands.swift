import Foundation
import XlateCore

/// Developer subcommands. They run inside the signed bundle so they share the
/// app's audio capture permission. Only these may print call content.
enum DevCommands {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "procs":
            return procs()
        default:
            print("usage: Xlate --dev <command>")
            return 64
        }
    }

    static func procs() -> Int32 {
        do {
            for p in try AudioProcesses.all() {
                print("pid=\(p.pid)\tobj=\(p.objectID)\toutput=\(p.isRunningOutput ? 1 : 0)\t\(p.bundleID ?? "-")")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
