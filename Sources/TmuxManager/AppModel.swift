import AppKit
import TmuxManagerCore

/// Owns config, wrapper state, frames and all entry operations.
final class AppModel {
    let paths: Paths
    private let configStore: ConfigStore
    private let stateStore: StateStore
    private let controller: TerminalController
    private let watcher: ConfigWatcher

    private(set) var config: Config
    private(set) var states: [String: WrapperState] = [:]
    private(set) var busy: Set<String> = []
    private(set) var errorMessage: String?
    private(set) var notes: [String] = []

    /// entry id -> last frame seen while the window was open
    private var frames: [String: Frame] = [:]
    private var frameSaveWork: DispatchWorkItem?
    private var originSaveWork: DispatchWorkItem?
    private var errorGeneration = 0
    private var stateTimer: Timer?
    private var frameTimer: Timer?
    private var suppressConfigReload = 0
    private var lastConfigStamp: ConfigStamp?

    private struct ConfigStamp: Equatable {
        var modified: TimeInterval
        var size: Int
        var inode: UInt64
    }

    var onChange: (() -> Void)?

    init(paths: Paths = .default) {
        self.paths = paths
        self.configStore = ConfigStore(paths: paths)
        self.stateStore = StateStore(paths: paths)
        self.controller = TerminalController(paths: paths)
        self.watcher = ConfigWatcher(paths: paths)
        self.config = Config()

        switch configStore.load() {
        case .loaded(let config, let notes):
            self.config = config
            self.notes = notes
        case .empty:
            self.config = Config()
        case .failed(let message):
            self.config = Config()
            self.errorMessage = message
        }
    }

    // MARK: - Lifecycle

    func start() {
        Log.shared.configure(paths)
        ProfileInstaller.install()
        do {
            try paths.prepareDirectories()
        } catch {
            show(error: "Cannot create \(paths.supportDir.path): \(error.localizedDescription)")
        }
        if let resource = Bundle.main.url(forResource: "attach", withExtension: "sh") {
            do {
                let changed = try WrapperInstaller.install(source: resource, paths: paths)
                Log.shared.write("attach.sh installed (changed=\(changed)) at \(paths.attachScriptURL.path)")
            } catch {
                show(error: "Cannot install attach.sh: \(error.localizedDescription)")
            }
        } else {
            Log.shared.write("attach.sh missing from app bundle (\(Bundle.main.bundlePath))")
        }
        persistEnvFiles()
        lastConfigStamp = configStamp()
        watcher.onChange = { [weak self] in self?.reloadFromDisk() }
        watcher.start()
        refreshStates()
        startStateTimer()
        startFrameTimer()
        if !notes.isEmpty {
            show(error: notes.joined(separator: "  "))
            notes = []
        }
        onChange?()
    }

    func shutdown() {
        stateTimer?.invalidate()
        frameTimer?.invalidate()
        watcher.stop()
        captureFrames()
        storeFramesNow()
    }

    /// Applies captured frames to config and writes it immediately (used on quit).
    private func storeFramesNow() {
        frameSaveWork?.cancel()
        var changed = false
        for (entryID, frame) in frames {
            guard let index = config.entries.firstIndex(where: { $0.id == entryID }) else { continue }
            if config.entries[index].frame != frame {
                config.entries[index].frame = frame
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Queries

    func isActive(_ entry: Entry) -> Bool { states[entry.id] != nil }
    func isBusy(_ entry: Entry) -> Bool { busy.contains(entry.id) }

    func liveState(_ entry: Entry) -> WrapperState? { states[entry.id] }

    // MARK: - Operations

    func open(_ entry: Entry) {
        // Always use the newest stored entry: the bar button may hold a stale copy
        // (frame flushes do not trigger a UI rebuild), and the restore frame must
        // come from current config.
        let entry = config.entry(id: entry.id) ?? entry
        guard !busy.contains(entry.id) else { return }
        if let state = states[entry.id], let guid = state.itermSessionID, !guid.isEmpty {
            // Mark busy for the whole probe too: without it, a second fast click
            // starts a second activate, and both completions would open a window.
            busy.insert(entry.id)
            onChange?()
            controller.activate(guid: guid) { [weak self] found in
                guard let self else { return }
                if found {
                    self.busy.remove(entry.id)
                    Log.shared.write("activated existing window for \(entry.address)")
                    self.captureFrames()
                    self.flushFrames()
                } else {
                    Log.shared.write("window for \(entry.address) is gone; opening a new one")
                    self.states[entry.id] = nil
                    // Hand over to createWindow: clear the probe's busy mark in
                    // the same main-thread turn, so createWindow's guard admits
                    // this call but still rejects a stale duplicate completion.
                    self.busy.remove(entry.id)
                    self.createWindow(for: entry)
                }
                self.onChange?()
            }
            return
        }
        createWindow(for: entry)
    }

    private func createWindow(for entry: Entry) {
        // Defensive: callers serialize on the main thread, but the activate
        // completion above can land here twice for one double-click.
        guard !busy.contains(entry.id) else { return }
        busy.insert(entry.id)
        onChange?()
        let frame = clampedRestoreFrame(for: entry)
        controller.createWindow(entry: entry, frame: frame) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // busy stays set until the wrapper's state file confirms the
                // window; clearing it here would leave a gap in which a fast
                // click opens a second window.
                self.waitForState(of: entry.id, attempts: 30)
            case .failure(let error):
                self.busy.remove(entry.id)
                self.show(error: error.localizedDescription)
            }
            self.onChange?()
        }
    }

    /// The wrapper writes its state file right after launching ssh. Also the
    /// point where `busy` is cleared on the open path: the console counts as
    /// open only once the state file exists.
    private func waitForState(of entryID: String, attempts: Int) {
        guard attempts > 0 else {
            busy.remove(entryID)
            show(error: "The console window opened but never reported back. Check \(paths.logURL.path).")
            onChange?()
            return
        }
        if states[entryID] != nil {
            busy.remove(entryID)
            onChange?()
            return
        }
        if config.entry(id: entryID) == nil {
            // The entry was removed while opening; stop waiting quietly.
            busy.remove(entryID)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.refreshStates()
            if self.states[entryID] != nil {
                self.busy.remove(entryID)
                self.onChange?()
            } else {
                self.waitForState(of: entryID, attempts: attempts - 1)
            }
        }
    }

    func reconnect(_ entry: Entry) {
        let entry = config.entry(id: entry.id) ?? entry
        guard let state = states[entry.id] else { return }
        captureFrames()
        flushFrames()
        if kill(state.wrapperPid, SIGUSR1) == 0 {
            Log.shared.write("sent reconnect to \(entry.address) (pid \(state.wrapperPid))")
        } else {
            show(error: "Could not signal the console process for \(entry.displayName).")
        }
    }

    func add(_ entry: Entry, thenProbe: Bool = true) -> Bool {
        if let message = EntryValidator.message(for: EntryValidator.problems(for: entry, all: config.entries)) {
            show(error: message)
            return false
        }
        config.entries.append(entry)
        save()
        onChange?()
        if thenProbe {
            probe(entry: entry, alertOnFailure: true)
        }
        return true
    }

    func update(_ entry: Entry) -> Bool {
        guard let index = config.entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        var candidate = entry
        candidate.frame = config.entries[index].frame
        if let message = EntryValidator.message(for: EntryValidator.problems(for: candidate,
                                                                             all: config.entries)) {
            show(error: message)
            return false
        }
        config.entries[index] = candidate
        save()
        onChange?()
        return true
    }

    func remove(_ entry: Entry, killRemoteSession: Bool) {
        if let state = states[entry.id] {
            kill(state.wrapperPid, SIGTERM)
            if let guid = state.itermSessionID, !guid.isEmpty {
                controller.closeWindow(guid: guid)
            }
            states[entry.id] = nil
            try? FileManager.default.removeItem(at: paths.stateURL(entryID: entry.id))
        }
        config.entries.removeAll { $0.id == entry.id }
        frames[entry.id] = nil
        busy.remove(entry.id)
        save()
        onChange?()
        if killRemoteSession {
            killRemote(entry)
        }
    }

    /// Closes an open console window: captures the window's current frame and
    /// persists it immediately, then tears the connection down. The remote tmux
    /// session survives; only the local window and ssh die.
    func closeConsole(_ entry: Entry) {
        guard let state = states[entry.id], !busy.contains(entry.id) else { return }
        captureFrames()
        storeFramesNow()
        kill(state.wrapperPid, SIGTERM)
        if let guid = state.itermSessionID, !guid.isEmpty {
            controller.closeWindow(guid: guid)
        }
        states[entry.id] = nil
        try? FileManager.default.removeItem(at: paths.stateURL(entryID: entry.id))
        Log.shared.write("closed console for \(entry.address)")
        onChange?()
    }

    private func killRemote(_ entry: Entry) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
            args += entry.sshOptions
            args += [entry.host, "\(entry.effectiveTmuxPath) kill-session -t \(Quote.shell(entry.session))"]
            let result = Shell.run("/usr/bin/ssh", args, timeout: 30)
            DispatchQueue.main.async {
                if result.status == 0 {
                    Log.shared.write("killed remote session \(entry.address)")
                } else {
                    let text = result.combined
                    self?.show(error: "Could not kill remote session \(entry.address): "
                               + (text.isEmpty ? "ssh exited \(result.status)" : text))
                }
            }
        }
    }

    func probe(entry: Entry, alertOnFailure: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SSHProbe.check(host: entry.host, sshOptions: entry.sshOptions)
            DispatchQueue.main.async {
                Log.shared.write("probe \(entry.host): \(result.summary)")
                guard alertOnFailure, let self else { return }
                switch result.kind {
                case .failed:
                    let alert = NSAlert()
                    alert.messageText = "Saved, but the connection test failed"
                    alert.informativeText = "\(entry.displayName): \(result.summary)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Keep Entry")
                    alert.addButton(withTitle: "Remove Entry")
                    if alert.runModal() == .alertSecondButtonReturn {
                        self.remove(entry, killRemoteSession: false)
                    }
                case .tmuxMissing:
                    self.show(error: "\(entry.displayName): connected, but tmux was not found on \(entry.host).")
                case .unverified, .ok:
                    break
                }
            }
        }
    }

    // MARK: - Frames

    private func clampedRestoreFrame(for entry: Entry) -> Frame? {
        guard let saved = entry.frame, saved.isUsable else { return nil }
        let screens = NSScreen.screens.map { $0.visibleFrame }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rects = screens.map { ScreenRect(x: $0.origin.x, y: $0.origin.y,
                                             w: $0.size.width, h: $0.size.height) }
        return FrameClamp.clamp(saved, screens: rects, primaryHeight: primaryHeight)
    }

    private func startFrameTimer() {
        frameTimer?.invalidate()
        let interval = max(1, config.ui.frameCaptureIntervalSeconds)
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tickFrames()
        }
        frameTimer?.tolerance = interval * 0.2
        RunLoop.main.add(frameTimer!, forMode: .common)
    }

    private func tickFrames() {
        captureFrames()
        flushFrames()
    }

    /// Reads all iTerm2 window frames and stores those belonging to tracked consoles.
    func captureFrames() {
        guard !states.isEmpty else { return }
        var guidToEntry: [String: String] = [:]
        for (entryID, state) in states {
            if let guid = state.itermSessionID, !guid.isEmpty {
                guidToEntry[guid.uppercased()] = entryID
            }
        }
        guard !guidToEntry.isEmpty else { return }
        for session in controller.frames() {
            guard let entryID = guidToEntry[session.guid.uppercased()] else { continue }
            if session.miniaturized { continue }
            guard session.frame.isUsable else { continue }
            if frames[entryID] != session.frame {
                frames[entryID] = session.frame
            }
        }
    }

    /// Writes captured frames into config.json (debounced).
    private func flushFrames() {
        var changed = false
        for (entryID, frame) in frames {
            guard let index = config.entries.firstIndex(where: { $0.id == entryID }) else { continue }
            if config.entries[index].frame != frame {
                config.entries[index].frame = frame
                changed = true
            }
        }
        guard changed else { return }
        frameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        frameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        // Refresh the bar so entry snapshots (e.g. saved frames) stay current.
        onChange?()
    }

    // MARK: - State / config plumbing

    private func startStateTimer() {
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let before = self.states
            self.refreshStates()
            if before != self.states { self.onChange?() }

            // Catches in-place edits, which do not produce directory events.
            if let stamp = self.configStamp(), stamp != self.lastConfigStamp {
                self.lastConfigStamp = stamp
                self.reloadFromDisk()
            }
        }
        RunLoop.main.add(stateTimer!, forMode: .common)
    }

    private func refreshStates() {
        let live = stateStore.liveStates()
        states = live.filter { config.entry(id: $0.key) != nil }
        frames = frames.filter { states[$0.key] != nil || config.entry(id: $0.key) != nil }
    }

    private func persistEnvFiles() {
        do {
            try configStore.writeEnvFiles(for: config)
            configStore.cleanupOrphans(config: config)
        } catch {
            show(error: "Cannot write entry files: \(error.localizedDescription)")
        }
    }

    func save() {
        suppressConfigReload += 1
        do {
            try configStore.save(config)
            lastConfigStamp = configStamp()
        } catch {
            show(error: "Cannot save config.json: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.suppressConfigReload = max(0, (self?.suppressConfigReload ?? 0) - 1)
        }
    }

    private func configStamp() -> ConfigStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: paths.configURL.path) else {
            return nil
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return ConfigStamp(modified: modified, size: size, inode: inode)
    }

    private func reloadFromDisk() {
        guard suppressConfigReload == 0 else { return }
        switch configStore.load() {
        case .loaded(let config, _):
            guard config != self.config else { return }
            Log.shared.write("config.json changed on disk; reloading")
            self.config = config
            persistEnvFiles()
            refreshStates()
            startFrameTimer()
            onChange?()
        case .empty:
            guard !self.config.entries.isEmpty else { return }
            self.config = Config()
            persistEnvFiles()
            refreshStates()
            onChange?()
        case .failed(let message):
            show(error: message)
        }
    }

    // MARK: - Bar geometry

    var barOrigin: BarOrigin? { config.ui.barOrigin }

    func setBarOrigin(_ origin: BarOrigin) {
        guard config.ui.barOrigin != origin else { return }
        config.ui.barOrigin = origin
        originSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        originSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Errors

    func show(error message: String) {
        errorMessage = message
        errorGeneration += 1
        let generation = errorGeneration
        Log.shared.write("error: \(message)")
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.errorGeneration == generation else { return }
            self.errorMessage = nil
            self.onChange?()
        }
    }

    func dismissError() {
        errorMessage = nil
        errorGeneration += 1
        onChange?()
    }
}
