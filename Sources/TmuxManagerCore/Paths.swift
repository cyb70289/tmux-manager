import Foundation

/// All on-disk locations used by the app and the wrapper script.
public struct Paths {
    public var supportDir: URL

    public init(supportDir: URL) {
        self.supportDir = supportDir
    }

    public static var `default`: Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(supportDir: home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("TmuxManager", isDirectory: true))
    }

    public var configURL: URL { supportDir.appendingPathComponent("config.json") }
    public var envDir: URL { supportDir.appendingPathComponent("env", isDirectory: true) }
    public var stateDir: URL { supportDir.appendingPathComponent("state", isDirectory: true) }
    public var logURL: URL { supportDir.appendingPathComponent("log.txt") }
    public var attachScriptURL: URL { supportDir.appendingPathComponent("attach.sh") }

    public func envURL(entryID: String) -> URL { envDir.appendingPathComponent("\(entryID).sh") }
    public func stateURL(entryID: String) -> URL { stateDir.appendingPathComponent("\(entryID).json") }

    /// Creates every directory the app needs (idempotent).
    public func prepareDirectories() throws {
        for dir in [supportDir, envDir, stateDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
