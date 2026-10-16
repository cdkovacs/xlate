import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--dev") {
    exit(DevCommands.run(Array(arguments[(i + 1)...])))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
