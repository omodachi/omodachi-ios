import XCTest
import RemoteInputCore
@testable import Omodachi

/// REMOTE-INPUT-1. Leo typed "y" in Remote and the host showed "U+": the soft
/// keyboard's text went as Moonlight's UTF-8 event, which the Sunshine fork
/// types as Ctrl+Shift+U + hex. Printable ASCII now goes as the US key plus
/// Shift; what no key produces goes to core's `wtype` route.
final class RemoteInputTypingTests: XCTestCase {
    private func key(_ vk: UInt16, _ modifiers: RemoteModifiers = []) -> [RemoteInputPayload] {
        guard modifiers.contains(.shift) else {
            return [.key(.init(rawValue: vk), .down, modifiers), .key(.init(rawValue: vk), .up, modifiers)]
        }
        // Shift is its own key around the stroke (REMOTE-INPUT-1 host finding).
        let shift = VirtualKey(rawValue: 0xA0)
        return [.key(shift, .down, modifiers), .key(.init(rawValue: vk), .down, modifiers),
                .key(.init(rawValue: vk), .up, modifiers), .key(shift, .up, modifiers.subtracting(.shift))]
    }

    // MARK: the mapping

    func testTheLetterLeoTypedIsTheYKeyWithNoText() {
        var engine = KeyboardInputEngine()
        XCTAssertEqual(engine.type("y"), key(0x59))
        XCTAssertEqual(engine.type("Y"), key(0x59, .shift))
    }

    func testEveryPrintableASCIICharacterIsOneUSKey() {
        var seen: [String: Character] = [:]
        for code in UInt8(0x20)...UInt8(0x7E) {
            let character = Character(Unicode.Scalar(code))
            guard let stroke = USKeyboardText.stroke(for: character) else {
                XCTFail("no key for \(code)"); continue
            }
            XCTAssertNotNil(HIDKeyboardMapper.virtualKey(for: stroke.usage), "\(character)")
            let identity = "\(stroke.usage.rawValue)/\(stroke.shift)"
            XCTAssertNil(seen[identity], "\(character) and \(seen[identity] ?? " ") share a key")
            seen[identity] = character
        }
        XCTAssertEqual(seen.count, 95)
    }

    func testUSPunctuationSitsWhereAUSKeyboardHasIt() {
        let table: [(Character, UInt16, Bool)] = [
            ("!", 0x1E, true), ("@", 0x1F, true), ("#", 0x20, true), ("$", 0x21, true), ("%", 0x22, true),
            ("^", 0x23, true), ("&", 0x24, true), ("*", 0x25, true), ("(", 0x26, true), (")", 0x27, true),
            ("-", 0x2D, false), ("_", 0x2D, true), ("=", 0x2E, false), ("+", 0x2E, true),
            ("[", 0x2F, false), ("{", 0x2F, true), ("]", 0x30, false), ("}", 0x30, true),
            ("\\", 0x31, false), ("|", 0x31, true), (";", 0x33, false), (":", 0x33, true),
            ("'", 0x34, false), ("\"", 0x34, true), ("`", 0x35, false), ("~", 0x35, true),
            (",", 0x36, false), ("<", 0x36, true), (".", 0x37, false), (">", 0x37, true),
            ("/", 0x38, false), ("?", 0x38, true), (" ", 0x2C, false), ("\t", 0x2B, false),
            ("\n", 0x28, false), ("\r", 0x28, false), ("\r\n", 0x28, false), ("0", 0x27, false), ("1", 0x1E, false)
        ]
        for (character, usage, shift) in table {
            XCTAssertEqual(USKeyboardText.stroke(for: character), KeyStroke(usage: .init(rawValue: usage), shift: shift),
                           "\(character.unicodeScalars.map { $0.value })")
        }
        for character: Character in ["你", "é", "👍", "👍🏽", "\u{1B}", "\u{7F}", "€"] {
            XCTAssertNil(USKeyboardText.stroke(for: character))
        }
    }

    func testYoutubeDotComAndReturnAreKeysOnly() {
        var engine = KeyboardInputEngine()
        let payloads = engine.type("youtube.com\n")
        XCTAssertEqual(payloads.count, 24)
        XCTAssertFalse(payloads.contains { if case .text = $0 { return true } else { return false } })
        XCTAssertEqual(Array(payloads.suffix(2)), key(0x0D))
        XCTAssertEqual(Array(payloads[14..<16]), key(0xBE))  // "."
    }

    func testHelloWorldShiftsExactlyTheCharactersThatNeedIt() {
        var engine = KeyboardInputEngine()
        let downs = engine.type("Hello, World!").compactMap { payload -> (UInt16, RemoteModifiers)? in
            guard case .key(let key, .down, let modifiers) = payload, key.rawValue != 0xA0 else { return nil }
            return (key.rawValue, modifiers)
        }
        XCTAssertEqual(downs.map(\.0), [0x48, 0x45, 0x4C, 0x4C, 0x4F, 0xBC, 0x20, 0x57, 0x4F, 0x52, 0x4C, 0x44, 0x31])
        XCTAssertEqual(downs.map { $0.1 == .shift }, [true, false, false, false, false, false, false,
                                                       true, false, false, false, false, true])
    }

    func testShiftIsItsOwnKeyAndIsReleasedAfterTheStroke() {
        var engine = KeyboardInputEngine()
        XCTAssertEqual(engine.type("H"), [
            .key(.init(rawValue: 0xA0), .down, .shift), .key(.init(rawValue: 0x48), .down, .shift),
            .key(.init(rawValue: 0x48), .up, .shift), .key(.init(rawValue: 0xA0), .up, [])])
        // Every Shift that goes down comes up again, in a long mixed string too.
        var held = 0
        for payload in engine.type("Hello, World! ~`@#$%^&*()_+-=[]{}\\|;:'\",.<>/?") {
            guard case .key(let key, let phase, _) = payload, key.rawValue == 0xA0 else { continue }
            held += phase == .down ? 1 : -1
            XCTAssertTrue((0...1).contains(held))
        }
        XCTAssertEqual(held, 0)
    }

    func testTextNoKeyProducesStaysTextAndKeepsItsPlace() {
        var engine = KeyboardInputEngine()
        XCTAssertEqual(engine.type("你好"), [.text(Data("你好".utf8))])
        let mixed = engine.type("a你好é b")
        XCTAssertEqual(mixed, key(0x41) + [.text(Data("你好é".utf8))] + key(0x20) + key(0x42))
        XCTAssertEqual(engine.type("👍🏽"), [.text(Data("👍🏽".utf8))])
        XCTAssertEqual(engine.type("\u{1B}"), [], "a control character is dropped, never typed as text")
        XCTAssertEqual(engine.type(""), [])
    }

    func testWithATextRoadNoShiftGoesDownTheStream() {
        var engine = KeyboardInputEngine()
        XCTAssertEqual(engine.type("Hello, World!\n", shiftedAsText: true),
                       [.text(Data("H".utf8))] + key(0x45) + key(0x4C) + key(0x4C) + key(0x4F) + key(0xBC) + key(0x20)
                       + [.text(Data("W".utf8))] + key(0x4F) + key(0x52) + key(0x4C) + key(0x44)
                       + [.text(Data("!".utf8))] + key(0x0D))
        XCTAssertEqual(engine.type("@#", shiftedAsText: true), [.text(Data("@#".utf8))], "a run is one request")
        // A held or latched modifier makes it a shortcut, which stays keys.
        engine.latch(.control)
        XCTAssertEqual(engine.type("T", shiftedAsText: true), key(0x54, [.control, .shift]))
        XCTAssertEqual(RemoteTypingRoute(hostText: true, asciiAsKeys: true).shiftedAsText, true)
        XCTAssertEqual(RemoteTypingRoute.keysOnly.shiftedAsText, false)
    }

    func testOnANonUSKeymapOnlySpaceReturnAndTabAreKeys() {
        var engine = KeyboardInputEngine()
        XCTAssertEqual(engine.type("zy b\n\t", asciiAsKeys: false),
                       [.text(Data("zy".utf8))] + key(0x20) + [.text(Data("b".utf8))] + key(0x0D) + key(0x09))
    }

    func testALatchedModifierIsSpentOnTheFirstStroke() {
        var engine = KeyboardInputEngine()
        engine.latch(.control)
        XCTAssertEqual(engine.type("cv"), key(0x43, .control) + key(0x56))
        engine.latch(.control)
        _ = engine.type("你")
        XCTAssertFalse(engine.hasLatchedModifiers)
    }

    func testTheControllerTypesOnlyForTheLiveGeneration() {
        let controller = RemoteInputController()
        controller.activate(generation: 3, geometryEpoch: 8)
        XCTAssertEqual(controller.type("y", generation: 2, geometryEpoch: 8), [])
        XCTAssertEqual(controller.type("y", generation: 3, geometryEpoch: 7), [])
        XCTAssertEqual(controller.type("y", generation: 3, geometryEpoch: 8).map(\.payload), key(0x59))
    }

    // MARK: the route

    private func capabilities(_ textInput: String?) throws -> RemoteCapabilitiesDTO {
        let extra = textInput.map { ", \"text_input\": \($0)" } ?? ""
        let json = """
        {"backends": {}, "modes": [], "placement_options": [], "lock_local_input_supported": true,
         "encoder_limits": null, "default_backend": "sunshine"\(extra)}
        """
        return try JSONDecoder().decode(RemoteCapabilitiesDTO.self, from: Data(json.utf8))
    }

    func testTheRouteFollowsWhatTheHostSays() throws {
        XCTAssertEqual(RemoteTypingRoute.from(nil), .keysOnly)
        XCTAssertEqual(RemoteTypingRoute.from(try capabilities(nil)), .keysOnly)
        XCTAssertEqual(RemoteTypingRoute.from(try capabilities(#"{"available": true, "layout": "us", "variant": null}"#)),
                       RemoteTypingRoute(hostText: true, asciiAsKeys: true))
        XCTAssertEqual(RemoteTypingRoute.from(try capabilities(#"{"available": true, "layout": "de", "variant": null}"#)),
                       RemoteTypingRoute(hostText: true, asciiAsKeys: false))
        XCTAssertEqual(RemoteTypingRoute.from(try capabilities(#"{"available": true, "layout": "us", "variant": "dvorak"}"#)),
                       RemoteTypingRoute(hostText: true, asciiAsKeys: false))
        XCTAssertEqual(RemoteTypingRoute.from(try capabilities(#"{"available": true, "layout": null, "variant": null}"#)),
                       RemoteTypingRoute(hostText: true, asciiAsKeys: true))
        // No text road: keys are the only way, whatever the keymap.
        XCTAssertEqual(RemoteTypingRoute.from(try capabilities(#"{"available": false, "layout": "de", "variant": null}"#)),
                       .keysOnly)
    }

    private func coreFixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: RemoteInputTypingTests.self)
            .url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures")))
    }

    func testTheCoreFixturesDecode() throws {
        let plain = try JSONDecoder().decode(RemoteCapabilitiesDTO.self, from: coreFixture("remote-capabilities"))
        // REMOTE-INPUT-2 added the route's limits and `compose`.
        XCTAssertEqual(plain.text_input, .init(available: true, layout: "us", variant: nil,
                                               max_chars: 1024, max_bytes: 4096, compose: true))
        let typed = try JSONDecoder().decode(RemoteTextDTO.self, from: coreFixture("remote-text"))
        XCTAssertTrue(typed.typed)
        XCTAssertEqual(typed.chars, 2)
    }

    func testOutcomes() {
        XCTAssertEqual(RemoteHostTextOutcome.from(RemoteRequestError(code: "route_unavailable", status: 404)), .unavailable)
        XCTAssertEqual(RemoteHostTextOutcome.from(RemoteRequestError(code: "invalid_request", status: 404)), .unavailable)
        XCTAssertEqual(RemoteHostTextOutcome.from(RemoteRequestError(code: "remote_text_unavailable", status: 503)), .unavailable)
        XCTAssertEqual(RemoteHostTextOutcome.from(RemoteRequestError(code: "remote_text_failed", status: 503)), .failed)
        XCTAssertEqual(RemoteHostTextOutcome.from(URLError(.timedOut)), .failed)
    }

    // MARK: the order of the two roads

    @MainActor func testKeysTypedAfterHostTextWaitForItsAnswer() async {
        let sequencer = RemoteHostTextSequencer()
        var log: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "request started")
        sequencer.deliver = { text in
            log.append("text:\(text)")
            started.fulfill()
            await withCheckedContinuation { release = $0 }
            return .typed
        }
        sequencer.perform { log.append("key:a") }
        sequencer.type("你好")
        sequencer.perform { log.append("key:b") }
        sequencer.type("👍")
        sequencer.perform { log.append("key:c") }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(log, ["key:a", "text:你好"])
        XCTAssertTrue(sequencer.isHolding)
        let second = expectation(description: "second request")
        sequencer.deliver = { text in log.append("text:\(text)"); second.fulfill(); return .typed }
        release?.resume()
        await fulfillment(of: [second], timeout: 2)
        let deadline = ContinuousClock.now + .seconds(2)
        while log.count < 5, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(log, ["key:a", "text:你好", "key:b", "text:👍", "key:c"])
        XCTAssertFalse(sequencer.isHolding)
    }

    @MainActor func testAnEndedSessionDropsWhatWasHeld() async {
        let sequencer = RemoteHostTextSequencer()
        var log: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "request started")
        sequencer.deliver = { _ in started.fulfill(); await withCheckedContinuation { release = $0 }; return .typed }
        sequencer.type("你好")
        sequencer.perform { log.append("held") }
        await fulfillment(of: [started], timeout: 2)
        sequencer.reset()
        sequencer.perform { log.append("next session") }
        release?.resume()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log, ["next session"])
    }

    @MainActor func testWithoutAHostRoadTextIsDroppedAndSaidOnce() {
        let sequencer = RemoteHostTextSequencer()
        var outcomes: [RemoteHostTextOutcome] = []
        var keys = 0
        sequencer.onUndelivered = { outcomes.append($0) }
        sequencer.type("你好")
        sequencer.perform { keys += 1 }
        XCTAssertEqual(outcomes, [.unavailable])
        XCTAssertEqual(keys, 1, "keys never wait for a road that does not exist")
    }

    @MainActor func testABurstOfKeysIsPacedAndKeepsItsOrder() async throws {
        let sequencer = RemoteHostTextSequencer()
        var sent: [Int] = []
        for index in 0..<100 { sequencer.perform { sent.append(index) } }
        XCTAssertEqual(sent, Array(0..<RemoteHostTextSequencer.burst), "only one burst goes out at once")
        XCTAssertTrue(sequencer.isHolding)
        let deadline = ContinuousClock.now + .seconds(3)
        while sent.count < 100, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(sent, Array(0..<100))
        XCTAssertFalse(sequencer.isHolding)
    }

    // MARK: VNC

    func testVNCKeysymsAreCharactersAndTabIsTheTabKey() {
        XCTAssertEqual(VNCTyping.keysym(for: "a"), 0x61)
        XCTAssertEqual(VNCTyping.keysym(for: "A"), 0x41)
        XCTAssertEqual(VNCTyping.keysym(for: "~"), 0x7E)
        XCTAssertEqual(VNCTyping.keysym(for: " "), 0x20)
        XCTAssertEqual(VNCTyping.keysym(for: "\t"), 0xFF09)
        XCTAssertEqual(VNCTyping.keysym(for: "\n"), 0xFF0D)
        XCTAssertEqual(VNCTyping.keysym(for: "\r\n"), 0xFF0D)
        XCTAssertNil(VNCTyping.keysym(for: "你"))
        XCTAssertNil(VNCTyping.keysym(for: "é"))
        XCTAssertNil(VNCTyping.keysym(for: "\u{1B}"))
    }
}
