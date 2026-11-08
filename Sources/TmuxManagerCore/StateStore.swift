import Foundation

/// The wrapper writes this file while a console window is alive.
public struct WrapperState: Codable, Equatable {
    public var entryID: String
    public var wrapperPid: Int32
    public var sshPid: Int32?
    public var itermSessionID: String?
    public var tty: String?
    public var startedAt: Double?

    public init(entryID: String, wrapperPid: Int32, sshPid: Int32? = nil,
                itermSessionID: String? = nil, tty: String? = nil, startedAt: Double? = nil) {
        self.entryID = entryID
        self.wrapperPid = wrapperPid
        self.sshPid = sshPid
        self.itermSessionID = itermSessionID
        self.tty = tty
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case entryID = "entry_id"
        case wrapperPid = "wrapper_pid"
        case sshPid = "ssh_pid"
        case itermSessionID = "iterm_session_id"
        case tty
        case startedAt = "started_at"
    }
}

public enum Processes {
    /// Path of the executable behind `pid`, or nil when the process is gone.
    public static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Full argv of `pid`, or nil when the process is gone (uses KERN_PROCARGS2).
    /// Needed because a script runs as its interpreter, so the executable path alone
    /// cannot tell our wrapper apart from any other bash.
    public static func arguments(of pid: Int32) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<4]))
            }
        }
        guard argc > 0, argc < 4096 else { return nil }

        var index = MemoryLayout<Int32>.size
        // exec path, then zero padding, then argv[0], argv[1], ...
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var current: [CChar] = []
        while index < size && arguments.count < Int(argc) {
            let character = buffer[index]
            index += 1
            if character == 0 {
                arguments.append(String(cString: current + [0]))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }
        return arguments.isEmpty ? nil : arguments
    }
}

public final class StateStore {
    public let paths: Paths

    public init(paths: Paths = .default) {
        self.paths = paths
    }

    /// Live wrapper states, keyed by entry id. Stale files (dead or foreign process) are dropped.
    public func liveStates() -> [String: WrapperState] {
        var out: [String: WrapperState] = [:]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.stateDir.path) else {
            return out
        }
        let expected = paths.attachScriptURL.resolvingSymlinksInPath().path
        for name in names where name.hasSuffix(".json") {
            let url = paths.stateDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(WrapperState.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard belongsToWrapper(state, scriptPath: expected) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            out[state.entryID] = state
        }
        return out
    }

    /// True when `pid` is still our wrapper for `state.entryID` (guards against pid reuse).
    private func belongsToWrapper(_ state: WrapperState, scriptPath expected: String) -> Bool {
        if let arguments = Processes.arguments(of: state.wrapperPid) {
            let matchesScript = arguments.contains { $0 == expected || $0 == paths.attachScriptURL.path }
            let matchesEntry = arguments.contains(state.entryID)
            return matchesScript && matchesEntry
        }
        // Older systems / permission denied: fall back to the executable path.
        guard let path = Processes.executablePath(of: state.wrapperPid) else { return false }
        return path == expected || path == "/bin/bash" || path == "/bin/sh"
    }
}
