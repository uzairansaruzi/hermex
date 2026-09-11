import XCTest
@testable import HermesMobile

/// The pin file is the maintainer-facing record; `BotConnection.testedHermesVersion`
/// is the runtime mirror. Reading the file via `#filePath` keeps it out of the bundle.
final class BotConnectionVersionTests: XCTestCase {
    private var pinFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HermesMobileTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("HERMES_AGENT_TESTED_SHA")
    }

    func testPinFileMatchesRuntimeConstant() throws {
        guard let contents = try? String(contentsOf: pinFile, encoding: .utf8) else {
            throw XCTSkip("Could not read \(pinFile.path); the source tree is not present (physical device or remote runner).")
        }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 3, "commit, release, trailing newline")
        XCTAssertNotNil(lines[0].wholeMatch(of: /[0-9a-f]{40}/), "line 1 is the hermes-agent commit")
        XCTAssertEqual(lines[1], BotConnection.testedHermesVersion, "line 2 is the release /api/status reports")
    }

    func testNoteAppearsOnlyForADifferentReportedVersion() throws {
        var connection = BotConnection(id: UUID(), name: "Host", address: URL(string: "http://hermes.local")!,
                                       username: "user", password: "secret")
        XCTAssertNil(connection.untestedVersionNote, "unknown version: nothing to warn about")
        connection.hermesVersion = BotConnection.testedHermesVersion
        XCTAssertNil(connection.untestedVersionNote)
        connection.hermesVersion = "0.22.0"
        let note = try XCTUnwrap(connection.untestedVersionNote)
        XCTAssertTrue(note.contains("0.22.0") && note.contains(BotConnection.testedHermesVersion))
    }

    func testRecordsSavedBeforeThePinDecodeWithoutAVersion() throws {
        let stored = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Host","address":"http://hermes.local","username":"user","password":"secret"}"#
        let connection = try JSONDecoder().decode(BotConnection.self, from: Data(stored.utf8))
        XCTAssertNil(connection.hermesVersion)
        XCTAssertNil(connection.untestedVersionNote)
    }
}
