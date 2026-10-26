import Foundation

/// Only whole-app exclusions affect native capture. Legacy domain preferences
/// never exclude a browser from the system mix.
struct RuleSnapshot {
    var speech = true
    var reaction = ReactionSettings()
    var applications: Set<String> = []
    var captureExclusions: Set<String> { applications }

    func blocks(application: String) -> Bool {
        applications.contains { application == $0 || application.hasPrefix($0 + ".") }
    }

    static func load(from defaults: UserDefaults) -> RuleSnapshot {
        RuleSnapshot(speech: defaults.object(forKey: "speechProtection") as? Bool != false,
                     reaction: ReactionSettings.load(from: defaults),
                     applications: Set(defaults.stringArray(forKey: "blockedApplications") ?? []))
    }
}
