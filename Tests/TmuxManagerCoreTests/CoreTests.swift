import XCTest
@testable import TmuxManagerCore

final class CoreTests: XCTestCase {

    // MARK: display name

    func testDefaultDisplayNameStripsUser() {
        let entry = Entry(host: "cyb@azure-japan", session: "main")
        XCTAssertEqual(entry.defaultDisplayName, "azure-japan:main")
        XCTAssertEqual(entry.displayName, "azure-japan:main")
        XCTAssertEqual(entry.address, "cyb@azure-japan:main")
    }

    func testExplicitNameWins() {
        var entry = Entry(host: "azure-japan", session: "main")
        entry.name = "  build box "
        XCTAssertEqual(entry.displayName, "  build box ")
        entry.name = "   "
        XCTAssertEqual(entry.displayName, "azure-japan:main")
        entry.name = ""
        XCTAssertEqual(entry.displayName, "azure-japan:main")
    }

    func testSortedByDisplayName() {
        let config = Config(entries: [
            Entry(name: "beta", host: "h1", session: "z"),
            Entry(name: "Alpha", host: "h1", session: "a"),
            Entry(host: "h2", session: "b"),
        ])
        XCTAssertEqual(config.sortedEntries.map(\.displayName), ["Alpha", "beta", "h2:b"])
    }

    // MARK: validation

    func testValidation() {
        XCTAssertTrue(Validation.isValidSession("main-1_a.b"))
        XCTAssertFalse(Validation.isValidSession("bad name"))
        XCTAssertFalse(Validation.isValidSession(""))
        XCTAssertFalse(Validation.isValidSession("semi;colon"))
        XCTAssertTrue(Validation.isValidHost("cyb@host.example.com"))
        XCTAssertFalse(Validation.isValidHost("two words"))
        XCTAssertFalse(Validation.isValidHost(" "))
        XCTAssertEqual(Validation.bareHost("cyb@host"), "host")
        XCTAssertEqual(Validation.bareHost("host"), "host")
    }

    func testDuplicateAddressRejected() {
        let a = Entry(host: "h", session: "s")
        let b = Entry(host: "H", session: "s")
        let problems = EntryValidator.problems(for: b, all: [a, b])
        XCTAssertTrue(problems.contains { $0.field == .session })
        XCTAssertEqual(EntryValidator.problems(for: a, all: [a]), [])
    }

    // MARK: quoting

    func testShellQuoting() {
        XCTAssertEqual(Quote.shell("plain"), "'plain'")
        XCTAssertEqual(Quote.shell("it's"), "'it'\\''s'")
    }

    func testAppleScriptQuoting() {
        XCTAssertEqual(Quote.appleScript("a\"b\\c\nd"), "\"a\\\"b\\\\c\\nd\"")
    }

    func testUnsafeGUIDRejected() {
        let script = AppleScripts.activateSession(guid: "abc\" & (do shell script \"rm -rf /\") & \"")
        XCTAssertEqual(script, "return \"false\"")
    }

    func testCreateWindowScriptQuotesArguments() {
        let script = AppleScripts.createWindow(attachScript: "/tmp/it's here/attach.sh",
                                               entryID: "ABC-123",
                                               frame: Frame(x: 10, y: 20, w: 800, h: 600))
        XCTAssertTrue(script.contains("create window with profile \"TmuxManager\""))
        XCTAssertTrue(script.contains("set bounds of w to {10, 20, 810, 620}"), script)
    }

    func testBoundsLiteralRounds() {
        XCTAssertEqual(AppleScripts.boundsLiteral(Frame(x: 1.4, y: 2.6, w: 10, h: 20)),
                       "{1, 3, 11, 23}")
    }

    // MARK: frames

    func testSessionFrameParsing() {
        let text = "AAA-BBB|10|20|810|620|false\nbroken\nCCC|1|2|3|4|true\n"
        let frames = SessionFrameParser.parse(text)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].guid, "AAA-BBB")
        XCTAssertEqual(frames[0].frame, Frame(x: 10, y: 20, w: 800, h: 600))
        XCTAssertFalse(frames[0].miniaturized)
        XCTAssertTrue(frames[1].miniaturized)
    }

    func testClampKeepsVisibleFrame() {
        let screens = [ScreenRect(x: 0, y: 0, w: 1440, h: 900)]
        let frame = Frame(x: 100, y: 100, w: 800, h: 600)
        XCTAssertEqual(FrameClamp.clamp(frame, screens: screens, primaryHeight: 900), frame)
    }

    func testClampMovesOffscreenFrame() {
        let screens = [ScreenRect(x: 0, y: 0, w: 1440, h: 900)]
        let frame = Frame(x: 3000, y: 100, w: 800, h: 600)
        let clamped = FrameClamp.clamp(frame, screens: screens, primaryHeight: 900)
        XCTAssertEqual(clamped.x, 640)
        XCTAssertEqual(clamped.y, 100)
        XCTAssertEqual(clamped.w, 800)
        XCTAssertEqual(clamped.h, 600)
    }

    func testClampShrinksOversizeFrame() {
        let screens = [ScreenRect(x: 0, y: 0, w: 1440, h: 900)]
        let frame = Frame(x: -50, y: -50, w: 3000, h: 2000)
        let clamped = FrameClamp.clamp(frame, screens: screens, primaryHeight: 900)
        XCTAssertEqual(clamped.w, 1440)
        XCTAssertEqual(clamped.h, 900)
        XCTAssertEqual(clamped.x, 0)
        XCTAssertEqual(clamped.y, 0)
    }

    func testClampUsesSecondaryScreen() {
        let screens = [
            ScreenRect(x: 0, y: 0, w: 1440, h: 900),
            ScreenRect(x: 1440, y: 0, w: 1920, h: 1080),
        ]
        // Entirely inside the secondary display: untouched.
        let inside = Frame(x: 1600, y: 100, w: 800, h: 600)
        XCTAssertEqual(FrameClamp.clamp(inside, screens: screens, primaryHeight: 900), inside)
        // Off to the right of everything: pulled onto the secondary display.
        let far = Frame(x: 5000, y: 100, w: 800, h: 600)
        let clamped = FrameClamp.clamp(far, screens: screens, primaryHeight: 900)
        XCTAssertEqual(clamped.x, 1440 + 1920 - 800)
    }

    // MARK: config round trip

    func testConfigRoundTrip() throws {
        var config = Config()
        config.ui.frameCaptureIntervalSeconds = 5
        config.ui.barOrigin = BarOrigin(x: 10, y: 20)
        var entry = Entry(host: "cyb@azure", session: "main")
        entry.name = "box"
        entry.tmuxPath = "/usr/local/bin/tmux"
        entry.sshOptions = ["-o", "ProxyJump=jump"]
        entry.detachOtherClients = true
        entry.frame = Frame(x: 1, y: 2, w: 3, h: 4)
        config.entries = [entry]

        let data = try JSONEncoder().encode(config)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"detach_other_clients\":true"), text)
        XCTAssertTrue(text.contains("\"frame_capture_interval_seconds\":5"), text)

        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testConfigDefaultsWhenFieldsMissing() throws {
        let json = #"{"entries":[{"host":"h","session":"s"}]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.ui.frameCaptureIntervalSeconds, 10)
        XCTAssertEqual(config.entries.first?.sshOptions, [])
        XCTAssertEqual(config.entries.first?.detachOtherClients, false)
        XCTAssertFalse(config.entries.first?.id.isEmpty ?? true)
    }

    func testFrameIntervalIsClamped() throws {
        let json = #"{"ui":{"frame_capture_interval_seconds":0},"entries":[]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.ui.frameCaptureIntervalSeconds, 1)
    }

    // MARK: env file

    func testEnvContentsAreShellSafe() {
        let store = ConfigStore(paths: Paths(supportDir: URL(fileURLWithPath: "/tmp/tm-test")))
        var entry = Entry(host: "cyb@it's a host", session: "main")
        entry.sshOptions = ["-o", "Value with space='x'"]
        let contents = store.envContents(for: entry)
        XCTAssertTrue(contents.contains("HOST='cyb@it'\\''s a host'"), contents)
        XCTAssertTrue(contents.contains("EXTRA_SSH_OPTS=( '-o' 'Value with space='\\''x'\\''' )"), contents)
        XCTAssertTrue(contents.contains("DETACH_OTHER_CLIENTS=0"), contents)
    }

    func testEnvFilesWrittenAndOrphansRemoved() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tm-test-\(UUID().uuidString)")
        let paths = Paths(supportDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(paths: paths)
        let entry = Entry(host: "h", session: "s")
        try store.save(Config(entries: [entry]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.envURL(entryID: entry.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configURL.path))

        try store.save(Config(entries: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.envURL(entryID: entry.id).path))
        let decoded = try JSONDecoder().decode(Config.self, from: Data(contentsOf: paths.configURL))
        XCTAssertEqual(decoded.entries.count, 0)
    }

    // MARK: state file

    func testWrapperStateDecoding() throws {
        let json = #"{"entry_id":"A","wrapper_pid":42,"ssh_pid":43,"iterm_session_id":"w0t0p0:XYZ","tty":"ttys002","started_at":1.5}"#
        let state = try JSONDecoder().decode(WrapperState.self, from: Data(json.utf8))
        XCTAssertEqual(state.wrapperPid, 42)
        XCTAssertEqual(state.sshPid, 43)
        XCTAssertEqual(state.itermSessionID, "w0t0p0:XYZ")
        XCTAssertEqual(state.tty, "ttys002")
    }

    func testStateStoreDropsStaleFiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tm-state-\(UUID().uuidString)")
        let paths = Paths(supportDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        try paths.prepareDirectories()
        let bogus = WrapperState(entryID: "A", wrapperPid: 999_999)
        let data = try JSONEncoder().encode(bogus)
        try data.write(to: paths.stateURL(entryID: "A"))
        XCTAssertEqual(StateStore(paths: paths).liveStates().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateURL(entryID: "A").path))
    }

    // MARK: probe

    func testProbeRejectsInvalidHost() {
        let result = SSHProbe.check(host: "bad host")
        if case .failed = result.kind {} else { XCTFail("expected failure") }
    }
}

final class ProcessTests: XCTestCase {
    func testArgumentsOfSelf() {
        let arguments = Processes.arguments(of: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(arguments)
        XCTAssertFalse(arguments?.isEmpty ?? true)
    }

    func testArgumentsOfDeadPid() {
        XCTAssertNil(Processes.arguments(of: 999_999))
    }
}
