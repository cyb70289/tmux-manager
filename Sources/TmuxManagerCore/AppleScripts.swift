import Foundation

/// AppleScript sources used by the app. Kept as pure string builders so they are testable.
public enum AppleScripts {
    public static let profileName = "TmuxManager"

    /// Creates one console window and (optionally) applies a saved frame.
    public static func createWindow(attachScript: String,
                                    entryID: String,
                                    frame: Frame?) -> String {
        var lines: [String] = []
        lines.append("tell application \"iTerm2\"")
        lines.append("  set cmd to \(Quote.appleScript("\(Quote.shell(attachScript)) \(Quote.shell(entryID))"))")
        lines.append("  set w to create window with profile \(Quote.appleScript(profileName)) command cmd")
        if let frame, frame.isUsable {
            let text = boundsLiteral(frame)
            lines.append("  set bounds of w to \(text)")
            lines.append("  delay 0.15")
            lines.append("  set bounds of w to \(text)")
        }
        lines.append("  return id of w as text")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// Brings the window owning session `guid` to the front. Returns "true"/"false".
    public static func activateSession(guid: String) -> String {
        guard Validation.isValidGUID(guid) else { return "return \"false\"" }
        return """
        tell application "iTerm2"
          set hit to false
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if ((id of s) as text) is \(Quote.appleScript(guid)) then
                  set hit to true
                  if miniaturized of w then set miniaturized of w to false
                  select t
                  select s
                  set index of w to 1
                end if
              end repeat
            end repeat
          end repeat
          activate
          return hit as text
        end tell
        """
    }

    /// `guid|left|top|right|bottom|miniaturized` per session, newline separated.
    /// A literal "|" is used instead of tab because iTerm2's dictionary defines a `tab` class.
    public static func sessionFrames() -> String {
        """
        tell application "iTerm2"
          set out to ""
          repeat with w in windows
            set b to bounds of w
            set mini to miniaturized of w
            repeat with t in tabs of w
              repeat with s in sessions of t
                set out to out & (id of s as text) & "|" & (item 1 of b) & "|" & (item 2 of b) & "|" & (item 3 of b) & "|" & (item 4 of b) & "|" & mini & linefeed
              end repeat
            end repeat
          end repeat
          return out
        end tell
        """
    }

    /// Closes the window owning session `guid` (used when removing an entry).
    public static func closeSessionWindow(guid: String) -> String {
        guard Validation.isValidGUID(guid) else { return "return \"false\"" }
        return """
        tell application "iTerm2"
          set hit to false
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if ((id of s) as text) is \(Quote.appleScript(guid)) then
                  set hit to true
                  close w
                end if
              end repeat
            end repeat
          end repeat
          return hit as text
        end tell
        """
    }

    public static func boundsLiteral(_ frame: Frame) -> String {
        let b = frame.bounds
        return "{\(Int(b.0.rounded())), \(Int(b.1.rounded())), \(Int(b.2.rounded())), \(Int(b.3.rounded()))}"
    }
}

/// One session reported by the frame query.
public struct SessionFrame: Equatable {
    public var guid: String
    public var frame: Frame
    public var miniaturized: Bool
}

public enum SessionFrameParser {
    public static func parse(_ text: String) -> [SessionFrame] {
        var out: [SessionFrame] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 6 else { continue }
            let guid = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard Validation.isValidGUID(guid),
                  let l = Double(parts[1]), let t = Double(parts[2]),
                  let r = Double(parts[3]), let b = Double(parts[4]) else { continue }
            let mini = String(parts[5]).trimmingCharacters(in: .whitespaces).lowercased() == "true"
            out.append(SessionFrame(guid: guid,
                                    frame: Frame(bounds: (l, t, r, b)),
                                    miniaturized: mini))
        }
        return out
    }
}
