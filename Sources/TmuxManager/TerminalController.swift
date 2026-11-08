import AppKit
import TmuxManagerCore

/// Talks to iTerm2. Window creation/activation go through `osascript` on a private
/// queue so the UI never blocks; the frequent frame poll runs in-process.
final class TerminalController {
    private let paths: Paths
    private let queue = DispatchQueue(label: "com.cyb.tmuxmanager.iterm", qos: .userInitiated)
    private var frameScript: NSAppleScript?
    private static let iTermBundleID = "com.googlecode.iterm2"

    init(paths: Paths) {
        self.paths = paths
    }

    // MARK: - Windows

    func createWindow(entry: Entry,
                      frame: Frame?,
                      completion: @escaping (Result<Void, NSError>) -> Void) {
        queue.async { [paths] in
            Self.ensureITermRunning()
            let script = AppleScripts.createWindow(attachScript: paths.attachScriptURL.path,
                                                   entryID: entry.id,
                                                   frame: frame)
            var result = Shell.osascript(script, timeout: 25)
            if result.status != 0, Self.isMissingProfile(result) {
                Log.shared.write("iTerm2 lost the TmuxManager profile; rewriting it")
                ProfileInstaller.install()
                result = Shell.osascript(script, timeout: 25)
            }
            if result.status == 0 {
                Log.shared.write("created window for \(entry.address)")
                DispatchQueue.main.async { completion(.success(())) }
            } else {
                let message = Self.describe(result, context: "Could not open a console window")
                Log.shared.write("create window failed: \(message)")
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "TmuxManager", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: message])))
                }
            }
        }
    }

    /// Returns true when the window owning `guid` was found and raised.
    func activate(guid: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            // Never let the Apple event launch iTerm2: that would open an
            // untitled window (the caller treats not-found as "open a new
            // console", which launches iTerm2 properly).
            guard Self.isITermRunning() else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let result = Shell.osascript(AppleScripts.activateSession(guid: guid), timeout: 15)
            let found = result.status == 0
                && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            if result.status != 0 {
                Log.shared.write("activate failed: \(Self.describe(result, context: "activate"))")
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    func closeWindow(guid: String) {
        queue.async {
            guard Self.isITermRunning() else { return } // no window left to close
            let result = Shell.osascript(AppleScripts.closeSessionWindow(guid: guid), timeout: 15)
            if result.status != 0 {
                Log.shared.write("close failed: \(Self.describe(result, context: "close"))")
            }
        }
    }

    /// Synchronous and cheap (in-process Apple Event); called from the main thread timer.
    func frames() -> [SessionFrame] {
        // A `tell` block to a not-running app would launch iTerm2 (untitled
        // window included); there is simply nothing to poll then.
        guard Self.isITermRunning() else { return [] }
        if frameScript == nil {
            frameScript = NSAppleScript(source: AppleScripts.sessionFrames())
        }
        guard let script = frameScript else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number != -1743 { // -1743: pending/user-denied Automation permission; stay quiet
                Log.shared.write("frame poll failed: \(error)")
                frameScript = nil
            }
            return []
        }
        return SessionFrameParser.parse(result.stringValue ?? "")
    }

    // MARK: - Helpers

    static func isITermRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: iTermBundleID).isEmpty
    }

    static func ensureITermRunning() {
        guard !isITermRunning() else { return }
        Log.shared.write("iTerm2 is not running; launching it")
        // Two things open a stray window when iTerm2 starts: AppKit's
        // open-untitled-file callback (triggered by the run event a normal
        // launch sends) and iTerm2's own startup activities. The quiet marker
        // suppresses the latter; launching via AppleScript's `launch` (which
        // sends no run event) suppresses the former. Verified: launch + quiet
        // marker → zero startup windows.
        let quietMarker = Self.writeITermQuietMarker()
        let launched = Shell.osascript("launch application id \"\(iTermBundleID)\"", timeout: 15)
        if launched.status != 0 {
            Log.shared.write("AppleScript launch failed (\(launched.combined)); falling back to open")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-b", iTermBundleID]
            try? task.run()
            task.waitUntilExit()
        }
        for _ in 0..<40 {
            if isITermRunning(),
               Shell.osascript("tell application id \"\(iTermBundleID)\" to get version", timeout: 3).status == 0 {
                return
            }
            usleep(150_000)
        }
        // iTerm2 never came up. Remove the marker ourselves so it cannot
        // suppress startup windows on the user's next manual launch (a real
        // launch consumes and deletes it).
        if let quietMarker {
            try? FileManager.default.removeItem(at: quietMarker)
            Log.shared.write("iTerm2 did not launch; removed the quiet marker")
        }
    }

    /// Best effort: writes `~/Library/Application Support/iTerm2/quiet`, the
    /// file iTerm2 looks for at launch to skip its startup window. A failure
    /// only falls back to the old behavior (one extra empty window).
    static func writeITermQuietMarker() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iTerm2/quiet")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
            Log.shared.write("wrote iTerm2 quiet marker at \(url.path)")
            return url
        } catch {
            Log.shared.write("could not write iTerm2 quiet marker: \(error.localizedDescription)")
            return nil
        }
    }

    static func isMissingProfile(_ result: CommandResult) -> Bool {
        result.stderr.lowercased().contains("no profile exists")
    }

    static func describe(_ result: CommandResult, context: String) -> String {
        let text = result.combined
        if text.contains("-1743") || text.lowercased().contains("not authorized to send apple events") {
            return "\(context): macOS blocked sending Apple Events to iTerm2. "
                + "Allow TmuxManager under System Settings → Privacy & Security → Automation, then try again."
        }
        if text.contains("isn't running") || text.contains("-600") {
            return "\(context): iTerm2 is not running and could not be launched."
        }
        return text.isEmpty ? "\(context): osascript exited with status \(result.status)" : text
    }
}
