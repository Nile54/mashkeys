import AppKit

final class SettingsWindow: NSWindowController {
    var onChange: (() -> Void)?
    var onToggleMusic: (() -> Void)?
    var onSyncSong: (() -> Void)?
    var isMusicEnabled: (() -> Bool)?
    private let defaults = UserDefaults.standard
    private var apps = NSStackView()
    private var musicButton = NSButton()
    private var speechButton = NSButton()
    private var sourcePopup = NSPopUpButton()
    private var sensitivitySlider = NSSlider()
    private var sensitivityValue = NSTextField(labelWithString: "")
    private var syncButton = NSButton()
    private var automaticButton = NSButton()
    private var lastSyncState: SongSyncStatus = .ready
    private var syncProgress = NSProgressIndicator()
    private var syncDescription = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MashKeys Settings"
        window.center()
        super.init(window: window)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        refreshApps(); refreshMusicState()
        refreshTuning(); refreshAutomation()
        speechButton.state = defaults.object(forKey: "speechProtection") as? Bool == false ? .off : .on
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshMusicState() {
        let enabled = isMusicEnabled?() == true
        musicButton.state = enabled ? .on : .off
        syncButton.isEnabled = enabled
    }

    func refreshAutomation() {
        automaticButton.state = defaults.bool(forKey: "autoSyncMusic") ? .on : .off
        updateSongSync(lastSyncState)
    }

    func updateSongSync(_ state: SongSyncStatus) {
        lastSyncState = state
        syncButton.title = state.isBusy ? "Cancel sync" : "Sync to song"
        syncProgress.isHidden = !state.isBusy
        switch state {
        case .ready:
            syncDescription.stringValue = defaults.bool(forKey: "autoSyncMusic")
                ? "Auto-sync starts with music after quiet gaps and rechecks continuous playback."
                : "Play music, then sync. Listens for 8 seconds in the selected beat source."
        case .listening(let progress):
            syncProgress.doubleValue = progress
            syncDescription.stringValue = "Listening… \(Int(min(8, progress * 8))) / 8 seconds. Keep your music playing."
        case .analysing:
            syncProgress.doubleValue = 1
            syncDescription.stringValue = "Choosing sensitivity for clear, smooth pulses…"
        case .finished(let percentage):
            syncDescription.stringValue = "Synced to \(percentage)% from this section. You can still fine-tune the slider."
        case .message(let message): syncDescription.stringValue = message
        }
    }

    private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        result.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return result
    }

    private func build() {
        guard let view = window?.contentView else { return }
        let title = label("Your music. Your rules.", size: 22, bold: true)
        title.frame = NSRect(x: 22, y: 644, width: 435, height: 32); view.addSubview(title)
        let tuning = label("0–100% light · smooth, music-paced recovery")
        tuning.textColor = .secondaryLabelColor
        tuning.frame = NSRect(x: 22, y: 614, width: 435, height: 26); view.addSubview(tuning)
        musicButton = NSButton(checkboxWithTitle: "Music lights — all apps and websites", target: self, action: #selector(musicChanged))
        musicButton.frame = NSRect(x: 22, y: 578, width: 435, height: 24); view.addSubview(musicButton)
        speechButton = NSButton(checkboxWithTitle: "Ignore talking; keep singing and rap", target: self, action: #selector(speechChanged))
        speechButton.frame = NSRect(x: 22, y: 544, width: 435, height: 24); view.addSubview(speechButton)
        let privacy = label("Speech detection stays on this Mac. Music starts immediately; confirmed talking is filtered after a brief recognition delay.")
        privacy.textColor = .secondaryLabelColor
        privacy.frame = NSRect(x: 22, y: 494, width: 435, height: 42); view.addSubview(privacy)
        let sourceLabel = label("Beat source", bold: true)
        sourceLabel.frame = NSRect(x: 22, y: 457, width: 90, height: 24); view.addSubview(sourceLabel)
        sourcePopup = NSPopUpButton(frame: NSRect(x: 117, y: 455, width: 340, height: 28), pullsDown: false)
        sourcePopup.addItems(withTitles: BeatSource.allCases.map(\.title))
        sourcePopup.target = self; sourcePopup.action = #selector(sourceChanged)
        sourcePopup.setAccessibilityLabel("Beat source")
        view.addSubview(sourcePopup)
        let sensitivityLabel = label("Sensitivity", bold: true)
        sensitivityLabel.frame = NSRect(x: 22, y: 419, width: 170, height: 24); view.addSubview(sensitivityLabel)
        sensitivityValue.alignment = .right
        sensitivityValue.frame = NSRect(x: 325, y: 419, width: 132, height: 24); view.addSubview(sensitivityValue)
        sensitivitySlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: self, action: #selector(sensitivityChanged))
        sensitivitySlider.isContinuous = true
        sensitivitySlider.frame = NSRect(x: 22, y: 388, width: 435, height: 24)
        sensitivitySlider.setAccessibilityLabel("Sensitivity")
        view.addSubview(sensitivitySlider)
        let fewer = label("Fewer pulses", size: 11)
        fewer.frame = NSRect(x: 22, y: 366, width: 180, height: 20); view.addSubview(fewer)
        let more = label("More pulses", size: 11); more.alignment = .right
        more.frame = NSRect(x: 277, y: 366, width: 180, height: 20); view.addSubview(more)
        let sensitivityHelp = label("Higher sensitivity picks up softer hits and recovers sooner. 50% keeps the original tuning.", size: 12)
        sensitivityHelp.textColor = .secondaryLabelColor
        sensitivityHelp.frame = NSRect(x: 22, y: 329, width: 435, height: 34); view.addSubview(sensitivityHelp)
        syncButton = NSButton(title: "Sync to song", target: self, action: #selector(syncSong))
        syncButton.bezelStyle = .rounded
        syncButton.frame = NSRect(x: 22, y: 291, width: 150, height: 30); view.addSubview(syncButton)
        syncProgress.isIndeterminate = false; syncProgress.minValue = 0; syncProgress.maxValue = 1
        syncProgress.style = .bar; syncProgress.isHidden = true
        syncProgress.frame = NSRect(x: 184, y: 299, width: 273, height: 12); view.addSubview(syncProgress)
        automaticButton = NSButton(checkboxWithTitle: "Auto-sync new music", target: self, action: #selector(automaticChanged))
        automaticButton.frame = NSRect(x: 22, y: 254, width: 435, height: 24); view.addSubview(automaticButton)
        syncDescription.font = .systemFont(ofSize: 11); syncDescription.textColor = .secondaryLabelColor
        syncDescription.frame = NSRect(x: 22, y: 215, width: 435, height: 32); view.addSubview(syncDescription)
        updateSongSync(.ready)
        let sites = label("YouTube and other websites work automatically. Website-specific exclusions are unavailable; you can ignore whole apps below.")
        sites.textColor = .secondaryLabelColor
        sites.frame = NSRect(x: 22, y: 177, width: 435, height: 36); view.addSubview(sites)
        let appTitle = label("Ignore whole apps (checked = ignored)", bold: true)
        appTitle.frame = NSRect(x: 22, y: 145, width: 435, height: 24); view.addSubview(appTitle)
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 48, width: 435, height: 90))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        apps.orientation = .vertical; apps.alignment = .leading; apps.spacing = 7
        apps.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        apps.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = apps
        NSLayoutConstraint.activate([apps.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        view.addSubview(scroll)
        let footer = label("Global toggle: ⌘⌥K   ·   No recording. No uploads.", size: 11)
        footer.textColor = .secondaryLabelColor
        footer.frame = NSRect(x: 22, y: 17, width: 435, height: 20); view.addSubview(footer)
    }

    private func refreshApps() {
        for view in apps.arrangedSubviews { apps.removeArrangedSubview(view); view.removeFromSuperview() }
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

    func refreshTuning() {
        let tuning = ReactionSettings.load(from: defaults)
        sourcePopup.selectItem(at: BeatSource.allCases.firstIndex(of: tuning.source) ?? 0)
        sensitivitySlider.doubleValue = tuning.sensitivity * 100
        updateSensitivityLabel()
    }

    private func updateSensitivityLabel() {
        let percentage = Int(sensitivitySlider.doubleValue.rounded())
        sensitivityValue.stringValue = percentage == 50 ? "50% (default)" : "\(percentage)%"
    }

    @objc private func sourceChanged() {
        let index = sourcePopup.indexOfSelectedItem
        guard BeatSource.allCases.indices.contains(index) else { return }
        defaults.set(BeatSource.allCases[index].rawValue, forKey: "beatSource")
        onChange?()
    }

    @objc private func sensitivityChanged() {
        defaults.set(sensitivitySlider.doubleValue / 100, forKey: "sensitivity")
        updateSensitivityLabel(); onChange?()
    }

    @objc private func automaticChanged() {
        defaults.set(automaticButton.state == .on, forKey: "autoSyncMusic"); onChange?()
    }

    @objc private func syncSong() { onSyncSong?() }

    @objc private func musicChanged() { onToggleMusic?(); refreshMusicState() }
    @objc private func speechChanged() { defaults.set(speechButton.state == .on, forKey: "speechProtection"); onChange?() }
    @objc private func appChanged(_ button: NSButton) {
        guard let id = button.identifier?.rawValue else { return }
        var blocked = Set(defaults.stringArray(forKey: "blockedApplications") ?? [])
        if button.state == .on { blocked.insert(id) } else { blocked.remove(id) }
        defaults.set(blocked.sorted(), forKey: "blockedApplications"); onChange?()
    }
}
