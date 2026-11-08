import AppKit
import TmuxManagerCore

enum Debug {
    /// Enabled with `--debug`; also turns on the distributed-notification test hook.
    static var enabled = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var debugHook: DebugHook?
    private var originTimer: Timer?
    private var lastSeenOrigin: NSPoint?
    /// False until the first placement is done, so early repaints cannot save a bogus origin.
    private var ready = false
    private var barWindow: BarWindow!
    private var barView: BarView!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Debug.enabled = CommandLine.arguments.contains("--debug")
        NSApp.mainMenu = MainMenu.build()

        model = AppModel()
        model.onChange = { [weak self] in self?.modelChanged() }

        barView = BarView(model: model)
        barView.onAddRequested = { [weak self] in self?.addEntry() }

        barWindow = BarWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: barView.preferredHeight),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        barWindow.contentView = barView
        barWindow.isOpaque = false
        barWindow.backgroundColor = .clear
        barWindow.hasShadow = true
        barWindow.level = .floating
        barWindow.isMovableByWindowBackground = true
        barWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        barWindow.delegate = self
        barWindow.isReleasedWhenClosed = false

        model.start()
        if CommandLine.arguments.contains("--debug") {
            debugHook = DebugHook(model: model)
        }
        refreshBar(initial: true)
        barWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        ready = true
        lastSeenOrigin = barWindow.frame.origin
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.sampleBarOrigin()
        }
        RunLoop.main.add(timer, forMode: .common)
        originTimer = timer

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                              name: NSApplication.didChangeScreenParametersNotification,
                                              object: nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdown()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showBar()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Actions

    @objc func showBar() {
        barWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func addEntry() {
        showBar()
        EntryEditor.present(entry: nil, model: model, on: barWindow)
    }

    // MARK: - Bar geometry

    private func modelChanged() {
        guard ready else { return }
        refreshBar(initial: false)
    }

    private func refreshBar(initial: Bool) {
        barView.reload()
        barView.layoutSubtreeIfNeeded()

        let screen = barWindow.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = barView.fittingBarSize(maxWidth: max(200, visible.width - 40))

        var frame = barWindow.frame
        let placed = initial && model.barOrigin != nil
        if placed {
            frame.origin = NSPoint(x: model.barOrigin!.x, y: model.barOrigin!.y)
            frame.size = size
        } else if initial {
            frame = NSRect(x: visible.maxX - size.width - 20,
                           y: visible.maxY - size.height - 20,
                           width: size.width, height: size.height)
        } else {
            // Keep the top-right corner anchored while the bar grows or shrinks.
            let top = frame.maxY
            let right = frame.maxX
            frame.size = size
            frame.origin = NSPoint(x: right - size.width, y: top - size.height)
        }

        frame = clampBarFrame(frame, visible: visible)
        barWindow.setFrame(frame, display: true)
        if Debug.enabled {
            Log.shared.write("bar set=\(frame) actual=\(barWindow.frame)")
        }

    }

    private func clampBarFrame(_ frame: NSRect, visible: NSRect) -> NSRect {
        var frame = frame
        let allScreens = NSScreen.screens.map(\.visibleFrame)
        guard !allScreens.isEmpty else { return frame }
        let rects = allScreens.map { ScreenRect(x: $0.origin.x, y: $0.origin.y, w: $0.width, h: $0.height) }
        let bar = ScreenRect(x: frame.origin.x, y: frame.origin.y, w: frame.width, h: frame.height)
        let reachable = rects.contains { $0.intersectionArea(bar) > 400 }
        if !reachable {
            let target = allScreens.first { $0.contains(NSEvent.mouseLocation) } ?? visible
            frame.origin = NSPoint(x: target.maxX - frame.width - 20,
                                   y: target.maxY - frame.height - 20)
        }
        let minX = rects.map(\.x).min() ?? 0
        let maxX = rects.map { $0.x + $0.w }.max() ?? visible.maxX
        let minY = rects.map(\.y).min() ?? 0
        let maxY = rects.map { $0.y + $0.h }.max() ?? visible.maxY
        frame.origin.x = min(max(frame.origin.x, minX - 40), maxX - frame.width + 40)
        frame.origin.y = min(max(frame.origin.y, minY), maxY - frame.height)
        return frame
    }

    func applyDebugFrame(_ frame: NSRect) {
        barWindow.setFrame(frame, display: true)
        Log.shared.write("debug frame set=\(frame) actual=\(barWindow.frame)")
    }

    @objc private func screensChanged() {
        refreshBar(initial: false)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        sampleBarOrigin()
    }

    /// Delegate notifications are not reliable for every kind of move, so the origin
    /// is also sampled once a second.
    private func sampleBarOrigin() {
        guard ready, let model, let barWindow else { return }
        let origin = barWindow.frame.origin
        guard origin != lastSeenOrigin else { return }
        lastSeenOrigin = origin
        if Debug.enabled { Log.shared.write("bar moved to \(origin)") }
        model.setBarOrigin(BarOrigin(x: origin.x, y: origin.y))
        lastSeenOrigin = barWindow.frame.origin
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About TmuxManager",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let add = NSMenuItem(title: "Add Host:Session…", action: #selector(AppDelegate.addEntry), keyEquivalent: "n")
        appMenu.addItem(add)
        let show = NSMenuItem(title: "Show Bar", action: #selector(AppDelegate.showBar), keyEquivalent: "0")
        appMenu.addItem(show)
        let openConfig = NSMenuItem(title: "Open config.json", action: #selector(Actions.openConfig), keyEquivalent: "")
        openConfig.target = Actions.shared
        appMenu.addItem(openConfig)
        let openLog = NSMenuItem(title: "Open Log", action: #selector(Actions.openLog), keyEquivalent: "")
        openLog.target = Actions.shared
        appMenu.addItem(openLog)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TmuxManager",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit TmuxManager",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }
}

final class Actions: NSObject {
    static let shared = Actions()

    @objc func openConfig() {
        NSWorkspace.shared.open(Paths.default.configURL)
    }

    @objc func openLog() {
        let url = Paths.default.logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }
}
