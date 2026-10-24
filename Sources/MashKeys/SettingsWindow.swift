import AppKit

final class SettingsWindow: NSWindowController {
    var onChange: (() -> Void)?
    private let defaults = UserDefaults.standard
    private var sites = NSStackView()
    private var apps = NSStackView()
    private var hostField = NSTextField()
    private var speechButton = NSButton()
    private let presetSites = ["instagram.com", "tiktok.com", "facebook.com", "x.com", "youtube.com"]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MashKeys Settings"
        window.center()
        super.init(window: window)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        refreshSites(); refreshApps()
        speechButton.state = defaults.object(forKey: "speechProtection") as? Bool == false ? .off : .on
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        result.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return result
    }

    private func build() {
        guard let view = window?.contentView else { return }
        let title = label("Your music. Your rules.", size: 22, bold: true)
        title.frame = NSRect(x: 22, y: 565, width: 435, height: 32); view.addSubview(title)
        let tuning = label("Bass 20–150 Hz · 0–100% light · adaptive rise up to 2.2 seconds")
        tuning.textColor = .secondaryLabelColor
        tuning.frame = NSRect(x: 22, y: 535, width: 435, height: 26); view.addSubview(tuning)
        speechButton = NSButton(checkboxWithTitle: "Ignore talking; keep singing and rap", target: self, action: #selector(speechChanged))
        speechButton.frame = NSRect(x: 22, y: 497, width: 435, height: 24); view.addSubview(speechButton)
        let privacy = label("Speech detection stays on this Mac. Unknown audio starts immediately; confirmed talking is filtered after a short recognition window.")
        privacy.textColor = .secondaryLabelColor
        privacy.frame = NSRect(x: 22, y: 449, width: 435, height: 42); view.addSubview(privacy)

        let siteTitle = label("Ignore websites", bold: true)
        siteTitle.frame = NSRect(x: 22, y: 415, width: 180, height: 22); view.addSubview(siteTitle)
        let setup = NSButton(title: "Set up browser helper…", target: self, action: #selector(setupBrowser))
        setup.bezelStyle = .rounded; setup.frame = NSRect(x: 252, y: 409, width: 208, height: 30); view.addSubview(setup)
        let explanation = label("Site rules isolate Chrome/Edge/Brave audio. Click the helper on each music tab to connect it. Unconnected or blocked tabs never drive the lights; other apps continue normally.")
        explanation.textColor = .secondaryLabelColor
        explanation.frame = NSRect(x: 22, y: 350, width: 435, height: 56); view.addSubview(explanation)
        addScroll(stack: sites, frame: NSRect(x: 22, y: 222, width: 435, height: 120), to: view)
        hostField = NSTextField(frame: NSRect(x: 22, y: 182, width: 330, height: 26))
        hostField.placeholderString = "Add a domain, e.g. instagram.com"
        hostField.target = self; hostField.action = #selector(addSite); view.addSubview(hostField)
        let add = NSButton(title: "Add", target: self, action: #selector(addSite))
        add.bezelStyle = .rounded; add.frame = NSRect(x: 364, y: 180, width: 94, height: 30); view.addSubview(add)
        let appTitle = label("Ignore whole apps", bold: true)
        appTitle.frame = NSRect(x: 22, y: 145, width: 435, height: 24); view.addSubview(appTitle)
        addScroll(stack: apps, frame: NSRect(x: 22, y: 34, width: 435, height: 105), to: view)
        let footer = label("Global toggle: ⌘⌥K   ·   No recording. No uploads.", size: 11)
        footer.textColor = .secondaryLabelColor
        footer.frame = NSRect(x: 22, y: 9, width: 435, height: 20); view.addSubview(footer)
    }

    private func addScroll(stack: NSStackView, frame: NSRect, to parent: NSView) {
        let scroll = NSScrollView(frame: frame)
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        parent.addSubview(scroll)
    }

    private func clear(_ stack: NSStackView) { for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() } }

    private func refreshSites() {
        clear(sites)
        let blocked = Set(defaults.stringArray(forKey: "blockedWebsites") ?? [])
        for host in Set(presetSites).union(blocked).sorted() {
            let button = NSButton(checkboxWithTitle: host, target: self, action: #selector(siteChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(host)
            button.state = blocked.contains(host) ? .on : .off
            sites.addArrangedSubview(button)
        }
    }

    private func refreshApps() {
        clear(apps)
        let blocked = Set(defaults.stringArray(forKey: "blockedApplications") ?? [])
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier { names[id] = app.localizedName ?? id }
        }
        for id in blocked where names[id] == nil { names[id] = id }
        for (id, name) in names.sorted(by: { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }) {
            let button = NSButton(checkboxWithTitle: name, target: self, action: #selector(appChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.state = blocked.contains(id) ? .on : .off
            apps.addArrangedSubview(button)
        }
    }

    @objc private func speechChanged() { defaults.set(speechButton.state == .on, forKey: "speechProtection"); onChange?() }
    @objc private func setupBrowser() { BrowserInstaller.showInstructions() }
    @objc private func addSite() {
        guard let host = RuleSnapshot.host(from: hostField.stringValue) else { NSSound.beep(); return }
        var blocked = Set(defaults.stringArray(forKey: "blockedWebsites") ?? [])
        blocked.insert(host); defaults.set(blocked.sorted(), forKey: "blockedWebsites")
        hostField.stringValue = ""; refreshSites(); onChange?()
    }
    @objc private func siteChanged(_ button: NSButton) { change(button, key: "blockedWebsites") }
    @objc private func appChanged(_ button: NSButton) { change(button, key: "blockedApplications") }
    private func change(_ button: NSButton, key: String) {
        guard let id = button.identifier?.rawValue else { return }
        var values = Set(defaults.stringArray(forKey: key) ?? [])
        if button.state == .on { values.insert(id) } else { values.remove(id) }
        defaults.set(values.sorted(), forKey: key); onChange?()
    }
}
