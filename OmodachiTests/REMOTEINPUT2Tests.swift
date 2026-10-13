import RemoteInputCore
import UIKit
import XCTest
@testable import Omodachi

/// REMOTE-INPUT-2. Type in the App, send to the computer — and the extend
/// rule that came with it (ROTATE-1).
@MainActor final class RemoteComposeTextTests: XCTestCase {
    func testLineBreaksAreNormalisedAndUntypableControlsAreDropped() {
        XCTAssertEqual(RemoteComposeText.normalized("a\r\nb\rc\nd"), "a\nb\nc\nd")
        XCTAssertEqual(RemoteComposeText.normalized("x\u{1b}y\u{7f}z\tq"), "xyz\tq")
        XCTAssertEqual(RemoteComposeText.normalized("你好👍🏽é"), "你好👍🏽é")
    }

    /// REMOTE-INPUT-2b: the return key's send ends with Return; insert only
    /// does not; an empty draft types nothing either way.
    func testTheReturnKeyEndsWithReturnInsertDoesNotAndEmptySendsNothing() {
        XCTAssertEqual(RemoteComposeText.payload("Hello, World!", pressReturn: false), "Hello, World!")
        XCTAssertEqual(RemoteComposeText.payload("Hello, World!", pressReturn: true), "Hello, World!\n")
        XCTAssertEqual(RemoteComposeText.payload("\u{1b}", pressReturn: true), "")
        XCTAssertEqual(RemoteComposeText.lineBreaks(in: "ls\r\npwd\n"), 2)
        XCTAssertEqual(RemoteComposeText.lineBreaks(in: "one line"), 0)
    }

    /// The limit is core's, counted the way core counts (Python's `len`, so
    /// Unicode scalars, and UTF-8 bytes), and shown before Send.
    func testTheLimitIsCountedTheWayCoreCountsIt() throws {
        let limits = RemoteComposeLimits(maxChars: 1024, maxBytes: 4096)
        XCTAssertNil(limits.overflow(String(repeating: "x", count: 1024)))
        XCTAssertEqual(limits.overflow(String(repeating: "x", count: 1025)), .characters(count: 1025, limit: 1024))
        // 1 400 Chinese characters are over both; characters are named first.
        XCTAssertEqual(limits.overflow(String(repeating: "你", count: 1400)), .characters(count: 1400, limit: 1024))
        // 1 000 emoji are 1 000 scalars but 4 000 bytes: fine; 1 024 are not.
        XCTAssertNil(limits.overflow(String(repeating: "👍", count: 1000)))
        XCTAssertEqual(RemoteComposeLimits(maxChars: 2000, maxBytes: 4096).overflow(String(repeating: "👍", count: 1025)),
                       .bytes(count: 4100, limit: 4096))
        // The fixture core publishes.
        let data = try Data(contentsOf: XCTUnwrap(Bundle(for: RemoteComposeTextTests.self)
            .url(forResource: "remote-capabilities", withExtension: "json", subdirectory: "CoreFixtures")))
        let capabilities = try JSONDecoder().decode(RemoteCapabilitiesDTO.self, from: data)
        XCTAssertEqual(RemoteComposeLimits.from(capabilities.text_input), limits)
        XCTAssertEqual(capabilities.text_input?.compose, true)
        XCTAssertEqual(RemoteComposeLimits.from(nil), RemoteComposeText.fallbackLimits)
    }

    func testTheSendIDIsOnlyEncodedWhenThereIsOne() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteTextRequest(text: "a"))) as? [String: Any]
        XCTAssertEqual(plain?.keys.sorted(), ["text"])
        let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteTextRequest(text: "a", id: "send-0001"))) as? [String: Any]
        XCTAssertEqual(sent?.keys.sorted(), ["id", "text"])
    }
}

/// Which keys a focused field gives the host, with a hardware keyboard too.
final class RemoteComposePassthroughTests: XCTestCase {
    typealias P = RemoteComposePassthrough

    func testAnEmptyFieldPassesEditingAndNavigationKeysThrough() {
        for usage in [P.backspace, P.returnKey, P.tab, P.escape, P.left, P.right, P.up, P.down, 0x4A, 0x4D, 0x3A] as [UInt16] {
            XCTAssertEqual(P.decide(usage: usage, modifiers: [], fieldEmpty: true, composing: false), .hold(usage: usage),
                           "usage \(usage)")
        }
        // A letter is text, even on an empty field.
        XCTAssertEqual(P.decide(usage: 0x04, modifiers: [], fieldEmpty: true, composing: false), .local)
        XCTAssertEqual(P.decide(usage: 0x04, modifiers: .shift, fieldEmpty: true, composing: false), .local)
    }

    func testAFieldWithWordsKeepsEveryKey() {
        for usage in [P.backspace, P.returnKey, P.left, P.escape] {
            XCTAssertEqual(P.decide(usage: usage, modifiers: [], fieldEmpty: false, composing: false), .local)
        }
        XCTAssertEqual(P.decide(usage: 0x06, modifiers: .control, fieldEmpty: false, composing: false), .local)
    }

    func testShortcutsOnAnEmptyFieldAreTheHostsButEditingChordsStayLocal() {
        XCTAssertEqual(P.decide(usage: 0x06, modifiers: .control, fieldEmpty: true, composing: false),
                       .chord(usage: 0x06, modifiers: .control))
        XCTAssertEqual(P.decide(usage: P.returnKey, modifiers: .superKey, fieldEmpty: true, composing: false),
                       .chord(usage: P.returnKey, modifiers: .superKey))
        XCTAssertEqual(P.decide(usage: P.left, modifiers: .shift, fieldEmpty: true, composing: false),
                       .chord(usage: P.left, modifiers: .shift))
        // ⌘V pastes into the field, ⌘Z undoes in it — whatever is in it.
        XCTAssertEqual(P.decide(usage: 0x19, modifiers: .superKey, fieldEmpty: true, composing: false), .local)
        XCTAssertEqual(P.decide(usage: 0x1D, modifiers: .superKey, fieldEmpty: true, composing: false), .local)
    }

    func testAPinyinCompositionAndABareModifierAreNeverPassedOn() {
        XCTAssertEqual(P.decide(usage: P.returnKey, modifiers: [], fieldEmpty: true, composing: true), .local)
        XCTAssertEqual(P.decide(usage: P.backspace, modifiers: [], fieldEmpty: true, composing: true), .local)
        XCTAssertEqual(P.decide(usage: 0xE0, modifiers: .control, fieldEmpty: true, composing: false), .local)
    }

    func testTheVNCLegHasAKeysymForEveryPassedKeyAndTheKeysRow() {
        for usage in P.navigation { XCTAssertNotNil(VNCTyping.keysym(usage: usage), "usage \(usage)") }
        for cap in RemoteKeyCap.row { XCTAssertNotNil(VNCTyping.keysym(usage: cap.usage), cap.id) }
        XCTAssertEqual(VNCTyping.keysym(usage: P.escape), 0xFF1B)
        XCTAssertEqual(VNCTyping.keysym(usage: 0x06), 0x63) // the c of ^C
        XCTAssertEqual(VNCTyping.modifierKeysyms([.control, .shift]), [0xFFE3, 0xFFE1])
    }
}

/// The composer on its own: a send is typed once, waits for the picture, and
/// keeps the draft whenever it is not known to have been typed.
@MainActor final class RemoteComposerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "omodachi.remote-input-2.tests")
        defaults.removePersistentDomain(forName: "omodachi.remote-input-2.tests")
    }

    /// A composer wired to a recording host that answers from `outcomes`.
    private func make(outcomes: [RemoteComposeOutcome] = [], ready: Bool = true,
                      session: String? = "rs_a") -> (RemoteComposer, Recorder) {
        let composer = RemoteComposer(defaults: defaults)
        let recorder = Recorder(outcomes: outcomes, ready: ready, session: session)
        composer.apply(.init(available: true, layout: "us", variant: nil, max_chars: 1024, max_bytes: 4096, compose: true))
        composer.currentSession = { recorder.session }
        composer.isReady = { recorder.ready && recorder.session == $0 }
        composer.deliver = { session, text, id in recorder.deliver(session, text, id) }
        composer.readyWait = .milliseconds(300)
        composer.readyPoll = .milliseconds(10)
        composer.retryDelays = [.milliseconds(5), .milliseconds(5), .milliseconds(5)]
        composer.sentLinger = .seconds(60)
        return (composer, recorder)
    }

    @MainActor final class Recorder {
        var outcomes: [RemoteComposeOutcome]
        var ready: Bool
        var session: String?
        private(set) var calls: [(session: String, text: String, id: String)] = []
        init(outcomes: [RemoteComposeOutcome], ready: Bool, session: String?) {
            self.outcomes = outcomes; self.ready = ready; self.session = session
        }
        func deliver(_ session: String, _ text: String, _ id: String) -> RemoteComposeOutcome {
            calls.append((session, text, id))
            return outcomes.isEmpty ? .typed : outcomes.removeFirst()
        }
    }

    private func settle(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
    }

    func testSendTypesTheDraftOnceAndClearsTheField() async {
        let (composer, host) = make()
        composer.draft = "你好世界"
        composer.send()
        await settle("never sent") { composer.phase == .sent }
        XCTAssertEqual(host.calls.map(\.text), ["你好世界\n"], "typed, then Return")
        XCTAssertEqual(composer.draft, "")
        // A second tap with nothing in the field does nothing.
        composer.send()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(host.calls.count, 1)
    }

    /// Send and Return in the same instant are one send.
    func testTwoPressesAtOnceAreOneSend() async {
        let (composer, host) = make()
        composer.draft = "once"
        composer.send()
        composer.send()
        await settle("never sent") { composer.phase == .sent }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(host.calls.count, 1)
        XCTAssertEqual(composer.sendIDs.count, 1)
    }

    /// The press is one id; a lost reply is retried with that same id — the
    /// host types an id once — never with a new one.
    func testALostReplyIsRetriedWithTheSameIDNeverANewOne() async {
        let (composer, host) = make(outcomes: [.lost, .lost, .typed])
        composer.draft = "youtube.com"
        composer.send()
        await settle("never sent") { composer.phase == .sent }
        XCTAssertEqual(host.calls.count, 3)
        XCTAssertEqual(Set(host.calls.map(\.id)).count, 1, "every attempt of one press carries one id")
        XCTAssertEqual(composer.sendIDs.count, 1)
    }

    func testAReplyThatNeverComesKeepsTheDraftAndSaysSo() async {
        let (composer, host) = make(outcomes: [.lost, .lost, .lost, .lost, .lost])
        composer.draft = "rm -rf build"
        composer.send()
        await settle("never gave up") { if case .failed = composer.phase { true } else { false } }
        XCTAssertEqual(composer.phase, .failed(Strings.remoteComposeUnconfirmed))
        XCTAssertEqual(composer.draft, "rm -rf build", "a text not known to be typed is not thrown away")
        XCTAssertEqual(host.calls.count, 4, "one try and three retries")
        XCTAssertEqual(Set(host.calls.map(\.id)).count, 1)
    }

    /// Insert only puts the words in and presses nothing; Keys mode is still
    /// remembered per computer; the first build's stored `enterAfter` is
    /// ignored and dropped on the next write.
    func testInsertOnlyTypesNoReturnAndKeysModeIsRememberedPerComputer() async {
        let (composer, host) = make()
        defaults.set(["enterAfter": true, "keysMode": false], forKey: RemoteComposer.storageKey("https://a.invalid:8099"))
        composer.configure(host: "https://a.invalid:8099")
        composer.draft = "Hello, World!"
        composer.insert()
        await settle("never inserted") { composer.phase == .sent }
        XCTAssertEqual(host.calls.first?.text, "Hello, World!", "no Return, whatever the old switch said")

        composer.configure(host: "https://b.invalid:8099")
        composer.keysMode = true
        composer.configure(host: "https://a.invalid:8099")
        XCTAssertFalse(composer.keysMode)
        composer.keysMode = true
        XCTAssertEqual(defaults.dictionary(forKey: RemoteComposer.storageKey("https://a.invalid:8099"))?.keys.sorted(),
                       ["keysMode"], "the old preference is gone after a write")
        composer.configure(host: "https://b.invalid:8099")
        XCTAssertTrue(composer.keysMode)
    }

    func testInsertNeedsWords() async {
        let (composer, host) = make()
        composer.insert()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(host.calls.isEmpty)
        XCTAssertFalse(composer.canSend)
    }

    /// Multi-line paste: `wtype` types each `\n` as Return, so a draft with
    /// line breaks asks first, and says how many Returns that is.
    func testADraftWithLineBreaksAsksFirst() async {
        let (composer, host) = make()
        composer.draft = "cd ~/src\r\nmake"
        composer.send()
        XCTAssertEqual(composer.phase, .confirmLines(1, pressReturn: true))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(host.calls.isEmpty)
        composer.cancelPending()
        XCTAssertEqual(composer.phase, .editing)
        XCTAssertEqual(composer.draft, "cd ~/src\r\nmake")
        composer.send()
        composer.confirmSend()
        await settle("never sent") { composer.phase == .sent }
        XCTAssertEqual(host.calls.map(\.text), ["cd ~/src\nmake\n"], "the line breaks, then the Return pressed")
        // Insert only asks too, and its answer types no final Return.
        composer.draft = "a\nb"
        composer.insert()
        XCTAssertEqual(composer.phase, .confirmLines(1, pressReturn: false))
        composer.confirmSend()
        await settle("never inserted") { host.calls.count == 2 && composer.phase == .sent }
        XCTAssertEqual(host.calls.last?.text, "a\nb")
    }

    func testADraftOverTheLimitCannotBeSent() {
        let (composer, _) = make()
        composer.apply(.init(available: true, layout: "us", variant: nil, max_chars: 8, max_bytes: 4096, compose: true))
        composer.draft = "123456789"
        XCTAssertEqual(composer.overflow, .characters(count: 10, limit: 8))
        XCTAssertFalse(composer.canSend)
        composer.draft = "12345678"
        XCTAssertEqual(composer.overflow, .characters(count: 9, limit: 8), "the return key's Return counts")
        composer.draft = "1234567"
        XCTAssertNil(composer.overflow)
    }

    /// While the picture reconnects the send waits, then goes, once.
    func testASendWhileReconnectingWaitsThenGoesOnce() async {
        let (composer, host) = make(ready: false)
        composer.draft = "nihao"
        composer.send()
        XCTAssertEqual(composer.phase, .waiting)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(host.calls.isEmpty, "nothing is typed blind")
        host.ready = true
        await settle("never sent") { composer.phase == .sent }
        XCTAssertEqual(host.calls.count, 1)
    }

    func testAPictureThatDoesNotComeBackSendsNothingAndKeepsTheDraft() async {
        let (composer, host) = make(ready: false)
        composer.draft = "nihao"
        composer.send()
        await settle("never gave up") { composer.phase == .failed(Strings.remoteComposeNotReconnected) }
        XCTAssertTrue(host.calls.isEmpty)
        XCTAssertEqual(composer.draft, "nihao")
    }

    /// Never into a different session: the send belongs to the session it
    /// was pressed in.
    func testASessionThatChangesUnderTheSendIsNeverTypedInto() async {
        let (composer, host) = make(ready: false)
        composer.draft = "secret plan"
        composer.send()
        host.session = "rs_b"
        host.ready = true
        await settle("never noticed") { composer.phase == .failed(Strings.remoteComposeSessionEnded) }
        XCTAssertTrue(host.calls.isEmpty)
        XCTAssertEqual(composer.draft, "secret plan")
    }

    func testANotReadyAnswerWaitsAndSendsTheSameIDAgain() async {
        let (composer, host) = make(outcomes: [.notReady, .typed])
        composer.draft = "abc"
        composer.send()
        await settle("never sent") { composer.phase == .sent }
        XCTAssertEqual(host.calls.count, 2)
        XCTAssertEqual(host.calls[0].id, host.calls[1].id)
    }

    func testAHostWithoutComposeHasNoField() {
        let composer = RemoteComposer(defaults: defaults)
        composer.apply(.init(available: true, layout: "us", variant: nil))
        XCTAssertFalse(composer.hostSupportsCompose)
        XCTAssertFalse(composer.usesField)
        composer.draft = "x"
        XCTAssertFalse(composer.canSend)
    }
}

/// The compose bar as the session controller runs it.
@MainActor final class RemoteComposeControllerTests: XCTestCase {
    private func make(mode: RemoteMode = .extend, compose: Bool = true) async
    -> (RemoteSessionController, FakeRemoteHost, FakeBackend) {
        let host = FakeRemoteHost()
        let backend = FakeBackend()
        let controller = RemoteSessionController(service: host, driver: backend,
                                                 heartbeatInterval: .seconds(600), backgroundGrace: .seconds(600))
        controller.backendChoice = .vnc
        controller.mode = mode
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        controller.composer.apply(.init(available: true, layout: "us", variant: nil,
                                        max_chars: compose ? 1024 : nil, max_bytes: compose ? 4096 : nil,
                                        compose: compose ? true : nil))
        controller.composer.keysMode = false
        controller.composer.readyPoll = .milliseconds(10)
        controller.composer.retryDelays = [.milliseconds(5), .milliseconds(5), .milliseconds(5)]
        controller.composer.sentLinger = .seconds(60)
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never streamed") { controller.isStreaming }
        return (controller, host, backend)
    }

    private func settle(_ message: String, _ predicate: @escaping () async -> Bool) async {
        for _ in 0..<400 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
    }

    func testTheKeyboardIsTheComposeBarAndThePictureLetsGoOfIt() async {
        let (controller, _, backend) = await make()
        let focus = controller.composer.focusRequest
        controller.toggleKeyboard()
        XCTAssertTrue(controller.keyboardVisible, "the bar is up")
        XCTAssertTrue(backend.composeOwnsKeyboard, "the picture must not take the keyboard back")
        XCTAssertFalse(backend.keyboardUp, "the per-key keyboard stays down")
        XCTAssertEqual(controller.composer.focusRequest, focus + 1, "the field takes the keyboard")
        // Three fingers are the same switch.
        backend.keyboardTap?()
        XCTAssertFalse(controller.keyboardVisible)
        XCTAssertFalse(backend.composeOwnsKeyboard, "a hardware keyboard goes straight to the host again")
    }

    func testSendTypesThroughTheTextRouteExactlyOnceWithOneID() async {
        let (controller, host, _) = await make()
        controller.toggleKeyboard()
        controller.composer.draft = "Hello, World!"
        controller.composer.send()
        await settle("never sent") { controller.composer.phase == .sent }
        let requests = await host.textRequests
        XCTAssertEqual(requests.map(\.text), ["Hello, World!\n"])
        XCTAssertNotNil(requests.first?.id)
        let typed = await host.typedTexts
        XCTAssertEqual(typed, ["Hello, World!\n"])
    }

    /// The reply to a typed send is lost: the retry carries the same id, the
    /// host answers "already typed", and the computer has the text once.
    func testALostReplyNeverTypesTwice() async {
        let (controller, host, _) = await make()
        await host.setTextFailures([nil])
        controller.toggleKeyboard()
        controller.composer.draft = "你好世界"
        controller.composer.send()
        await settle("never sent") { controller.composer.phase == .sent }
        let requests = await host.textRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].id, requests[1].id)
        let typed = await host.typedTexts
        XCTAssertEqual(typed, ["你好世界\n"], "typed once")
        XCTAssertEqual(controller.composer.draft, "")
    }

    /// An empty field: Backspace, Return and the keys row reach the host as
    /// keys, so a terminal stays usable without typing into the field.
    func testAnEmptyFieldPassesKeysThroughAndTheKeysRowIsAlwaysKeys() async {
        let (controller, _, backend) = await make()
        controller.toggleKeyboard()
        let view = RemoteComposeTextView(frame: .zero, textContainer: nil)
        view.passKey = { usage, down in controller.passKey(usage: usage, down: down) }
        view.deleteBackward()
        XCTAssertEqual(backend.passed, [.key(0x2A, true), .key(0x2A, false)])
        view.text = "draft"
        view.deleteBackward()
        XCTAssertEqual(view.text, "draf", "with words in it, Backspace edits the field")
        XCTAssertEqual(backend.passed.count, 2)

        for cap in RemoteKeyCap.row { controller.tapKey(cap) }
        XCTAssertEqual(backend.passed.dropFirst(2).prefix(2), [.key(0x29, true), .key(0x29, false)], "esc")
        XCTAssertEqual(backend.passed.last, .chord(0x06, RemoteModifiers.control.rawValue), "^C")
    }

    func testReturnOnAnEmptyFieldIsReturnOnTheComputerAndWithWordsItSends() async {
        let (controller, host, backend) = await make()
        controller.toggleKeyboard()
        let field = RemoteComposeField(controller: controller, composer: controller.composer, height: .constant(44))
        let coordinator = RemoteComposeField.Coordinator(field)
        let view = UITextView()
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "\n"))
        XCTAssertEqual(backend.passed, [.key(0x28, true), .key(0x28, false)])
        controller.composer.draft = "ls"
        view.text = "ls"
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 2, length: 0), replacementText: "\n"))
        await settle("never sent") { controller.composer.phase == .sent }
        let typed = await host.typedTexts
        XCTAssertEqual(typed, ["ls\n"], "the words and their Return, in one request")
        XCTAssertEqual(backend.passed.count, 2, "the Return goes with the text, not as a second key")
    }

    /// Keys mode is the per-key keyboard on the picture (vim, games), and the
    /// switch back puts the field in charge again.
    func testKeysModeIsThePerKeyKeyboard() async {
        let (controller, _, backend) = await make()
        controller.toggleKeyboard()
        controller.setKeysMode(true)
        XCTAssertTrue(controller.keyboardVisible)
        XCTAssertTrue(backend.keyboardUp, "the picture's own keyboard")
        XCTAssertFalse(backend.composeOwnsKeyboard)
        controller.setKeysMode(false)
        XCTAssertFalse(backend.keyboardUp)
        XCTAssertTrue(backend.composeOwnsKeyboard)
        // And it is remembered: the next summon is the per-key keyboard.
        controller.hideKeyboard()
        controller.setKeysMode(true)
        controller.toggleKeyboard()
        XCTAssertTrue(backend.keyboardUp)
    }

    func testAHostWithoutComposeGetsThePerKeyKeyboard() async {
        let (controller, _, backend) = await make(compose: false)
        controller.toggleKeyboard()
        XCTAssertTrue(backend.keyboardUp)
        XCTAssertFalse(backend.composeOwnsKeyboard)
    }

    /// The draft is the App's: it survives the app leaving and coming back,
    /// and a reconnect of the picture.
    func testTheDraftSurvivesBackgroundAndReconnect() async {
        let (controller, _, backend) = await make()
        controller.toggleKeyboard()
        controller.composer.draft = "半句话"
        controller.setForeground(false)
        await settle("not paused") { controller.pausedForBackground }
        controller.setForeground(true)
        await settle("not dialled again") { await backend.connections.count == 2 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never streamed again") { controller.isStreaming }
        XCTAssertEqual(controller.composer.draft, "半句话")
    }

    /// A send pressed while the picture is being dialled again waits for it,
    /// then goes once into the same session.
    func testASendWhileThePictureReconnectsWaitsForIt() async {
        let (controller, host, backend) = await make()
        controller.toggleKeyboard()
        controller.setForeground(false)
        await settle("not paused") { controller.pausedForBackground }
        controller.composer.draft = "after"
        controller.composer.insert()
        XCTAssertEqual(controller.composer.phase, .waiting)
        controller.setForeground(true)
        await settle("not dialled again") { await backend.connections.count == 2 }
        try? await Task.sleep(for: .milliseconds(40))
        let early = await host.textRequests
        XCTAssertTrue(early.isEmpty, "nothing typed while the picture is away")
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never sent") { controller.composer.phase == .sent }
        let typed = await host.typedTexts
        XCTAssertEqual(typed, ["after"])
    }

    func testAPanelTakesTheBarDownAndTheDraftStays() async {
        let (controller, _, backend) = await make()
        controller.toggleKeyboard()
        controller.composer.draft = "keep me"
        controller.setPanelVisible(true)
        XCTAssertFalse(controller.keyboardVisible)
        XCTAssertFalse(backend.composeOwnsKeyboard)
        XCTAssertEqual(controller.composer.draft, "keep me")
    }

    func testTheHostsAnswersMapToWhatTheBarSays() {
        typealias C = RemoteSessionController
        XCTAssertEqual(C.composeOutcome(.init(code: "session_not_ready", status: 409)), .notReady)
        XCTAssertEqual(C.composeOutcome(.init(code: "session_not_found", status: 404)), .sessionGone)
        XCTAssertEqual(C.composeOutcome(.init(code: "permission_denied", status: 403)), .sessionGone)
        XCTAssertEqual(C.composeOutcome(.init(code: "remote_text_failed", status: 503)), .refused(Strings.remoteTypingFailed))
        XCTAssertEqual(C.composeOutcome(.init(code: "invalid_request", status: 400)), .refused(Strings.remoteComposeRefused))
        XCTAssertEqual(C.composeOutcome(.init(code: "internal_error", status: 500)), .lost)
    }

    /// The bar is a layer: bringing it up and putting it away never re-plans.
    func testTheBarNeverAsksTheHostToRePlan() async {
        let (controller, host, _) = await make(mode: .takeover)
        controller.toggleKeyboard()
        controller.setKeysMode(true)
        controller.setKeysMode(false)
        controller.hideKeyboard()
        try? await Task.sleep(for: .milliseconds(450))
        let resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 0)
    }
}

/// ROTATE-1 (Leo, 2026-10-05): "拓展模式不动啊，只有接管模式动".
@MainActor final class RotateExtendTests: XCTestCase {
    private func streaming(_ mode: RemoteMode) async -> (RemoteSessionController, FakeRemoteHost, FakeBackend) {
        let host = FakeRemoteHost()
        let backend = FakeBackend()
        let controller = RemoteSessionController(service: host, driver: backend,
                                                 heartbeatInterval: .seconds(600), backgroundGrace: .seconds(600))
        controller.backendChoice = .vnc
        controller.mode = mode
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        controller.start()
        for _ in 0..<400 where await backend.connections.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        backend.deliverFrame(RemotePixels(width: 2388, height: 1668))
        XCTAssertTrue(controller.isStreaming)
        return (controller, host, backend)
    }

    func testAnExtendSessionKeepsItsGeometryThroughATurn() async {
        let (controller, host, backend) = await streaming(.extend)
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        try? await Task.sleep(for: .milliseconds(450))
        let resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 0, "no re-plan, so no new revision")
        XCTAssertEqual(backend.connections.count, 1, "no new stream")
        XCTAssertEqual(backend.stops, 0)
        XCTAssertTrue(controller.isStreaming, "the same picture, fitted into the turned window")
        XCTAssertEqual(controller.session?.revision, 1)
        // Turning back is not a re-plan either.
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        try? await Task.sleep(for: .milliseconds(450))
        let after = await host.resizeCount()
        XCTAssertEqual(after, 0)
    }

    func testATakeoverReplansExactlyOncePerTurn() async {
        let (controller, host, backend) = await streaming(.takeover)
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        for _ in 0..<400 where await host.resizeCount() == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(450))
        let resizes = await host.resizes
        XCTAssertEqual(resizes.count, 1)
        XCTAssertEqual(resizes.first?.orientation, "portrait")
        XCTAssertEqual(backend.connections.count, 2)
    }

    /// The host run (takeover, 13:09 UTC): a panel summoned over the compose
    /// bar slid the keyboard away, the picture reported 864…873 for a moment
    /// and then its own 874 again — and the takeover re-planned to the
    /// geometry it already had. A reading that settles on the plan is not a
    /// re-plan.
    func testATakeoverReadingThatSettlesBackOnThePlanIsNotARePlan() async {
        let (controller, host, backend) = await streaming(.takeover)
        for height in [864.0, 867, 871, 873] {
            controller.viewportChanged(size: CGSize(width: 1194, height: height), orientation: "landscape_left")
        }
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        try? await Task.sleep(for: .milliseconds(450))
        let resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 0)
        XCTAssertEqual(backend.connections.count, 1)
        // A real turn after it still re-plans, once.
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        for _ in 0..<400 where await host.resizeCount() == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(400))
        let after = await host.resizeCount()
        XCTAssertEqual(after, 1)
    }

    /// The window the extend session ignored is the one the next session is
    /// planned for.
    func testTheNextSessionIsPlannedForTheTurnedWindow() async {
        let (controller, host, _) = await streaming(.extend)
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        controller.stop()
        for _ in 0..<400 where controller.phase != .idle { try? await Task.sleep(for: .milliseconds(5)) }
        controller.start()
        for _ in 0..<400 where await host.created.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        let created = await host.created
        XCTAssertEqual(created.last?.viewport_points, RemotePoints(width: 834, height: 1194))
        XCTAssertEqual(created.last?.orientation, "portrait")
    }

    /// ROTATE-2 (Leo's iPad, 17:23 AEDT): a second reading during a re-plan
    /// started a second resize over the first one's half-dialled stream, the
    /// stream failed, and the failure ended the session. Now the reading is
    /// held and planned once after the first frame, and nothing is released.
    func testAReadingDuringAReplanIsPlannedOnceAfterTheFirstFrame() async {
        let (controller, host, backend) = await streaming(.takeover)
        await host.setResizeDelay(.milliseconds(300))
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        for _ in 0..<400 where controller.phase != .resizing { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.phase, .resizing)
        // The turn is still settling: another reading, and the old stream's
        // failure arriving late.
        controller.viewportChanged(size: CGSize(width: 834, height: 1150), orientation: "portrait", source: "window")
        backend.onFailure?("The media connection failed during setup.")
        for _ in 0..<400 where backend.connections.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(controller.session, "a turn never ends the session")
        let releases = await host.releases
        XCTAssertTrue(releases.isEmpty)
        var resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 1, "one re-plan in flight at a time")
        backend.deliverFrame(RemotePixels(width: 2388, height: 1668))
        for _ in 0..<400 where await host.resizeCount() < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 2, "the held reading is planned after the first frame")
        let last = await host.resizes.last
        XCTAssertEqual(last?.viewport_points, RemotePoints(width: 834, height: 1150))
        await host.setResizeDelay(.zero)
        backend.deliverFrame(RemotePixels(width: 2388, height: 1668))
        try? await Task.sleep(for: .milliseconds(450))
        resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 2)
        XCTAssertTrue(controller.isStreaming)
    }

    /// ROTATE-2, the host run: a held turn re-planned 10 ms after the new
    /// stream's first frame, the fork could not stop a stream that had not
    /// pinged yet (`409 session_not_stopped`) and the session was failed. A
    /// new stream gets its settle time before a re-plan stops it.
    func testANewStreamSettlesBeforeAReplanStopsIt() async {
        let host = FakeRemoteHost()
        let backend = FakeBackend()
        let controller = RemoteSessionController(service: host, driver: backend, heartbeatInterval: .seconds(600),
                                                 backgroundGrace: .seconds(600), streamSettle: .milliseconds(800))
        controller.backendChoice = .vnc
        controller.mode = .takeover
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        controller.start()
        for _ in 0..<400 where backend.connections.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        backend.deliverFrame(RemotePixels(width: 2388, height: 1668))
        let framed = ContinuousClock.now
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        for _ in 0..<600 where backend.stops == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - framed, .milliseconds(750),
                                    "the fresh stream was not stopped before it settled")
        for _ in 0..<400 where await host.resizeCount() == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 1)
    }

    /// ROTATE-2: a re-plan the host answered badly dials the same session
    /// again instead of ending it.
    func testAFailedReplanDialsTheSessionAgainInsteadOfEndingIt() async {
        let (controller, host, backend) = await streaming(.takeover)
        await host.setFailNextResize(RemoteRequestError(code: "internal_error", status: 503))
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        for _ in 0..<400 where backend.connections.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(backend.connections.count, 2, "dialled again")
        XCTAssertNotNil(controller.session)
        let releases = await host.releases
        XCTAssertTrue(releases.isEmpty)
    }

    /// The two readers name a landscape differently; the shape is what counts.
    func testLandscapeLeftAndRightAreTheSamePlan() async {
        let (controller, host, _) = await streaming(.takeover)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_right")
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left", source: "window")
        try? await Task.sleep(for: .milliseconds(450))
        let resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 0)
        XCTAssertFalse(controller.viewportDiffersFromPlan)
    }

    func testTheRuleIsTheModes() {
        XCTAssertFalse(RemoteSessionController.replans(mode: .extend))
        XCTAssertTrue(RemoteSessionController.replans(mode: .takeover))
        // DUO-1 round 2: the one exception is the unfold.
        XCTAssertTrue(RemoteSessionController.replans(mode: .extend, unfolding: true))
        XCTAssertFalse(RemoteSessionController.replans(mode: .extend, unfolding: false))
    }

    // MARK: - DUO-1 round 2: a foldable opened from closed

    /// The closed iPhone Duo is 466 × 678; opened, the window is 951 × 669.
    private let closedDuo = CGSize(width: 466, height: 678)
    private let openDuo = CGSize(width: 951, height: 669)

    private func extendOnTheClosedDuo() async -> (RemoteSessionController, FakeRemoteHost, FakeBackend) {
        let (controller, host, backend) = await streaming(.extend)
        controller.unfoldWindow = .milliseconds(400)
        controller.hingeChanged(open: false)
        return (controller, host, backend)
    }

    /// Closed → open during an extend session re-plans once, for the inner screen.
    func testUnfoldingReplansAnExtendSessionOnce() async {
        let (controller, host, _) = await extendOnTheClosedDuo()
        controller.hingeChanged(open: true)
        controller.viewportChanged(size: openDuo, orientation: "landscape_left", source: "window")
        try? await Task.sleep(for: .milliseconds(450))
        let resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 1, "one re-plan to fill the inner screen")
        XCTAssertFalse(controller.viewportDiffersFromPlan)
    }

    /// The window may report before the hinge does; the held reading is re-read.
    func testAWindowThatComesBeforeTheHingeStillReplans() async {
        let (controller, host, _) = await extendOnTheClosedDuo()
        controller.viewportChanged(size: openDuo, orientation: "landscape_left", source: "window")
        try? await Task.sleep(for: .milliseconds(100))
        let before = await host.resizeCount()
        XCTAssertEqual(before, 0, "a new window alone is a turn: kept")
        controller.hingeChanged(open: true)
        try? await Task.sleep(for: .milliseconds(450))
        let after = await host.resizeCount()
        XCTAssertEqual(after, 1)
    }

    /// After the unfold, a turn is a turn again: kept.
    func testATurnAfterTheUnfoldDoesNotReplan() async {
        let (controller, host, _) = await extendOnTheClosedDuo()
        controller.hingeChanged(open: true)
        controller.viewportChanged(size: openDuo, orientation: "landscape_left", source: "window")
        try? await Task.sleep(for: .milliseconds(1_200))
        controller.viewportChanged(size: CGSize(width: 669, height: 951), orientation: "portrait", source: "window")
        try? await Task.sleep(for: .milliseconds(450))
        let resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 1, "the unfold's one re-plan and nothing for the turn")
    }

    /// Open → closed never re-plans an extend session: the output is shown scaled.
    func testClosingDoesNotReplanAnExtendSession() async {
        let (controller, host, _) = await streaming(.extend)
        controller.unfoldWindow = .milliseconds(400)
        controller.hingeChanged(open: true)
        controller.hingeChanged(open: false)
        controller.viewportChanged(size: closedDuo, orientation: "portrait", source: "window")
        try? await Task.sleep(for: .milliseconds(450))
        let resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 0)
    }

    /// The App opened on the open Duo, or a device with no hinge, has not unfolded.
    func testAHingeFirstReadOpenIsNotAnUnfold() async {
        let (controller, host, _) = await streaming(.extend)
        controller.hingeChanged(open: true)
        controller.hingeChanged(open: nil)
        controller.viewportChanged(size: openDuo, orientation: "landscape_left", source: "window")
        try? await Task.sleep(for: .milliseconds(450))
        let resizes = await host.resizeCount()
        XCTAssertEqual(resizes, 0)
    }

    func testTheUnfoldAllowanceIsOnlyClosedToOpen() {
        let now = ContinuousClock.now
        var unfold = RemoteUnfold()
        XCTAssertFalse(unfold.hinge(open: true, now: now, window: .seconds(3)), "first reading")
        XCTAssertFalse(unfold.hinge(open: false, now: now, window: .seconds(3)))
        XCTAssertTrue(unfold.hinge(open: true, now: now, window: .seconds(3)), "closed → open")
        XCTAssertTrue(unfold.allows(now: now + .seconds(1)))
        XCTAssertFalse(unfold.allows(now: now + .seconds(4)), "only for the window it opens onto")
        XCTAssertFalse(unfold.hinge(open: true, now: now, window: .seconds(3)), "half open → fully open is not another")
        XCTAssertFalse(unfold.hinge(open: false, now: now, window: .seconds(3)))
        XCTAssertFalse(unfold.allows(now: now), "closing ends it")
    }
}
