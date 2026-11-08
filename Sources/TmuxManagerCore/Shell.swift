import Foundation

public struct CommandResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var combined: String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (out.isEmpty, err.isEmpty) {
        case (false, false): return out + "\n" + err
        case (false, true): return out
        case (true, false): return err
        case (true, true): return ""
        }
    }
}

public enum Shell {
    /// Runs a command, capturing output, with a hard timeout.
    @discardableResult
    public static func run(_ launchPath: String,
                           _ arguments: [String],
                           timeout: TimeInterval? = nil,
                           stdinData: Data? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = stdinData == nil ? FileHandle.nullDevice : input

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
        if let stdinData {
            input.fileHandleForWriting.write(stdinData)
            try? input.fileHandleForWriting.close()
        }

        var timedOut = false
        let deadline = timeout.map { DispatchTime.now() + $0 }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        if let deadline {
            if semaphore.wait(timeout: deadline) == .timedOut {
                timedOut = true
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 2)
            }
        } else {
            semaphore.wait()
        }
        process.waitUntilExit()

        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(status: timedOut ? 124 : process.terminationStatus,
                             stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                             stderr: String(data: stderrData, encoding: .utf8) ?? "",
                             timedOut: timedOut)
    }

    public static func osascript(_ script: String, timeout: TimeInterval = 20) -> CommandResult {
        run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }

    public static func osascriptFile(_ path: String, arguments: [String], timeout: TimeInterval? = nil) -> CommandResult {
        run("/usr/bin/osascript", [path] + arguments, timeout: timeout)
    }
}

/// Result of the advisory "can I reach this host and is tmux there?" check.
public struct ProbeResult {
    public enum Kind {
        case ok(version: String)
        case tmuxMissing
        case unverified(String)
        case failed(String)
    }
    public var kind: Kind

    public var isBlocking: Bool { false }

    public var summary: String {
        switch kind {
        case .ok(let version): return "Connected. Remote tmux: \(version)"
        case .tmuxMissing: return "Connected, but tmux was not found on the remote host."
        case .unverified(let why): return "Could not verify automatically (\(why)). You can still save."
        case .failed(let why): return "Connection failed: \(why)"
        }
    }
}

public enum SSHProbe {
    /// Advisory check; never throws, never blocks saving.
    public static func check(host: String,
                             sshOptions: [String] = [],
                             timeout: TimeInterval = 25) -> ProbeResult {
        guard Validation.isValidHost(host) else {
            return ProbeResult(kind: .failed("invalid host"))
        }
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        args += sshOptions
        // Use a login shell so PATH includes /opt/homebrew/bin and friends.
        args += [host, "bash -lc 'command -v tmux >/dev/null 2>&1 && tmux -V || echo NO_TMUX'"]
        let result = Shell.run("/usr/bin/ssh", args, timeout: timeout)
        let text = result.combined
        if result.timedOut {
            return ProbeResult(kind: .failed("timed out after \(Int(timeout))s"))
        }
        if text.contains("NO_TMUX") {
            return ProbeResult(kind: .tmuxMissing)
        }
        if result.status == 0 {
            let version = text.split(separator: "\n").first.map(String.init) ?? "tmux"
            return ProbeResult(kind: .ok(version: version))
        }
        let lower = text.lowercased()
        if lower.contains("permission denied") || lower.contains("host key verification failed") {
            return ProbeResult(kind: .failed(text))
        }
        if lower.contains("batchmode") || lower.contains("no more authentication methods")
            || lower.contains("passphrase") || lower.contains("password") {
            return ProbeResult(kind: .unverified("interactive authentication required"))
        }
        return ProbeResult(kind: .failed(text.isEmpty ? "ssh exited with status \(result.status)" : text))
    }
}
