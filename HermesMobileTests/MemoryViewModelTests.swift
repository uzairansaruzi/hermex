import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class MemoryViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testSaveWritesSelectedSectionAndReloadsMemory() async throws {
        var requestPaths: [String] = []
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")

            if request.url?.path == "/api/memory/write" {
                XCTAssertEqual(request.httpMethod, "POST")
                let data = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertEqual(body?["section"] as? String, "soul")
                XCTAssertEqual(body?["content"] as? String, "# Updated Soul")

                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "section": "soul",
                  "path": "/Users/test/.hermes/SOUL.md"
                }
                """, for: request)
            }

            XCTAssertEqual(request.url?.path, "/api/memory")
            return apiTestJSONResponse("""
            {
              "memory": "# Notes",
              "user": "# Profile",
              "soul": "# Updated Soul",
              "memory_mtime": 1770000000,
              "user_mtime": 1770000100,
              "soul_mtime": 1770000200
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didSave = await viewModel.save(section: .soul, content: "# Updated Soul")

        XCTAssertTrue(didSave)
        XCTAssertEqual(requestPaths, ["/api/memory/write", "/api/memory"])
        XCTAssertEqual(viewModel.memoryText, "# Notes")
        XCTAssertEqual(viewModel.userText, "# Profile")
        XCTAssertEqual(viewModel.soulText, "# Updated Soul")
        XCTAssertEqual(viewModel.soulMtime, Date(timeIntervalSince1970: 1_770_000_200))
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testSaveSurfacesRejectedResponseWithoutReloading() async throws {
        var requestPaths: [String] = []
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")

            return apiTestJSONResponse("""
            {
              "ok": false,
              "error": "section rejected"
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didSave = await viewModel.save(section: .memory, content: "# Notes")

        XCTAssertFalse(didSave)
        XCTAssertEqual(requestPaths, ["/api/memory/write"])
        XCTAssertEqual(viewModel.actionErrorMessage, "section rejected")
        XCTAssertFalse(viewModel.hasLoaded)
    }

    @MainActor
    func testLoadSurfacesProjectContextDocument() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "memory": "# Notes",
              "user": "# Profile",
              "soul": "# Soul",
              "project_context": "# Project rules",
              "project_context_name": "AGENTS.md",
              "project_context_workspace": "/Users/test/workspace",
              "project_context_mtime": 1770000300,
              "project_context_shadowed": [
                {
                  "name": "PROJECT.md",
                  "path": "/Users/test/PROJECT.md"
                }
              ],
              "external_notes_enabled": true
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.showsProjectContext)
        XCTAssertEqual(viewModel.projectContextText, "# Project rules")
        XCTAssertEqual(viewModel.projectContextName, "AGENTS.md")
        XCTAssertEqual(viewModel.projectContextWorkspace, "/Users/test/workspace")
        XCTAssertEqual(viewModel.projectContextMtime, Date(timeIntervalSince1970: 1_770_000_300))
        XCTAssertTrue(viewModel.isProjectContextShadowed)
        XCTAssertEqual(viewModel.isExternalNotesEnabled, true)
        XCTAssertEqual(viewModel.projectContextDetail, "AGENTS.md — /Users/test/workspace")
    }

    @MainActor
    func testProjectContextSectionHiddenWithoutFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "memory": "# Notes",
              "user": "# Profile",
              "soul": "# Soul"
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.showsProjectContext)
        XCTAssertFalse(viewModel.isProjectContextShadowed)
        XCTAssertNil(viewModel.projectContextDetail)
        XCTAssertNil(viewModel.isExternalNotesEnabled)
    }

    @MainActor
    func testProjectContextSectionHiddenForBlankDocumentAndDetailOmitsEmptyParts() async throws {
        // Upstream returns "" (not null) when no readable project-context file exists.
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "memory": "# Notes",
              "project_context": "  \\n ",
              "project_context_name": "",
              "project_context_workspace": "/Users/test/workspace",
              "project_context_shadowed": []
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.showsProjectContext)
        XCTAssertFalse(viewModel.isProjectContextShadowed)
        XCTAssertEqual(viewModel.projectContextDetail, "/Users/test/workspace")
    }

    // MARK: - Hermes (#1073)

    @MainActor
    func testOverTheHostsLimitNothingIsSentAndTheCountSaysByHowMuch() async throws {
        let client = StubMemoryClient(limits: [.memory: 10])
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)
        await viewModel.load()

        // 👍🏽 is two scalars on the host: "1234567 👍🏽" is 10, and a second entry makes it 14.
        let atLimit = MemoryCharacterCount(draft: "1234567 👍🏽", limit: 10)
        let over = MemoryCharacterCount(draft: "1234567 👍🏽\n\n§\n\nx", limit: 10)

        XCTAssertEqual([atLimit.count, atLimit.overBy], [10, 0])
        XCTAssertFalse(atLimit.isOver)
        XCTAssertEqual([over.count, over.overBy], [14, 4])
        XCTAssertTrue(over.isOver)
        let didSave = await viewModel.save(section: .memory, content: "1234567 👍🏽\n§\nx", loaded: "")
        XCTAssertFalse(didSave)
        XCTAssertEqual(client.saves.count, 0, "Nothing is sent over the limit")
        XCTAssertEqual(viewModel.actionErrorMessage, "Over the host's limit. Shorten to save.")
        XCTAssertNil(viewModel.characterLimit(for: .soul), "The soul has no limit")
    }

    @MainActor
    func testAConflictKeepsTheDraftAndReloadReturnsTheHostsText() async throws {
        let client = StubMemoryClient(memory: "On the host")
        client.saveError = MemoryConflict()
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)
        await viewModel.load()
        client.response = MemoryResponse(memory: "Changed by the agent", user: "", soul: "")

        let didSave = await viewModel.save(section: .memory, content: "My draft", loaded: "On the host")

        XCTAssertFalse(didSave, "The editor stays open with its draft")
        XCTAssertEqual(viewModel.conflictedSection, .memory)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(client.saves.map(\.loaded), ["On the host"])
        XCTAssertEqual(viewModel.memoryText, "On the host", "Nothing is reloaded behind the draft")

        let reloaded = await viewModel.reload(.memory)

        XCTAssertEqual(reloaded, "Changed by the agent")
        XCTAssertNil(viewModel.conflictedSection)
    }

    /// A file that turned read-only on the host while its editor was open (seen on Reload) is
    /// not sent, so the save can't come back as a "Changed on the host" the user can't clear.
    @MainActor
    func testASectionReloadFindsReadOnlyIsNotSent() async throws {
        let client = StubMemoryClient(memory: "Prefers short PRs")
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)
        await viewModel.load()
        client.response.readOnlySections = [.memory]
        _ = await viewModel.reload(.memory)

        let didSave = await viewModel.save(section: .memory, content: "My draft", loaded: "Prefers short PRs")

        XCTAssertFalse(didSave)
        XCTAssertEqual(client.saves.count, 0, "Nothing is sent for a read-only file")
        XCTAssertNil(viewModel.conflictedSection)
    }

    @MainActor
    func testHermesSectionsTheHostTurnsOffAreHiddenAndUnreadableOnesAreReadOnly() async throws {
        let client = StubMemoryClient()
        client.response.hiddenSections = [.user]
        client.response.readOnlySections = [.memory]
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertEqual(viewModel.visibleSections, [.memory, .soul])
        XCTAssertTrue(viewModel.isReadOnly(.memory))
        XCTAssertFalse(viewModel.isReadOnly(.soul))
    }

    @MainActor
    func testWebuiShowsEverySectionWithoutLimits() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(##"{"memory": "# Notes", "user": "", "soul": "# Soul"}"##, for: request)
        }
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertEqual(viewModel.visibleSections, [.memory, .user, .soul])
        XCTAssertNil(viewModel.characterLimit(for: .memory))
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }
}

/// A Hermes memory client with scripted replies, recording each save.
@MainActor
private final class StubMemoryClient: MemoryDataClient {
    nonisolated var memoryFeatures: MemoryFeatures { .hermes }
    var response: MemoryResponse
    var saveError: Error?
    private(set) var saves: [(section: MemorySection, content: String, loaded: String)] = []

    init(memory: String = "", limits: [MemorySection: Int] = [.memory: 2200, .user: 1375]) {
        response = MemoryResponse(memory: memory, user: "", soul: "")
        response.characterLimits = limits
    }

    func memory() async throws -> MemoryResponse { response }

    func saveMemory(section: MemorySection, content: String, loaded: String) async throws -> MemoryWriteResponse {
        saves.append((section, content, loaded))
        if let saveError { throw saveError }
        return MemoryWriteResponse(saved: section)
    }
}
