import Foundation

public final class Log {
    public static let shared = Log()
    private let queue = DispatchQueue(label: "com.cyb.tmuxmanager.log")
    private var url: URL?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public init() {}

    public func configure(_ paths: Paths) {
        queue.sync { url = paths.logURL }
    }

    public func write(_ message: String) {
        queue.async { [url, formatter] in
            guard let url else { return }
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            FileAppend.append(data, to: url, rotateAt: 1_000_000)
        }
    }
}

public enum FileAppend {
    static func append(_ data: Data, to url: URL, rotateAt size: Int) {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let current = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if current > size {
            let backup = url.deletingPathExtension().appendingPathExtension("1.txt")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: url, to: backup)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

public enum WrapperInstaller {
    /// Installs (or refreshes) attach.sh next to config.json.
    @discardableResult
    public static func install(source: URL, paths: Paths) throws -> Bool {
        try paths.prepareDirectories()
        let destination = paths.attachScriptURL
        let newData = try Data(contentsOf: source)
        let oldData = try? Data(contentsOf: destination)
        if oldData != newData {
            try newData.write(to: destination, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return oldData != newData
    }

    /// `attach.sh <uuid>` as run by iTerm2.
    public static func commandLine(paths: Paths, entryID: String) -> String {
        "\(Quote.shell(paths.attachScriptURL.path)) \(Quote.shell(entryID))"
    }
}
