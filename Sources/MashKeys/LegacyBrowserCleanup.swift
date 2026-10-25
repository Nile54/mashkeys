import Foundation

/// Remove only this app's obsolete native-host registrations. Saved domain
/// choices remain in preferences, but have no effect on system audio capture.
enum LegacyBrowserCleanup {
    static func run(defaults: UserDefaults) {
        defaults.removeObject(forKey: "websiteFilteringEnabled")
        let name = "io.github.nile54.mashkeys"
        let oldHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MashKeysBridge").path
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for folder in ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"] {
            let path = base.appendingPathComponent(folder).appendingPathComponent("NativeMessagingHosts/" + name + ".json")
            guard let data = try? Data(contentsOf: path),
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  manifest["name"] as? String == name,
                  manifest["path"] as? String == oldHelper else { continue }
            try? FileManager.default.removeItem(at: path)
        }
    }
}
