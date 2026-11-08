import Foundation

/// Window frame in AppleScript `bounds` space: top-left origin, y grows downward
/// from the top edge of the primary display, units are points.
public struct Frame: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public init(bounds: (Double, Double, Double, Double)) {
        self.init(x: bounds.0, y: bounds.1, w: bounds.2 - bounds.0, h: bounds.3 - bounds.1)
    }

    /// The four AppleScript `bounds` values: {left, top, right, bottom}.
    public var bounds: (Double, Double, Double, Double) {
        (x, y, x + w, y + h)
    }

    public var isUsable: Bool { w >= 100 && h >= 100 }
}

public struct BarOrigin: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct UIConfig: Codable, Equatable {
    public var barOrigin: BarOrigin?
    public var frameCaptureIntervalSeconds: Double

    public init(barOrigin: BarOrigin? = nil, frameCaptureIntervalSeconds: Double = 10) {
        self.barOrigin = barOrigin
        self.frameCaptureIntervalSeconds = frameCaptureIntervalSeconds
    }

    enum CodingKeys: String, CodingKey {
        case barOrigin = "bar_origin"
        case frameCaptureIntervalSeconds = "frame_capture_interval_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        barOrigin = try c.decodeIfPresent(BarOrigin.self, forKey: .barOrigin)
        let interval = try c.decodeIfPresent(Double.self, forKey: .frameCaptureIntervalSeconds) ?? 10
        frameCaptureIntervalSeconds = min(max(interval, 1), 3600)
    }
}

public struct Entry: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    public var host: String
    public var session: String
    public var tmuxPath: String?
    public var sshOptions: [String]
    public var detachOtherClients: Bool
    public var frame: Frame?

    public init(id: String = UUID().uuidString,
                name: String? = nil,
                host: String,
                session: String,
                tmuxPath: String? = nil,
                sshOptions: [String] = [],
                detachOtherClients: Bool = false,
                frame: Frame? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.session = session
        self.tmuxPath = tmuxPath
        self.sshOptions = sshOptions
        self.detachOtherClients = detachOtherClients
        self.frame = frame
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, session, frame
        case tmuxPath = "tmux_path"
        case sshOptions = "ssh_options"
        case detachOtherClients = "detach_other_clients"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        session = try c.decode(String.self, forKey: .session)
        tmuxPath = try c.decodeIfPresent(String.self, forKey: .tmuxPath)
        sshOptions = try c.decodeIfPresent([String].self, forKey: .sshOptions) ?? []
        detachOtherClients = try c.decodeIfPresent(Bool.self, forKey: .detachOtherClients) ?? false
        frame = try c.decodeIfPresent(Frame.self, forKey: .frame)
    }

    /// What the bar shows: explicit name, otherwise `host:session` with any `user@` stripped.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return defaultDisplayName
    }

    public var defaultDisplayName: String {
        "\(Validation.bareHost(host)):\(session)"
    }

    public var address: String { "\(host):\(session)" }

    public var effectiveTmuxPath: String { tmuxPath?.isEmpty == false ? tmuxPath! : "tmux" }
}

public struct Config: Codable, Equatable {
    public var version: Int
    public var ui: UIConfig
    public var entries: [Entry]

    public init(version: Int = 1, ui: UIConfig = UIConfig(), entries: [Entry] = []) {
        self.version = version
        self.ui = ui
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case version, ui, entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        ui = try c.decodeIfPresent(UIConfig.self, forKey: .ui) ?? UIConfig()
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    public func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Bar order: display name, case-insensitively, ties broken by address.
    public var sortedEntries: [Entry] {
        entries.sorted { a, b in
            let cmp = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a.address.localizedCaseInsensitiveCompare(b.address) == .orderedAscending
        }
    }
}

/// Problems with a single field of an entry draft.
public enum EntryField: String {
    case name, host, session, tmuxPath, sshOptions
}

public struct EntryProblem: Equatable {
    public var field: EntryField
    public var message: String
}

public enum EntryValidator {
    public static func problems(for entry: Entry, all: [Entry]) -> [EntryProblem] {
        var out: [EntryProblem] = []
        if !Validation.isValidHost(entry.host) {
            out.append(.init(field: .host, message: "SSH host is empty or contains whitespace."))
        }
        if !Validation.isValidSession(entry.session) {
            out.append(.init(field: .session,
                             message: "Session name may only contain letters, digits, _ . and -"))
        }
        if let tmuxPath = entry.tmuxPath, tmuxPath.contains(where: { $0.isWhitespace }) {
            out.append(.init(field: .tmuxPath, message: "Remote tmux path must not contain whitespace."))
        }
        for option in entry.sshOptions where option.contains(where: { $0.isNewline }) {
            out.append(.init(field: .sshOptions, message: "SSH options must be one per line."))
        }
        let clash = all.contains { other in
            other.id != entry.id
                && other.host.caseInsensitiveCompare(entry.host) == .orderedSame
                && other.session == entry.session
        }
        if clash {
            out.append(.init(field: .session, message: "\(entry.address) is already configured."))
        }
        return out
    }

    public static func message(for problems: [EntryProblem]) -> String? {
        problems.isEmpty ? nil : problems.map(\.message).joined(separator: " ")
    }
}
