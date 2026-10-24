import Foundation

struct RuleSnapshot {
    var running = false
    var speech = true
    var websiteFiltering = false
    var websites: Set<String> = []
    var applications: Set<String> = []
    var events = 0
    var isolatesBrowser: Bool { websiteFiltering && !websites.isEmpty }

    func blocks(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return websites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func blocks(application: String) -> Bool {
        applications.contains { application == $0 || application.hasPrefix($0 + ".") }
    }

    var captureExclusions: Set<String> {
        applications.union(isolatesBrowser ? Self.chromiumApplications : [])
    }

    static let chromiumApplications: Set<String> = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser"]

    static func host(from text: String) -> String? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty, let parsed = URL(string: input.contains("://") ? input : "https://" + input),
              let host = parsed.host, host.contains("."), !host.contains(" ") else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

final class RoutingRules {
    private let mutex = NSLock()
    private var value = RuleSnapshot()
    var snapshot: RuleSnapshot { mutex.lock(); defer { mutex.unlock() }; return value }
    func replace(_ snapshot: RuleSnapshot) { mutex.lock(); value = snapshot; mutex.unlock() }
}
