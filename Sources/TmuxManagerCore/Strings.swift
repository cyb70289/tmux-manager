import Foundation

/// Quoting helpers. Everything we hand to a shell or to osascript goes through these.
public enum Quote {
    /// POSIX single-quoted word: safe to paste into bash/sh.
    public static func shell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Double-quoted AppleScript string literal (including the quotes).
    public static func appleScript(_ value: String) -> String {
        var out = "\""
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    /// True when the string is safe to interpolate into AppleScript/shell as a bare token.
    public static func isSafeToken(_ value: String, allowed: CharacterSet) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public enum Validation {
    public static let sessionAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
    public static let guidAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

    public static func isValidSession(_ session: String) -> Bool {
        Quote.isSafeToken(session, allowed: sessionAllowed)
    }

    public static func isValidHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains(where: { $0.isWhitespace })
    }

    public static func isValidGUID(_ guid: String) -> Bool {
        Quote.isSafeToken(guid, allowed: guidAllowed)
    }

    /// Host with any `user@` prefix removed, for display.
    public static func bareHost(_ host: String) -> String {
        guard let at = host.lastIndex(of: "@") else { return host }
        return String(host[host.index(after: at)...])
    }
}
