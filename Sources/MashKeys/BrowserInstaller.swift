import AppKit

enum BrowserInstaller {
    static let nativeName = "io.github.nile54.mashkeys"
    // Filled from the extension's fixed public key by scripts/build.sh.
    static var extensionID: String {
        guard let url = Bundle.main.url(forResource: "extension-id", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func installRegistrations() throws -> URL {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MashKeysBridge")
        guard FileManager.default.isExecutableFile(atPath: helper.path), !extensionID.isEmpty,
              let extensionFolder = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension") else { throw BridgeFailure.invalidMessage }
        let manifest: [String: Any] = ["name": nativeName, "description": "MashKeys local tab-audio bridge",
                                      "path": helper.path, "type": "stdio",
                                      "allowed_origins": ["chrome-extension://\(extensionID)/"]]
        let homes = [("com.google.Chrome", "Google/Chrome"), ("com.microsoft.edgemac", "Microsoft Edge"),
                     ("com.brave.Browser", "BraveSoftware/Brave-Browser")]
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for (bundle, folder) in homes where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil {
            let destination = base.appendingPathComponent(folder).appendingPathComponent("NativeMessagingHosts")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent(nativeName + ".json"), options: .atomic)
        }
        return extensionFolder
    }

    static func showInstructions() {
        do {
            let folder = try installRegistrations()
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            let alert = NSAlert()
            alert.messageText = "Connect individual music tabs"
            alert.informativeText = "In Chrome or Edge, open Extensions → Manage Extensions, enable Developer mode and choose Load unpacked. Select the BrowserExtension folder shown in Finder. Pin MashKeys, then click its button on each music tab to connect it.\n\nWhen website rules are enabled, unconnected browser tabs never drive the keyboard. Blocked sites are ignored without muting them or stopping other music. All processing stays on this Mac."
            alert.addButton(withTitle: "Open Chrome Extensions")
            alert.addButton(withTitle: "Done")
            if alert.runModal() == .alertFirstButtonReturn,
               let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: chrome,
                                        configuration: NSWorkspace.OpenConfiguration())
            }
        } catch {
            let alert = NSAlert(error: error); alert.runModal()
        }
    }
}
