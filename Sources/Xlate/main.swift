import AppKit
import XlateCore

@MainActor
func runApp(target: String = TargetApp.teamsBundleID, devMode: Bool = false) -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate(target: target, devMode: devMode)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--dev") {
    exit(DevCommands.run(Array(arguments[(i + 1)...])))
}
MainActor.assumeIsolated { runApp() }
