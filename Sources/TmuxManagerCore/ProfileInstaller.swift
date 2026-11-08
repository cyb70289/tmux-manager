import Foundation

/// Writes the dynamic profile iTerm2 loads for console windows.
public enum ProfileInstaller {
    public static let profileName = "TmuxManager"
    public static let profileGUID = "B7F2B9C6-4E0B-4E9B-9C4B-2A6D0F1E3A55"

    static var profilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iTerm2/DynamicProfiles", isDirectory: true)
    }

    static var profileURL: URL { profilesDirectory.appendingPathComponent("TmuxManager.json") }

    static var json: String {
        // Omitting parent keys inherits iTerm2's actual default profile, whatever
        // its name. An unknown explicit parent yields bare settings in iTerm2.
        let profile: [String: Any] = [
            "Name": profileName,
            "Guid": profileGUID,
            "Close Sessions On End": true,
            "Prompt Before Closing 2": false,
        ]
        let root: [String: Any] = ["Profiles": [profile]]
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func install() {
        do {
            try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
            let desired = json.data(using: .utf8) ?? Data()
            if let existing = try? Data(contentsOf: profileURL), existing == desired { return }
            try desired.write(to: profileURL, options: .atomic)
            Log.shared.write("installed iTerm2 dynamic profile at \(profileURL.path)")
        } catch {
            Log.shared.write("could not install iTerm2 profile: \(error)")
        }
    }
}
