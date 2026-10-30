import AppKit
import ServiceManagement

final class MashKeysApplication: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let capture = AudioTap()
    private var rules = RuleSnapshot()
    private var animator: LightAnimator?
    private var shortcut: GlobalShortcut?
    private var syncTimer: DispatchSourceTimer?
    private var status: NSStatusItem!
    private var statusLine = NSMenuItem()
    private var toggleItem = NSMenuItem()
    private var speechItem = NSMenuItem()
    private var loginItem = NSMenuItem()
    private var enabled = false
    private var captureStatus = "Paused"
    private var window: NSWindow?
    private lazy var settings = SettingsWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["speechProtection": true, "enabledLastSession": true])
        LegacyBrowserCleanup.run(defaults: defaults)
        if let keyboard = try? KeyboardBacklight() { animator = LightAnimator(keyboard: keyboard) }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "MashKeys")
        status.button?.toolTip = "MashKeys · ⌘⌥K toggles music lights"
        makeMenu()
        settings.onChange = { [weak self] in self?.applyRules() }
        settings.onToggleMusic = { [weak self] in self?.toggle() }
        settings.onSyncSong = { [weak self] in self?.syncSong() }
        settings.isMusicEnabled = { [weak self] in self?.enabled ?? false }
        capture.onHit = { [weak self] hit in
            guard let self, self.enabled else { return }
            self.captureStatus = "Listening for beats"; self.animator?.react(to: hit); self.render()
        }
        capture.onSpeech = { [weak self] blocked in
            guard let self, self.enabled else { return }
            if blocked { self.animator?.speechBegan() }
            self.captureStatus = blocked ? "Talking filtered" : "Listening for beats"
            self.render()
        }
        capture.onStatus = { [weak self] text in self?.captureStatus = text; self?.render() }
        capture.onFailure = { [weak self] message in
            guard let self else { return }
            self.enabled = false; self.animator?.stop()
            self.capture.songSync.cancel("Audio capture stopped. Sensitivity unchanged."); self.refreshSongSync()
            self.captureStatus = "Audio access needs attention"; self.render()
            self.showError(message)
        }
        do { shortcut = try GlobalShortcut(); shortcut?.onToggle = { [weak self] in self?.toggle() } }
        catch { showError(error.localizedDescription) }
        updateSnapshot()
        if defaults.bool(forKey: "launchAtLogin") { registerLogin(true) }
        if defaults.bool(forKey: "onboardingDone") {
            if defaults.bool(forKey: "enabledLastSession") { setEnabled(true) }
        } else { showWelcome() }
        if CommandLine.arguments.contains("--settings") { settings.show() }
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
        settings.refreshMusicState()
        toggleItem.state = enabled ? .on : .off
        speechItem.state = defaults.bool(forKey: "speechProtection") ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusLine.title = enabled ? captureStatus + " · System-wide" : "Paused · ⌘⌥K to enable"
        status.button?.appearsDisabled = !enabled
        status.button?.toolTip = "MashKeys · \(enabled ? captureStatus : "Paused") · ⌘⌥K"
    }

    private func updateSnapshot() { rules = RuleSnapshot.load(from: defaults) }

    private func applyRules(fromSync: Bool = false) {
        let before = rules
        updateSnapshot()
        if !fromSync && (before.reaction != rules.reaction || before.speech != rules.speech || before.captureExclusions != rules.captureExclusions) {
            if capture.songSync.status.isBusy { capture.songSync.cancel("Settings changed. Click Sync to song again.") }
            else { capture.songSync.reset() }
            refreshSongSync()
        }
        capture.setSpeechProtection(rules.speech)
        capture.setReaction(rules.reaction)
        animator?.configure(rules.reaction)
        if enabled && before.captureExclusions != rules.captureExclusions {
            capture.start(excluding: rules.captureExclusions, speech: rules.speech, reaction: rules.reaction)
        }
        render()
    }

    private func syncSong() {
        if capture.songSync.status.isBusy {
            capture.songSync.cancel(); refreshSongSync(); return
        }
        guard enabled else { return }
        capture.songSync.begin(source: rules.reaction.source) { [weak self] result in
            guard let self, self.enabled else { return }
            self.defaults.set(result.sensitivity, forKey: "sensitivity")
            self.applyRules(fromSync: true)
            self.settings.refreshTuning(); self.refreshSongSync()
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        syncTimer?.cancel(); syncTimer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.refreshSongSync() }
        timer.resume()
        refreshSongSync()
    }

    private func refreshSongSync() {
        let state = capture.songSync.poll()
        settings.updateSongSync(state)
        if !state.isBusy { syncTimer?.cancel(); syncTimer = nil }
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
            let config = rules
            animator.configure(config.reaction)
            capture.start(excluding: config.captureExclusions, speech: config.speech, reaction: config.reaction)
        } else {
            enabled = false; capture.songSync.cancel(); refreshSongSync()
            capture.stop(); animator?.stop(); captureStatus = "Paused"
        }
        defaults.set(value, forKey: "enabledLastSession")
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncTimer?.cancel(); syncTimer = nil
        enabled = false; capture.finish(); animator?.stop(); shortcut = nil
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
