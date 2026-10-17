import AppKit
import AVFoundation
import ServiceManagement
import XlateCore

/// Menu bar app: waits for Teams to play audio, taps it, and shows captions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let enabledKey = "enabled"

    private let target: String
    private let devMode: Bool
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let setupItem = NSMenuItem(title: "Set Up Models…", action: #selector(setUpModels), keyEquivalent: "")
    private let persistentItem = NSMenuItem(title: "Keep Captions Visible", action: #selector(togglePersistent),
                                            keyEquivalent: "")
    private let historyMenu = NSMenu()
    private let sizeMenu = NSMenu()
    private let panel = PillPanel()
    private let translator = AppleTranslator()
    private var monitor: WakeMonitor?
    private var watching: Task<Void, Never>?
    private var tap: ProcessTap?
    private var tapped: Set<AudioObjectID> = []
    private var captions: Task<Void, Never>?
    private var ready = false

    /// `devMode` mutes the tapped app and prints captions, for testing
    /// against a clip played by `--dev play` instead of a real call.
    init(target: String = TargetApp.teamsBundleID, devMode: Bool = false) {
        self.target = target
        self.devMode = devMode
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
    }

    private var transcriber: any Transcriber {
        if let dir = ProcessInfo.processInfo.environment["XLATE_DEBUG_AUDIO_DIR"] {
            return DumpingTranscriber(base: WhisperTranscriber.shared, directory: URL(fileURLWithPath: dir))
        }
        return WhisperTranscriber.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Xlate")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        enabledItem.target = self
        menu.addItem(enabledItem)
        let reset = NSMenuItem(title: "Reset Caption Position", action: #selector(resetPill), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        persistentItem.target = self
        menu.addItem(persistentItem)
        for lines in PillPanel.historyChoices {
            let title = lines == 0 ? "None" : lines == 1 ? "1 Line" : "\(lines) Lines"
            let choice = NSMenuItem(title: title, action: #selector(chooseHistory(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = lines
            historyMenu.addItem(choice)
        }
        let history = NSMenuItem(title: "Caption History", action: nil, keyEquivalent: "")
        history.submenu = historyMenu
        menu.addItem(history)
        for size in CaptionSize.allCases {
            let choice = NSMenuItem(title: size.title, action: #selector(chooseSize(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = size.rawValue
            sizeMenu.addItem(choice)
        }
        let sizes = NSMenuItem(title: "Caption Size", action: nil, keyEquivalent: "")
        sizes.submenu = sizeMenu
        menu.addItem(sizes)
        loginItem.target = self
        menu.addItem(loginItem)
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Xlate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        refreshMenu()
        Task { await start() }
    }

    private func refreshMenu() {
        enabledItem.state = UserDefaults.standard.bool(forKey: Self.enabledKey) ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        persistentItem.state = panel.persistent ? .on : .off
        for choice in historyMenu.items { choice.state = choice.tag == panel.historyLines ? .on : .off }
        for choice in sizeMenu.items {
            choice.state = choice.representedObject as? String == panel.captionSize.rawValue ? .on : .off
        }
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
        if devMode { print("status: \(text)") }
    }

    /// Fails closed: if either model is missing, never start the tap.
    private func start() async {
        setStatus("Loading models…")
        do {
            if case .modelMissing = try await WhisperTranscriber.shared.prepare() {
                return setStatus("Speech model missing")
            }
            if case .modelMissing = try await translator.prepare() {
                return setStatus("Translation model missing")
            }
        } catch {
            return setStatus("Model failed to load")
        }
        ready = true
        startWatching()
    }

    private func startWatching() {
        stopWatching()
        guard ready, UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            return setStatus(ready ? "Disabled" : statusLine.title)
        }
        let monitor = WakeMonitor(bundlePrefix: target)
        self.monitor = monitor
        watching = Task { [weak self] in
            for await state in monitor.states {
                self?.apply(state)
            }
        }
    }

    private func stopWatching() {
        watching?.cancel()
        watching = nil
        monitor = nil
        stopTap()
    }

    private func apply(_ state: WakeState) {
        if devMode { print("wake: \(state)") }
        switch state {
        case .waitingForTarget:
            stopTap()
            setStatus("Waiting for Teams")
        case .idle:
            stopTap()
            setStatus("Idle")
        case .active(let ids):
            if WakeMachine.needsRetap(tapped: tapped, wanted: ids) { startTap(ids) }
        }
    }

    private func startTap(_ ids: Set<AudioObjectID>) {
        stopTap()
        do {
            let tap = try ProcessTap(processes: Array(ids), muted: devMode)
            self.tap = tap
            tapped = ids
            let pipeline = CaptionPipeline(transcriber: transcriber, translator: translator)
            let stream = pipeline.run(tap.chunks)
            captions = Task { [weak self] in
                for await caption in stream {
                    self?.panel.show(caption)
                    if self?.devMode == true { print("caption: \(caption.english) | \(caption.portuguese)") }
                }
                // The tap ended without stopTap() (a device change it couldn't
                // recover from). Forget it so the next wake poll retaps.
                if !Task.isCancelled { self?.tapLost() }
            }
            setStatus("Listening")
        } catch {
            setStatus("Can't capture Teams audio")
        }
    }

    private func tapLost() {
        tap = nil
        tapped = []
        setStatus("Reconnecting…")
    }

    private func stopTap() {
        captions?.cancel()
        captions = nil
        tap?.stop()
        tap = nil
        tapped = []
        panel.endSession()
    }

    @objc private func toggleEnabled() {
        let enabled = !UserDefaults.standard.bool(forKey: Self.enabledKey)
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        refreshMenu()
        if enabled { startWatching() } else {
            stopWatching()
            setStatus("Disabled")
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            setStatus("Couldn't change login item")
        }
        refreshMenu()
    }

    @objc private func togglePersistent() {
        panel.persistent.toggle()
        refreshMenu()
    }

    @objc private func chooseHistory(_ sender: NSMenuItem) {
        panel.historyLines = sender.tag
        refreshMenu()
    }

    /// Shows a sample caption so the new size is visible right away.
    @objc private func chooseSize(_ sender: NSMenuItem) {
        panel.captionSize = CaptionSize(saved: sender.representedObject as? String)
        refreshMenu()
        panel.show(Caption(english: "Captions will appear here.", portuguese: "As legendas vão aparecer aqui."))
    }

    @objc private func resetPill() {
        panel.resetPosition()
        panel.show(Caption(english: "Captions will appear here.", portuguese: "As legendas vão aparecer aqui."))
    }

    /// The only action that downloads anything. The menu closes on click, so
    /// every outcome is reported in a dialog, and progress shows in this item.
    @objc private func setUpModels() {
        Task {
            let step = ModelSetup.nextStep(speechInstalled: WhisperTranscriber.isInstalled,
                                           translationInstalled: await AppleTranslator.isInstalled())
            switch step {
            case .allReady:
                // Restarting would interrupt captions mid-call, so only
                // start if a missing model stopped us earlier.
                if !ready { await start() }
                alert("Models are ready",
                      "The speech and translation models are installed on this Mac. Captions appear when Teams plays Portuguese.")
            case .downloadSpeech:
                await downloadSpeechModel()
            case .installTranslation:
                promptForTranslation()
            }
        }
    }

    private func downloadSpeechModel() async {
        setupItem.isEnabled = false
        setupItem.title = "Downloading Speech Model… 0%"
        defer {
            setupItem.title = "Set Up Models…"
            setupItem.isEnabled = true
        }
        do {
            try await WhisperTranscriber.installModel { fraction in
                Task { @MainActor [weak self] in
                    self?.setupItem.title = String(format: "Downloading Speech Model… %.0f%%", fraction * 100)
                }
            }
        } catch {
            setStatus("Speech model download failed")
            alert("Speech model download failed", error.localizedDescription)
            return
        }
        if await AppleTranslator.isInstalled() {
            await start()
            alert("Models are ready", "The speech model is installed. Captions appear when Teams plays Portuguese.")
        } else {
            promptForTranslation()
        }
    }

    /// Apple's translation languages install from System Settings.
    private func promptForTranslation() {
        setStatus("Translation model missing")
        let open = alert("Install Portuguese for translation",
                         "In System Settings, open General → Language & Region → Translation Languages and download Portuguese (Brazil). Then choose Set Up Models… again.",
                         buttons: ["Open System Settings", "Later"])
        if open {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
        }
    }

    /// Shows a dialog in front of other apps. Returns true for the first button.
    @discardableResult
    private func alert(_ title: String, _ message: String, buttons: [String] = ["OK"]) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Debug only (XLATE_DEBUG_AUDIO_DIR): writes each utterance as a WAV before
/// transcribing it. Never active unless that variable is set.
struct DumpingTranscriber: Transcriber {
    let base: any Transcriber
    let directory: URL

    func prepare() async throws -> EngineStatus { try await base.prepare() }

    func transcribe(_ utterance: Utterance) async throws -> Transcript {
        let name = "utterance-\(Int(Date().timeIntervalSince1970 * 1000)).wav"
        try? DevCommands.writeWAV(utterance.samples, to: directory.appendingPathComponent(name))
        return try await base.transcribe(utterance)
    }
}
