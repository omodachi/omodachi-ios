import SwiftUI
import XCTest
@testable import Omodachi

/// HERDR-5: a stopped session is started from the switcher and a new one made;
/// the More menu lost three items; the panels stop at the keyboard UIKit says
/// is on screen.
@MainActor
final class HERDR5Tests: XCTestCase {
    private func fixtures() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["OMODACHI_CORE_FIXTURES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
    }

    private func decode(_ name: String) throws -> HerdrSessionStartDTO {
        try JSONDecoder().decode(HerdrSessionStartDTO.self,
                                 from: Data(contentsOf: fixtures().appendingPathComponent(name)))
    }

    // MARK: - Wire

    func testCoresStartAndCreateRepliesDecode() throws {
        let start = try decode("herdr-session-start.json")
        XCTAssertEqual(start.selected, "default")
        XCTAssertTrue(start.started)
        XCTAssertFalse(start.created)
        let create = try decode("herdr-session-create.json")
        XCTAssertEqual(create.selected, "h5test")
        XCTAssertTrue(create.created)
        XCTAssertEqual(create.owned, "omodachi")
    }

    func testANewNameIsCoresNewSessionAlphabet() {
        for good in ["h5test", "my.proj_1", "A-b", String(repeating: "x", count: 32), "7"] {
            XCTAssertTrue(CompanionHostClient.isNewHerdrSession(good), good)
        }
        for bad in [".", "..", ".hidden", "-x", "_x", "a/b", "a b", "", String(repeating: "x", count: 33), "名字", "x;y"] {
            XCTAssertFalse(CompanionHostClient.isNewHerdrSession(bad), bad)
        }
    }

    func testEveryNewReasonIsASentenceNotACode() {
        for code in ["invalid_session", "invalid_session_name", "herdr_session_exists", "herdr_session_start_failed"] {
            XCTAssertEqual(ReasonText.knownCodes[code], .herdr, code)
            let sentence = ReasonText.message(code, domain: .herdr)
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertFalse(sentence.contains(code), code)
            XCTAssertNotEqual(sentence, ReasonText.unknown(code, domain: .herdr), code)
        }
    }

    // MARK: - The More menu

    func testTheMoreMenuIsTheShapeOfThePaneAndNothingElse() {
        // HERDR-6 added "New workspace…" beside "New tab"; HERDR-13 took out
        // split right, split down and zoom.
        XCTAssertEqual(HerdrControlAction.menu, [.newWorkspace, .newTab, .closeTab, .close])
        XCTAssertEqual(Set(HerdrControlAction.allCases.map(\.rawValue)),
                       ["newWorkspace", "newTab", "closeTab", "close", "previousPane", "nextPane"])
    }

    // MARK: - The store

    /// `HerdrStore` holds its home `unowned`, as the app's stores do; the
    /// test keeps it alive for as long as the store is used.
    private var home: HomeStore?

    private func store() -> HerdrStore {
        let defaults = UserDefaults(suiteName: "herdr5-\(UUID().uuidString)")!
        let home = HomeStore(defaults: defaults, clientFactory: { _, _ in HerdrFiveNoService() }, autoConnect: false)
        self.home = home
        return HerdrStore(home: home)
    }

    func testABadOrTakenNameIsSaidInTheCardBeforeAnythingIsSent() {
        let store = store()
        store.openNewSession()
        XCTAssertTrue(store.newSessionOpen)
        store.createSession("..")
        XCTAssertEqual(store.newSessionError, ReasonText.message("invalid_session_name", domain: .herdr))
        XCTAssertFalse(store.creatingSession)
        store.createSession("  ")
        XCTAssertEqual(store.newSessionError, ReasonText.message("invalid_session_name", domain: .herdr))
        store.cancelNewSession()
        XCTAssertFalse(store.newSessionOpen)
        XCTAssertNil(store.newSessionError)
    }

    func testTheMirrorTapIsLeftAloneWhileTypeHoldsTheKeyboard() {
        // With no pane Type cannot start, and a tap is a no-op that must not
        // throw or start anything.
        let store = store()
        store.mirrorTapped()
        XCTAssertFalse(store.typing)
    }

    // MARK: - The keyboard

    func testOnlyADockedKeyboardCoversThePanels() {
        let window = CGRect(x: 0, y: 0, width: 402, height: 874)
        typealias Reader = KeyboardOverlapReader.Reader
        // iPhone 17, docked: 336 from its top edge down.
        XCTAssertEqual(Reader.overlap(keyboard: CGRect(x: 0, y: 538, width: 402, height: 336), window: window), 336)
        // A hardware keyboard: UIKit reports no height (iOS 27 simulator).
        XCTAssertEqual(Reader.overlap(keyboard: CGRect(x: 0, y: 874, width: 402, height: 0), window: window), 0)
        // Off the bottom (hidden), floating in the middle (iPad), outside the window.
        XCTAssertEqual(Reader.overlap(keyboard: CGRect(x: 0, y: 874, width: 402, height: 336), window: window), 0)
        XCTAssertEqual(Reader.overlap(keyboard: CGRect(x: 40, y: 300, width: 320, height: 250), window: window), 0)
        XCTAssertEqual(Reader.overlap(keyboard: CGRect(x: 900, y: 538, width: 402, height: 336), window: window), 0)
    }

    func testThePanelStopsAtTheKeyboardOrTheIndicatorNeverBoth() {
        let window = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        XCTAssertEqual(SafeAreaLayoutPolicy.stage(edge: .left, window: window).bottom, 34)
        // A keyboard up: the layout rides on it, and the indicator's inset is
        // not added on top (that was the 34-point band).
        XCTAssertEqual(SafeAreaLayoutPolicy.stage(edge: .left, window: window, keyboard: 336).bottom, 0)
        XCTAssertEqual(SafeAreaLayoutPolicy.keyboardLift(336), 336)
        XCTAssertEqual(SafeAreaLayoutPolicy.stage(edge: .left, window: window, keyboard: 336).bottom
                       + SafeAreaLayoutPolicy.keyboardLift(336), 336)
        // No keyboard (or a hidden / floating one): back to the indicator.
        XCTAssertEqual(SafeAreaLayoutPolicy.keyboardLift(0), 0)
        XCTAssertEqual(SafeAreaLayoutPolicy.stage(edge: .top, window: window, keyboard: 0).bottom, 34)
        XCTAssertEqual(SafeAreaLayoutPolicy.stage(edge: .bottom, window: window, keyboard: 336).bottom, 0)
    }
}

/// A host that is never reached: the store tests above stop before any call.
private struct HerdrFiveNoService: CompanionServing {
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
