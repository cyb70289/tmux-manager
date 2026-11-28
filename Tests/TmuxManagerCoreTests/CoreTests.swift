import XCTest
@testable import TmuxManagerCore

final class CoreTests: XCTestCase {

    func testConfigSaveReloadAndEnvCleanup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tm-test-\(UUID().uuidString)")
        let paths = Paths(supportDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = Config()
        config.ui.barOrigin = BarOrigin(x: 10, y: 20)
        var entry = Entry(host: "cyb@it's-host", session: "main")
        entry.name = "box"
        entry.sshOptions = ["-o", "ProxyJump=jump"]
        entry.detachOtherClients = true
        entry.frame = Frame(x: 100, y: 200, w: 800, h: 600)
        config.entries = [entry]

        let store = ConfigStore(paths: paths)
        try store.save(config)

        guard case .loaded(let loaded, _) = store.load() else {
            return XCTFail("expected saved config to load")
        }
        XCTAssertEqual(loaded, config)

        let env = try String(contentsOf: paths.envURL(entryID: entry.id), encoding: .utf8)
        XCTAssertTrue(env.contains("HOST='cyb@it'\\''s-host'"), env)
        XCTAssertTrue(env.contains("DETACH_OTHER_CLIENTS=1"), env)

        try store.save(Config(entries: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.envURL(entryID: entry.id).path))
    }

    func testCreateWindowAndUnsafeGUID() {
        let script = AppleScripts.createWindow(attachScript: "/tmp/it's here/attach.sh",
                                               entryID: "ABC-123",
                                               frame: Frame(x: 10, y: 20, w: 800, h: 600))
        XCTAssertTrue(script.contains("create window with profile \"TmuxManager\""))
        XCTAssertTrue(script.contains("set bounds of w to {10, 20, 810, 620}"), script)

        let rejected = AppleScripts.activateSession(guid: "abc\" & (do shell script \"rm -rf /\") & \"")
        XCTAssertEqual(rejected, "return \"false\"")
    }

    func testDynamicProfileInheritsActualDefault() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ProfileInstaller.json.utf8))
            as? [String: Any])
        let profiles = try XCTUnwrap(root["Profiles"] as? [[String: Any]])
        let profile = try XCTUnwrap(profiles.first)

        XCTAssertNil(profile["Dynamic Profile Parent Name"])
        XCTAssertNil(profile["Dynamic Profile Parent GUID"])
        XCTAssertEqual(profile["Name"] as? String, AppleScripts.profileName)
        XCTAssertEqual(profile["Close Sessions On End"] as? Bool, true)
        XCTAssertEqual(profile["Prompt Before Closing 2"] as? Bool, false)
    }

    func testFrameParseAndClamp() {
        let parsed = SessionFrameParser.parse("AAA-BBB|10|20|810|620|false\nbroken\n")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].frame, Frame(x: 10, y: 20, w: 800, h: 600))

        let screens = [ScreenRect(x: 0, y: 0, w: 1440, h: 900)]
        XCTAssertEqual(FrameClamp.clamp(parsed[0].frame, screens: screens, primaryHeight: 900),
                       parsed[0].frame)

        let offscreen = FrameClamp.clamp(Frame(x: 3000, y: 100, w: 800, h: 600),
                                         screens: screens, primaryHeight: 900)
        XCTAssertEqual(offscreen, Frame(x: 640, y: 100, w: 800, h: 600))
    }

    func testBarPlacementKeepsRightEdgePinned() {
        let visible = ScreenRect(x: 65, y: 0, w: 1645, h: 1073)
        let anchor = BarAnchor(right: 1710, top: 1073)

        let grown = BarPlacement.frame(width: 500, height: 44, anchor: anchor, visible: visible)
        XCTAssertEqual(grown.x + grown.w, 1710)
        XCTAssertEqual(grown.y, 1029)

        let overflow = BarPlacement.frame(width: 1700, height: 44, anchor: anchor, visible: visible)
        XCTAssertEqual(overflow.x, 65)
    }

    func testStateStoreDropsStaleFiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tm-state-\(UUID().uuidString)")
        let paths = Paths(supportDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        try paths.prepareDirectories()
        let data = try JSONEncoder().encode(WrapperState(entryID: "A", wrapperPid: 999_999))
        try data.write(to: paths.stateURL(entryID: "A"))

        XCTAssertTrue(StateStore(paths: paths).liveStates().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateURL(entryID: "A").path))
    }
}
