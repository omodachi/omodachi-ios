import XCTest
@testable import Omodachi

/// HERDR-6: a new Herdr workspace from the phone, in a folder it picks. core's
/// two replies decode; the client asks exactly the two routes; the More menu
/// has the item and it needs no pane; the card's own early words are core's
/// codes; every refusal is a sentence.
@MainActor
final class HERDR6Tests: XCTestCase {
    private func fixtures() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["OMODACHI_CORE_FIXTURES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: fixtures().appendingPathComponent(name)))
    }

    // MARK: - Wire

    func testCoresFoldersAndCreateRepliesDecode() throws {
        let offered = try decode(HerdrFoldersDTO.self, "herdr-folders.json")
        XCTAssertEqual(offered.recent?.map(\.display), ["~/Work/omodachi", "~/code"])
        XCTAssertEqual(offered.common?.map(\.display), ["~", "~/Work", "~/Projects", "~/code"])
        XCTAssertNil(offered.browse)
        let browse = try XCTUnwrap(decode(HerdrFoldersDTO.self, "herdr-folders-browse.json").browse)
        XCTAssertEqual(browse.display, "~/Work")
        XCTAssertEqual(browse.parent?.display, "~")
        XCTAssertEqual(browse.dirs.map(\.name), ["notes", "omodachi"])
        XCTAssertFalse(browse.truncated)
        let made = try decode(HerdrWorkspaceCreatedDTO.self, "herdr-workspace-create.json")
        XCTAssertEqual(made.selected, "work")
        XCTAssertEqual(made.workspace.pane, "w3:p1")
        XCTAssertFalse(made.workspace.focused, "made without moving the computer")
        XCTAssertEqual(made.workspace.display, "~/Work/omodachi")
    }

    private func client() throws -> CompanionHostClient {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        return CompanionHostClient(
            configuration: try CompanionHostConfiguration(endpoint: XCTUnwrap(URL(string: "https://fixture.invalid:8443"))),
            credentials: FixtureCredential(), pinnedFingerprint: nil,
            session: URLSession(configuration: options))
    }

    func testTheClientAsksTheTwoRoutesAndRefusesInWords() async throws {
        let client = try client()
        try await client.connect()
        let folders = try String(contentsOf: fixtures().appendingPathComponent("herdr-folders.json"), encoding: .utf8)
        CompanionURLProtocol.storage.set("/v1/herdr/folders", body: folders)
        _ = try await client.herdrFolders()
        XCTAssertNil(CompanionURLProtocol.storage.requests.last?.url?.query)
        _ = try await client.herdrFolders(under: "~/a+b c", hidden: true)
        let browsed = try XCTUnwrap(CompanionURLProtocol.storage.requests.last?.url)
        let items = URLComponents(url: browsed, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "under" })?.value, "~/a+b c")
        XCTAssertTrue(browsed.absoluteString.contains("%2B"), "a + in a folder name is not a space to core")
        XCTAssertEqual(items.first(where: { $0.name == "hidden" })?.value, "1")

        let made = try String(contentsOf: fixtures().appendingPathComponent("herdr-workspace-create.json"), encoding: .utf8)
        CompanionURLProtocol.storage.set("/v1/herdr/sessions/work/workspaces", body: made)
        let value = try await client.herdrCreateWorkspace(session: "work", cwd: "~/Work/omodachi", name: "omodachi")
        XCTAssertEqual(value.workspace.id, "w3")
        let request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/herdr/sessions/work/workspaces")

        let refused = try String(contentsOf: fixtures().appendingPathComponent("http-error-herdr-folder-private.json"),
                                 encoding: .utf8)
        CompanionURLProtocol.storage.set("/v1/herdr/sessions/work/workspaces", status: 400, body: refused)
        do {
            _ = try await client.herdrCreateWorkspace(session: "work", cwd: "~/.ssh", name: nil)
            XCTFail("core refused it")
        } catch let error as HerdrRequestError {
            XCTAssertEqual(error.code, "folder_private")
            XCTAssertEqual(error.userMessage, Strings.reasonFolderPrivate)
        }
        CompanionURLProtocol.storage.set("/v1/herdr/folders", status: 404,
                                         body: #"{"error":{"code":"folder_not_found","message":"x"}}"#)
        do {
            _ = try await client.herdrFolders(under: "~/nope")
            XCTFail("core refused it")
        } catch let error as HerdrRequestError {
            XCTAssertEqual(error.userMessage, Strings.reasonFolderNotFound)
        }
        // A session name this client will not spell never leaves the device.
        let before = CompanionURLProtocol.storage.requests.count
        do {
            _ = try await client.herdrCreateWorkspace(session: "../x", cwd: "~", name: nil)
            XCTFail("refused before sending")
        } catch {}
        XCTAssertEqual(CompanionURLProtocol.storage.requests.count, before)
    }

    // MARK: - The More menu

    func testTheMenuHasItAndItNeedsNoPane() {
        XCTAssertTrue(HerdrControlAction.menu.contains(.newWorkspace))
        XCTAssertFalse(HerdrControlAction.newWorkspace.confirms)
        XCTAssertFalse(HerdrControlAction.newWorkspace.title.isEmpty)
        XCTAssertEqual(HerdrControlMapper.request(.newWorkspace, layout: nil, selected: nil), .newWorkspace)
    }

    // MARK: - The card's own words

    func testTheCardsEarlyWordsAreCoresCodes() {
        XCTAssertNil(HerdrStore.folderProblem("~/Work"))
        XCTAssertNil(HerdrStore.folderProblem("/etc"), "outside the home folder is core's to say, with its reason")
        for bad in ["", "   ", "a\nb", "x\u{7f}", String(repeating: "x", count: 4097)] {
            XCTAssertEqual(HerdrStore.folderProblem(bad), "invalid_folder", bad.prefix(8).description)
        }
        XCTAssertNil(HerdrStore.workspaceNameProblem(""))
        XCTAssertNil(HerdrStore.workspaceNameProblem("项目 2"))
        XCTAssertNil(HerdrStore.workspaceNameProblem(String(repeating: "x", count: 64)))
        for bad in [String(repeating: "x", count: 65), "a\tb"] {
            XCTAssertEqual(HerdrStore.workspaceNameProblem(bad), "invalid_workspace_name")
        }
    }

    func testEveryNewReasonIsASentenceNotACode() {
        for code in ["invalid_folder", "folder_outside_home", "folder_private", "folder_not_found", "folder_unreadable",
                     "invalid_workspace_name"] {
            XCTAssertEqual(ReasonText.knownCodes[code], .herdr, code)
            let sentence = ReasonText.message(code, domain: .herdr)
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertFalse(sentence.contains(code), code)
            XCTAssertNotEqual(sentence, ReasonText.unknown(code, domain: .herdr), code)
        }
        XCTAssertTrue(Strings.herdrNewWorkspaceDetail("h6test").contains("h6test"))
    }

    // MARK: - The store

    private var home: HomeStore?

    private func store() -> HerdrStore {
        let defaults = UserDefaults(suiteName: "herdr6-\(UUID().uuidString)")!
        let home = HomeStore(defaults: defaults, clientFactory: { _, _ in HerdrSixNoService() }, autoConnect: false)
        self.home = home
        return HerdrStore(home: home)
    }

    func testABadFolderOrNameIsSaidInTheCardAndNothingIsMade() {
        let store = store()
        store.openNewWorkspace()
        XCTAssertTrue(store.newWorkspaceOpen)
        // HERDR-11: an empty folder is the home folder now; a control
        // character is still not a folder.
        store.createWorkspace(path: "a\u{1}b", name: "")
        XCTAssertEqual(store.newWorkspaceError, ReasonText.message("invalid_folder", domain: .herdr))
        XCTAssertFalse(store.creatingWorkspace)
        store.createWorkspace(path: "~/Work", name: String(repeating: "x", count: 65))
        XCTAssertEqual(store.newWorkspaceError, ReasonText.message("invalid_workspace_name", domain: .herdr))
        XCTAssertFalse(store.creatingWorkspace)
        XCTAssertNil(store.pendingWorkspacePane)
        // One card at a time: the new-session card closes this one.
        store.openNewSession()
        XCTAssertFalse(store.newWorkspaceOpen)
        XCTAssertTrue(store.newSessionOpen)
        store.openNewWorkspace()
        XCTAssertFalse(store.newSessionOpen)
        store.cancelNewWorkspace()
        XCTAssertFalse(store.newWorkspaceOpen)
        XCTAssertNil(store.newWorkspaceError)
        XCTAssertNil(store.folderBrowse)
    }
}

/// A host that is never reached: the store tests above stop before any call.
private struct HerdrSixNoService: CompanionServing {
    func connect() async throws { throw CompanionHostError.notConnected }
    func disconnect() async {}
    func fetchState() async throws -> HostStateDTO { throw CompanionHostError.notConnected }
    func fetchSnapshot() async throws -> CompanionSnapshot { throw CompanionHostError.notConnected }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter],
                targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse {
        throw CompanionHostError.notConnected
    }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse {
        throw CompanionHostError.notConnected
    }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
