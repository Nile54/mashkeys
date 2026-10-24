import AppKit
import ServiceManagement

final class MashKeysApplication: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let capture = AudioTap()
    private let rules = RoutingRules()
    private var bridge: BrowserBridge!
    private var animator: LightAnimator?
    private var shortcut: GlobalShortcut?
    private var status: NSStatusItem!
    private var statusLine = NSMenuItem()
    private var toggleItem = NSMenuItem()
    private var speechItem = NSMenuItem()
    private var loginItem = NSMenuItem()
    private var enabled = false
    private var captureStatus = "Paused"
    private var browserCount = 0
    private var eventCount = 0
    private var window: NSWindow?
    private lazy var settings = SettingsWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["speechProtection": true, "enabledLastSession": true])
        if let keyboard = try? KeyboardBacklight() { animator = LightAnimator(keyboard: keyboard) }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "MashKeys")
        status.button?.toolTip = "MashKeys · ⌘⌥K toggles music lights"
        makeMenu()
        settings.onChange = { [weak self] in self?.applyRules() }
        capture.onHit = { [weak self] hit in
            guard let self, self.enabled else { return }
            self.eventCount += 1; self.updateSnapshot()
            self.captureStatus = "Listening for bass"; self.animator?.react(to: hit); self.render()
        }
        capture.onSpeech = { [weak self] blocked in
            guard let self, self.enabled else { return }
            if blocked { self.animator?.speechBegan() }
            self.captureStatus = blocked ? "Talking filtered" : "Listening for bass"
            self.render()
        }
        capture.onStatus = { [weak self] text in self?.captureStatus = text; self?.render() }
        capture.onFailure = { [weak self] message in
            guard let self else { return }
            self.enabled = false; self.animator?.stop(); self.updateSnapshot()
            self.captureStatus = "Audio access needs attention"; self.render()
            self.showError(message)
        }
        bridge = BrowserBridge(rules: rules)
        bridge.onHit = { [weak self] hit, source in
            guard let self, self.enabled else { return }
            self.eventCount += 1; self.updateSnapshot()
            self.captureStatus = "Listening to music tab"; self.animator?.react(to: hit, source: source); self.render()
        }
        bridge.onSpeech = { [weak self] blocked, source in if blocked { self?.animator?.speechBegan(source: source) } }
        bridge.onConnection = { [weak self] count in self?.browserCount = count; self?.render() }
        do { try bridge.start() } catch { captureStatus = "Browser helper unavailable" }
        do { shortcut = try GlobalShortcut(); shortcut?.onToggle = { [weak self] in self?.toggle() } }
        catch { showError(error.localizedDescription) }
        updateSnapshot()
        if defaults.bool(forKey: "launchAtLogin") { registerLogin(true) }
        if defaults.bool(forKey: "onboardingDone") {
            if defaults.bool(forKey: "enabledLastSession") { setEnabled(true) }
        } else { showWelcome() }
    }

    private func makeMenu() {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(NSMenuItem(title: "MashKeys \(version)", action: nil, keyEquivalent: ""))
        statusLine = NSMenuItem(title: "Paused", action: nil, keyEquivalent: ""); menu.addItem(statusLine)
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "Music lights", action: #selector(toggle), keyEquivalent: "k")
        toggleItem.keyEquivalentModifierMask = [.command, .option]; toggleItem.target = self; menu.addItem(toggleItem)
        let item = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        item.target = self; menu.addItem(item)
        speechItem = NSMenuItem(title: "Ignore talking", action: #selector(toggleSpeech), keyEquivalent: "")
        speechItem.target = self; menu.addItem(speechItem)
        loginItem = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self; menu.addItem(loginItem)
        menu.addItem(.separator())
        let help = NSMenuItem(title: "Help & downloads", action: #selector(openProject), keyEquivalent: "")
        help.target = self; menu.addItem(help)
        menu.addItem(NSMenuItem(title: "Quit MashKeys", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "MashKeys")
        let preferences = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self; applicationMenu.addItem(preferences)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "Quit MashKeys", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = applicationMenu; main.addItem(applicationItem)
        NSApp.mainMenu = main
        render()
    }

    private func render() {
        guard status != nil else { return }
        toggleItem.state = enabled ? .on : .off
        speechItem.state = defaults.bool(forKey: "speechProtection") ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let isolated = !(defaults.stringArray(forKey: "blockedWebsites") ?? []).isEmpty
        let browser = isolated ? " · \(browserCount > 0 ? "Browser helper connected" : "Connect music tabs with helper")" : ""
        statusLine.title = enabled ? captureStatus + browser : "Paused · ⌘⌥K to enable"
        status.button?.appearsDisabled = !enabled
        status.button?.toolTip = "MashKeys · \(enabled ? captureStatus : "Paused") · ⌘⌥K"
    }

    private func updateSnapshot() {
        rules.replace(RuleSnapshot(running: enabled, speech: defaults.bool(forKey: "speechProtection"),
                                   websites: Set(defaults.stringArray(forKey: "blockedWebsites") ?? []),
                                   applications: Set(defaults.stringArray(forKey: "blockedApplications") ?? []), events: eventCount))
    }

    private func applyRules() {
        let before = rules.snapshot
        updateSnapshot()
        let after = rules.snapshot
        capture.setSpeechProtection(after.speech)
        if enabled && before.captureExclusions != after.captureExclusions {
            capture.start(excluding: after.captureExclusions, speech: after.speech)
        }
        render()
    }

    @objc private func toggle() { setEnabled(!enabled) }
    @objc private func toggleSpeech() { defaults.set(!defaults.bool(forKey: "speechProtection"), forKey: "speechProtection"); applyRules() }
    @objc private func openSettings() { settings.show() }
    @objc private func openProject() { NSWorkspace.shared.open(URL(string: "https://github.com/Nile54/mashkeys")!) }
    @objc private func toggleLogin() { registerLogin(SMAppService.mainApp.status != .enabled); render() }

    private func registerLogin(_ value: Bool) {
        do {
            if value && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if !value && SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            defaults.set(value, forKey: "launchAtLogin")
        } catch { showError("Login setting: \(error.localizedDescription)") }
    }

    private func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if value {
            guard let animator else { showError(KeyboardError.unsupported.localizedDescription); return }
            do { try animator.begin() } catch { showError(error.localizedDescription); return }
            defaults.set(true, forKey: "onboardingDone")
            window?.close()
            enabled = true; updateSnapshot(); captureStatus = "Starting audio…"
            let config = rules.snapshot
            capture.start(excluding: config.captureExclusions, speech: config.speech)
        } else {
            enabled = false; updateSnapshot(); capture.stop(); animator?.stop(); captureStatus = "Paused"
        }
        defaults.set(value, forKey: "enabledLastSession")
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        enabled = false; updateSnapshot(); capture.finish(); animator?.stop(); bridge.stop(); shortcut = nil
    }

    private func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = "MashKeys"; alert.informativeText = text
        alert.addButton(withTitle: "OK"); alert.runModal()
    }

    private func showWelcome() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "MashKeys"; panel.center(); window = panel
        guard let view = panel.contentView else { return }
        let title = NSTextField(labelWithString: "Let your keyboard\nfeel the music.")
        title.font = .systemFont(ofSize: 29, weight: .bold); title.maximumNumberOfLines = 2
        title.frame = NSRect(x: 28, y: 221, width: 390, height: 86); view.addSubview(title)
        let detail = NSTextField(wrappingLabelWithString: "Smooth bass pulses for your MacBook’s built-in backlight. Singing and rap stay musical; ordinary talking is filtered locally.\n\n⌘⌥K toggles the lights from any app. No microphone, recording or uploads.")
        detail.frame = NSRect(x: 28, y: 93, width: 383, height: 115)
        detail.textColor = .secondaryLabelColor; view.addSubview(detail)
        let button = NSButton(title: "Enable MashKeys", target: self, action: #selector(welcomeEnable))
        button.bezelStyle = .rounded; button.keyEquivalent = "\r"
        button.frame = NSRect(x: 27, y: 36, width: 182, height: 36); view.addSubview(button)
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func welcomeEnable() {
        defaults.set(true, forKey: "onboardingDone")
        window?.close(); setEnabled(true)
    }
}
