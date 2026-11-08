import AppKit
import TmuxManagerCore

/// Test hook: lets a shell drive the app without clicking, e.g.
///   notifyutil -p com.cyb.tmuxmanager.debug  (with userInfo: action=open entry=<id>)
/// Only installed when the app is launched with `--debug`.
final class DebugHook {
    static let notification = Notification.Name("com.cyb.tmuxmanager.debug")

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        DistributedNotificationCenter.default().addObserver(
            forName: Self.notification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handle(note)
        }
        Log.shared.write("debug action channel enabled")
    }

    private func handle(_ note: Notification) {
        let info = (note.userInfo ?? [:]).reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        let action = info["action"] ?? ""
        Log.shared.write("debug action \(action) \(info)")
        if action == "sizebar", let x = Double(info["x"] ?? ""), let y = Double(info["y"] ?? ""),
           let w = Double(info["w"] ?? ""), let h = Double(info["h"] ?? "") {
            (NSApp.delegate as? AppDelegate)?.applyDebugFrame(NSRect(x: x, y: y, width: w, height: h))
            return
        }
        if action == "add", let json = info["json"], let data = json.data(using: .utf8),
           let entry = try? JSONDecoder().decode(Entry.self, from: data) {
            _ = model.add(entry, thenProbe: true)
            return
        }
        if action == "sheet" {
            if let bar = NSApp.windows.first(where: { $0 is BarWindow }) {
                EntryEditor.present(entry: nil, model: model, on: bar)
            }
            return
        }
        if action == "closesheet" {
            for window in NSApp.windows {
                if let parent = window.sheetParent {
                    parent.endSheet(window)
                }
            }
            return
        }
        if action == "windows" {
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier {
                let num = w[kCGWindowNumber as String] ?? "?"
                let bounds = w[kCGWindowBounds as String] ?? "?"
                Log.shared.write("debug window num=\(num) cg=\(bounds)")
            }
            return
        }
        guard let entryID = info["entry"], let entry = model.config.entry(id: entryID) else {
            if action == "reload" { model.start() }
            if action == "capture" { model.captureFrames() }
            return
        }
        switch action {
        case "open": model.open(entry)
        case "reconnect": model.reconnect(entry)
        case "close": model.closeConsole(entry)
        case "remove": model.remove(entry, killRemoteSession: info["kill"] == "1")
        case "update":
            if let json = info["json"], let data = json.data(using: .utf8),
               var patch = try? JSONDecoder().decode(Entry.self, from: data) {
                patch.id = entry.id
                _ = model.update(patch)
            }
        default:
            break
        }
    }
}
