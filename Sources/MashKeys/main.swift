import AppKit

if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "MashKeysBridge" {
    runBrowserNativeHost()
}

if let identifier = Bundle.main.bundleIdentifier,
   let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.executableURL?.lastPathComponent == "MashKeys" }) {
    existing.activate(options: [])
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = MashKeysApplication()
application.delegate = delegate
signal(SIGTERM, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { application.terminate(nil) }
termination.resume()
application.run()
