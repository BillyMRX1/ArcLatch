import AppKit
import ArcLatchCore

// Entry point: Finder launch runs the windowed app. `--verify` runs the
// headless end-to-end verifier against the same adapters and coordinator.
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--verify") {
    exit(VerifyCLI.run(arguments: args))
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = buildMainMenu()
app.run()
