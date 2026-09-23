import SwiftUI
import XCTest
@testable import Omodachi

/// SPEC-F3 §4.4. Three things have to hold with no host in the room: a frame
/// off the bridge decodes into the bytes the emulator is fed, a control resolves
/// to a route and never to a key code, and the SSH surface knows where it is
/// dialling before it opens a socket.
@MainActor
final class HerdrSSHTests: XCTestCase {
    private func fixtures() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["OMODACHI_CORE_FIXTURES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
    }

    private func layout() throws -> HerdrLayoutDTO {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("herdr-layout.json"))
        return try JSONDecoder().decode(HerdrLayoutDTO.self, from: data)
    }

    // MARK: - Layout

    func testTheCoreLayoutFixtureDecodesIntoTheGridTheSurfaceDraws() throws {
        let value = try layout()
        XCTAssertEqual(value.session, "omodachi")
        XCTAssertEqual(value.protocolVersion, 20)
        XCTAssertEqual(value.version, "0.8.2")
        XCTAssertEqual(value.revision, 1)
        XCTAssertEqual(value.workspaces.map(\.id), ["w1"])
        XCTAssertEqual(value.panes.map(\.id), ["w1:p1", "w1:p2"])
        XCTAssertEqual(value.focused?.paneID, "w1:p1")
        XCTAssertEqual(value.preferredPane, "w1:p1")
        XCTAssertEqual(value.tab(of: "w1:p2")?.id, "w1:t1")
        XCTAssertEqual(value.workspace(of: "w1:p2")?.id, "w1")
        XCTAssertEqual(value.pane("w1:p1")?.size?.cols, 47)
    }

    /// §1.3. The agent row says Herdr's own kind and status word; a pane with no
    /// agent has no agent line and falls back to its id.
    func testAnAgentPaneCarriesItsKindAndHerdrsOwnStatusWord() throws {
        let value = try layout()
        let agent = try XCTUnwrap(value.pane("w1:p2"))
        XCTAssertEqual(agent.agentLabel, "codex · working")
        XCTAssertEqual(agent.status, .working)
        XCTAssertEqual(agent.displayTitle, "codex")

        let plain = try XCTUnwrap(value.pane("w1:p1"))
        XCTAssertNil(plain.agentLabel)
        // `unknown` is not "finished": it is left exactly as Herdr said it.
        XCTAssertEqual(plain.status, .unknown)
    }

    /// A pane Herdr has not titled yet says so rather than borrowing a title
    /// from its neighbour — a freshly split pane has `"title": null`.
    func testAnUntitledPaneSaysUntitledRatherThanBorrowingATitle() throws {
        let json = """
        {"revision": 4, "workspaces": [{"id": "w1", "focused": true, "tabs": [
          {"id": "w1:t1", "focused": true, "zoomed": false, "panes": [
            {"id": "w1:p3", "tab_id": "w1:t1", "workspace_id": "w1", "title": null,
             "focused": false, "zoomed": false, "agent": null,
             "size": {"cols": null, "rows": null}, "revision": 0}]}]}]}
        """
        let value = try JSONDecoder().decode(HerdrLayoutDTO.self, from: Data(json.utf8))
        XCTAssertEqual(value.pane("w1:p3")?.displayTitle, "untitled")
        XCTAssertNil(value.pane("w1:p3")?.size?.cols)
        XCTAssertEqual(value.preferredPane, "w1:p3")
    }

    // MARK: - Frames

    /// The three envelopes SPEC-F1 recorded off the live `omodachi` session,
    /// verbatim apart from the elided `bytes`.
    func testTheThreeLiveFrameEnvelopesDecodeIntoFullAndIncrementalBytes() throws {
        let payload = Data("\u{1b}[2Jomodachi-f3".utf8).base64EncodedString()

        let first = try HerdrStreamDecoder.decode(text: """
        {"encoding":"ansi","full":true,"height":10,"seq":1,"type":"terminal.frame","width":80,"bytes":"\(payload)"}
        """)
        guard case .frame(let full) = first else { return XCTFail("expected a frame") }
        XCTAssertTrue(full.full)
        XCTAssertEqual(full.sequence, 1)
        XCTAssertEqual(full.width, 80)
        XCTAssertEqual(full.height, 10)
        XCTAssertEqual(Data(full.bytes), Data("\u{1b}[2Jomodachi-f3".utf8))

        let second = try HerdrStreamDecoder.decode(text: """
        {"encoding":"ansi","full":false,"height":10,"seq":2,"type":"terminal.frame","width":80,"bytes":"\(payload)"}
        """)
        guard case .frame(let increment) = second else { return XCTFail("expected a frame") }
        XCTAssertFalse(increment.full)
        XCTAssertEqual(increment.sequence, 2)

        let closed = try HerdrStreamDecoder.decode(text: #"{"reason":"detached","type":"terminal.closed"}"#)
        XCTAssertEqual(closed, .closed(reason: "detached"))
    }

    /// The bridge is a pipe, so a message type this client has never seen is
    /// carried rather than treated as a protocol error.
    func testAMessageTypeThisClientDoesNotKnowIsCarriedNotRefused() throws {
        XCTAssertEqual(try HerdrStreamDecoder.decode(text: #"{"type":"terminal.hint","note":"x"}"#),
                       .other(type: "terminal.hint"))
    }

    func testAFrameThisClientCannotPaintIsRefusedRatherThanFedToTheEmulator() {
        XCTAssertThrowsError(try HerdrStreamDecoder.decode(text: "not json")) {
            XCTAssertEqual($0 as? HerdrFrameDecodingError, .notJSON)
        }
        XCTAssertThrowsError(try HerdrStreamDecoder.decode(text: #"{"seq":1}"#)) {
            XCTAssertEqual($0 as? HerdrFrameDecodingError, .missingType)
        }
        // 0.8.2 emits `ansi`. Decoding an unknown encoding blind would put
        // garbage on screen and call it the host's output.
        XCTAssertThrowsError(try HerdrStreamDecoder.decode(
            text: #"{"type":"terminal.frame","encoding":"cbor","bytes":"AA=="}"#)) {
            XCTAssertEqual($0 as? HerdrFrameDecodingError, .unsupportedEncoding("cbor"))
        }
        XCTAssertThrowsError(try HerdrStreamDecoder.decode(
            text: #"{"type":"terminal.frame","encoding":"ansi","bytes":"!!!!"}"#)) {
            XCTAssertEqual($0 as? HerdrFrameDecodingError, .invalidBase64)
        }
    }

    /// Base64 with the line breaks a wrapped encoder produces still decodes to
    /// the same bytes; the payload is what Herdr wrote, not how it was folded.
    func testBase64WithLineBreaksDecodesToTheSameBytes() throws {
        let raw = Data((0..<200).map { UInt8($0 % 251) })
        let folded = raw.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let escaped = folded.replacingOccurrences(of: "\n", with: "\\n")
        let message = try HerdrStreamDecoder.decode(
            text: #"{"type":"terminal.frame","encoding":"ansi","full":true,"bytes":"\#(escaped)"}"#)
        guard case .frame(let frame) = message else { return XCTFail("expected a frame") }
        XCTAssertEqual(Data(frame.bytes), raw)
    }

    // MARK: - Control commands

    /// Herdr's four stdin commands, and the one message `observe` answers.
    /// Their field names are Herdr's; the bridge closes the socket with
    /// `invalid_control_command` for anything else.
    func testTheControlCommandsAreExactlyHerdrsOwnFourPlusTheObserveResize() throws {
        func decode(_ command: HerdrControlCommand) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.json.utf8)) as? [String: Any])
        }
        let input = try decode(.input(text: "echo omodachi-f3\n"))
        XCTAssertEqual(input["type"] as? String, "terminal.input")
        XCTAssertEqual(input["text"] as? String, "echo omodachi-f3\n")
        XCTAssertNil(input["bytes"], "terminal.input accepts text or bytes, not both.")

        let resize = try decode(.resize(cols: 100, rows: 20))
        XCTAssertEqual(resize["type"] as? String, "terminal.resize")
        XCTAssertEqual(resize["cols"] as? Int, 100)
        XCTAssertEqual(resize["rows"] as? Int, 20)

        XCTAssertEqual(try decode(.scroll(lines: 3))["lines"] as? Int, 3)
        XCTAssertEqual(try decode(.release)["type"] as? String, "terminal.release")
        // `observe` reads no stdin on 0.8.2; the bridge answers this itself.
        XCTAssertEqual(try decode(.observeResize(cols: 80, rows: 24))["type"] as? String, "resize")
    }

    func testInputEscapesControlCharactersAndNonASCIIWithoutLosingThem() throws {
        let command = HerdrControlCommand.input(text: "中文 \u{3}\u{1b}[A")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.json.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["text"] as? String, "中文 \u{3}\u{1b}[A")
    }

    /// A multi-byte character split across two `send` callbacks must arrive as
    /// one character, not as two replacement glyphs.
    func testAMultiByteCharacterSplitAcrossTwoSendsIsHeldUntilItIsWhole() {
        var encoder = HerdrInputEncoder()
        let bytes = Array("中".utf8)
        XCTAssertEqual(bytes.count, 3)
        XCTAssertNil(encoder.encode([bytes[0], bytes[1]]), "an incomplete sequence is held back")
        XCTAssertEqual(encoder.encode([bytes[2]]), "中")
        XCTAssertEqual(encoder.encode(Array("ab".utf8)), "ab")
        // A four-byte emoji arriving one byte at a time.
        let emoji = Array("😀".utf8)
        XCTAssertNil(encoder.encode([emoji[0]]))
        XCTAssertNil(encoder.encode([emoji[1]]))
        XCTAssertNil(encoder.encode([emoji[2]]))
        XCTAssertEqual(encoder.encode([emoji[3]]), "😀")
    }

    func testGeometryIsClampedToTheRangeTheBridgeAccepts() {
        XCTAssertEqual(HerdrGeometry.clamp(cols: 0, rows: 0).cols, 1)
        XCTAssertEqual(HerdrGeometry.clamp(cols: 5000, rows: 5000).rows, 1000)
        XCTAssertEqual(HerdrGeometry.clamp(cols: 80, rows: 24).cols, 80)
    }

    /// Backoff exists so a host that is down is not hammered; it never re-runs
    /// anything, which is why the delays are the whole policy.
    func testReconnectBacksOffAndStopsGrowingAtTheCap() {
        XCTAssertEqual(HerdrReconnectPolicy.delay(attempt: 0), 0)
        XCTAssertEqual(HerdrReconnectPolicy.delay(attempt: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(HerdrReconnectPolicy.delay(attempt: 2), 1, accuracy: 0.0001)
        XCTAssertEqual(HerdrReconnectPolicy.delay(attempt: 5), 8, accuracy: 0.0001)
        XCTAssertEqual(HerdrReconnectPolicy.delay(attempt: 40), HerdrReconnectPolicy.maximumDelay, accuracy: 0.0001)
    }

    // MARK: - Control bar mapping

    /// A-13. Every control is a route on `/v1/herdr`; none of them is a key
    /// code, which is the whole point of the semantic bar.
    func testEveryControlResolvesToAHerdrRouteAndNeverToAKeyCode() throws {
        let value = try layout()
        XCTAssertEqual(HerdrControlMapper.request(.splitRight, layout: value, selected: "w1:p1"),
                       .pane(pane: "w1:p1", action: .split(direction: .right)))
        XCTAssertEqual(HerdrControlMapper.request(.splitDown, layout: value, selected: "w1:p1"),
                       .pane(pane: "w1:p1", action: .split(direction: .down)))
        XCTAssertEqual(HerdrControlMapper.request(.zoom, layout: value, selected: "w1:p1"),
                       .pane(pane: "w1:p1", action: .zoom(mode: .toggle)))
        XCTAssertEqual(HerdrControlMapper.request(.close, layout: value, selected: "w1:p2"),
                       .pane(pane: "w1:p2", action: .close))

        // The bodies are the bridge's own, checked here because a wrong key
        // name is a 400 the user would see as "nothing happened".
        XCTAssertEqual(HerdrPaneAction.split(direction: .down).path, "split")
        XCTAssertEqual(HerdrPaneAction.split(direction: .down).body, ["direction": "down"])
        XCTAssertEqual(HerdrPaneAction.zoom(mode: .toggle).body, ["mode": "toggle"])
        XCTAssertEqual(HerdrPaneAction.close.body, [:])
    }

    /// Tapping a pane is absolute focus, which 0.8.2's CLI cannot do — the
    /// bridge answers a directionless focus with the protocol's `pane.focus`.
    /// A direction is never inferred from a tap.
    func testATapIsAbsoluteFocusWithNoDirection() {
        XCTAssertEqual(HerdrControlMapper.focus(pane: "w1:p2"),
                       .pane(pane: "w1:p2", action: .focus(direction: nil)))
        XCTAssertEqual(HerdrPaneAction.focus(direction: nil).body, [:])
        XCTAssertEqual(HerdrPaneAction.focus(direction: .left).body, ["direction": "left"])
    }

    func testPaneCyclingWrapsInsideTheTabAndSaysSoWhenThereIsOnlyOnePane() throws {
        let value = try layout()
        XCTAssertEqual(HerdrControlMapper.request(.nextPane, layout: value, selected: "w1:p1"),
                       .select(pane: "w1:p2"))
        XCTAssertEqual(HerdrControlMapper.request(.nextPane, layout: value, selected: "w1:p2"),
                       .select(pane: "w1:p1"))
        XCTAssertEqual(HerdrControlMapper.request(.previousPane, layout: value, selected: "w1:p1"),
                       .select(pane: "w1:p2"))

        let single = """
        {"revision": 1, "workspaces": [{"id": "w1", "focused": true, "tabs": [
          {"id": "w1:t1", "focused": true, "zoomed": false, "panes": [
            {"id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1", "title": "x",
             "focused": true, "zoomed": false, "agent": null, "revision": 1}]}]}]}
        """
        let one = try JSONDecoder().decode(HerdrLayoutDTO.self, from: Data(single.utf8))
        XCTAssertEqual(HerdrControlMapper.request(.nextPane, layout: one, selected: "w1:p1"),
                       .unsupported(reason: Strings.herdrOnlyOnePane))
    }

    /// The bridge has split, zoom, focus, close and `workspaces/{id}/select`
    /// and no tab route, so the control says why instead of doing nothing.
    func testNewTabIsUnsupportedBecauseTheBridgeHasNoTabRoute() throws {
        XCTAssertEqual(HerdrControlMapper.request(.newTab, layout: try layout(), selected: "w1:p1"),
                       .unsupported(reason: HerdrControlMapper.noTabRoute))
    }

    func testEveryControlIsUnsupportedWithNoSelectedPane() throws {
        for action in HerdrControlAction.allCases {
            guard case .unsupported = HerdrControlMapper.request(action, layout: try layout(), selected: nil) else {
                return XCTFail("\(action) must not resolve without a pane")
            }
        }
    }

    /// `wN:pN` and `wN` are the bridge's patterns. Checking them client-side is
    /// what keeps a value out of the path and out of an argv.
    func testOnlyHerdrsOwnIdentifierShapesReachTheRoutes() {
        for value in ["w1:p1", "w12:p345", "w999999999:p1"] {
            XCTAssertTrue(CompanionHostClient.isHerdrPane(value), value)
        }
        for value in ["", "w1", "w1:t1", "w1:p", ":p1", "w1:p1:p2", "w1:p1/../x", "W1:P1", "w1:p1 ", "w-1:p1"] {
            XCTAssertFalse(CompanionHostClient.isHerdrPane(value), value)
        }
        XCTAssertTrue(CompanionHostClient.isHerdrWorkspace("w10"))
        XCTAssertFalse(CompanionHostClient.isHerdrWorkspace("w1:t1"))
        XCTAssertFalse(CompanionHostClient.isHerdrWorkspace("w"))
    }

    // MARK: - Terminal palette (§3)

    func testTheTerminalPaletteComesFromTheHostColoursWhenThereIsNoTerminalSection() throws {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("theme.json"))
        let theme = try JSONDecoder().decode(HostTheme.self, from: data)
        XCTAssertNil(theme.shell["terminal"], "this host publishes no [terminal] section")

        let ansi = TerminalPalette.ansi(theme)
        XCTAssertEqual(ansi.count, 16)
        XCTAssertEqual(ansi[1].0, theme.rgb(.red).0, accuracy: 0.0001)
        XCTAssertEqual(ansi[2].1, theme.rgb(.green).1, accuracy: 0.0001)
        XCTAssertEqual(ansi[9].0, theme.rgb(.brightRed).0, accuracy: 0.0001)
        XCTAssertEqual(ansi[15].2, theme.rgb(.brightForeground).2, accuracy: 0.0001)
        XCTAssertEqual(TerminalPalette.background(theme).0, theme.rgb(.background).0, accuracy: 0.0001)
        XCTAssertEqual(TerminalPalette.cursor(theme).0, theme.rgb(.accent).0, accuracy: 0.0001)
    }

    /// A host that does publish `[terminal]` is the authority; the role mapping
    /// above is only what happens when it does not.
    func testAPublishedTerminalSectionWinsOverTheRoleMapping() {
        let theme = HostTheme(name: "t", mode: "dark", colors: FallbackTheme.colors,
                              shell: ["terminal": ["color1": .text("#010203"),
                                                   "background": .text("#040506")]])
        XCTAssertEqual(TerminalPalette.ansi(theme)[1].0, Double(0x01) / 255, accuracy: 0.0001)
        XCTAssertEqual(TerminalPalette.background(theme).1, Double(0x05) / 255, accuracy: 0.0001)
        // Unlisted slots still fall to their role rather than to a picked value.
        XCTAssertEqual(TerminalPalette.ansi(theme)[2].1, theme.rgb(.green).1, accuracy: 0.0001)
    }

    // MARK: - SSH target (§2)

    private func pin(_ endpoints: [(String, Int)], hostName: String = "omarchy") -> HostPin {
        HostPin(hostID: String(repeating: "a", count: 32), hostName: hostName,
                fingerprintSHA256: String(repeating: "b", count: 64),
                endpoints: endpoints.map { .init(host: $0.0, port: $0.1) })
    }

    func testTheSSHTargetIsThePairedAddressWithTheUsersOwnAccount() {
        var profile = HostProfile()
        profile.hostname = ""
        profile.username = "alex"
        profile.port = 22
        let target = SSHTargetResolver.resolve(profile: profile, pin: pin([("192.168.1.10", 8099)]))
        XCTAssertEqual(target?.host, "192.168.1.10")
        XCTAssertEqual(target?.username, "alex")
        // The pinned endpoint's 8099 is the companion service's HTTPS port, not
        // an SSH port; reading one as the other would dial the wrong thing.
        XCTAssertEqual(target?.port, 22)
        XCTAssertEqual(target?.source, .pairedEndpoint)
        XCTAssertEqual(target?.label, "alex@192.168.1.10")
        XCTAssertEqual(target?.identity, "192.168.1.10:22")
    }

    func testAnExplicitSetupHostWinsOverThePairedAddress() {
        var profile = HostProfile()
        profile.hostname = "omarchy.tailnet"
        profile.username = "alex"
        let target = SSHTargetResolver.resolve(profile: profile, pin: pin([("192.168.1.10", 8099)]))
        XCTAssertEqual(target?.host, "omarchy.tailnet")
        XCTAssertEqual(target?.source, .profile)
    }

    func testHostNameIsUsedOnlyWhenTheClaimCarriedNoEndpoints() {
        var profile = HostProfile()
        profile.hostname = ""
        profile.username = "alex"
        let target = SSHTargetResolver.resolve(profile: profile, pin: pin([], hostName: "omarchy"))
        XCTAssertEqual(target?.host, "omarchy")
        XCTAssertEqual(target?.source, .pairedHostName)
    }

    func testNoAccountOrNoAddressMeansNoTargetRatherThanAGuess() {
        var profile = HostProfile()
        profile.hostname = "omarchy"
        profile.username = "   "
        XCTAssertNil(SSHTargetResolver.resolve(profile: profile, pin: nil))

        profile.username = "alex"
        profile.hostname = ""
        XCTAssertNil(SSHTargetResolver.resolve(profile: profile, pin: nil))
    }

    /// RELEASE-3b: a fresh profile carries no account. It used to default to
    /// the maintainer's login, which on anybody else's host dialled a stranger's
    /// account whenever pairing had not handed over an SSH target.
    func testAFreshProfileHasNoAccountSoOnlyAPairedTargetIsDialled() {
        let profile = HostProfile()
        XCTAssertEqual(profile.username, "")
        XCTAssertNil(SSHTargetResolver.resolve(profile: profile, pin: nil))
        XCTAssertNil(SSHTargetResolver.resolve(profile: profile, pin: pin([("192.168.1.10", 8099)])))
        var paired = pin([("192.168.1.10", 8099)])
        paired.ssh = .init(user: "alex", host: "192.168.1.10", port: 22)
        let target = try! XCTUnwrap(SSHTargetResolver.resolve(profile: profile, pin: paired))
        XCTAssertEqual(target.label, "alex@192.168.1.10")
        XCTAssertEqual(target.source, .pairedTarget)
    }

    /// RELEASE-3b: with no account the session is named by its host alone,
    /// not a bare `@omarchy`.
    func testTheEndpointLabelOfAnAccountlessProfileIsTheHostAlone() {
        var profile = HostProfile()
        profile.mock = false
        XCTAssertEqual(SurfaceRouteTargets.shell(host: profile, title: "t", argv: []).endpointLabel, "omarchy")
        profile.username = "alex"
        XCTAssertEqual(SurfaceRouteTargets.shell(host: profile, title: "t", argv: []).endpointLabel, "alex@omarchy")
    }

    /// RELEASE-3b: what the SSH panel says when the profile it was handed has
    /// no account — pairing gave no SSH target — rather than "invalid options".
    func testDiallingWithoutAnAccountSaysPairingGaveNoTarget() async {
        let transport = SSHTransport(
            options: SSHConnectionOptions(host: "omarchy", port: 22, username: "", privateKeyAccount: "ssh-none"),
            privateKeyProvider: { nil }, hostKeyValidator: { _ in })
        do {
            try await transport.connect(cols: 80, rows: 24)
            XCTFail("an accountless profile must not dial")
        } catch {
            XCTAssertEqual(error as? SSHTransportError, .invalidOptions(Strings.sshNoPairedTarget))
            XCTAssertEqual(error.localizedDescription, Strings.sshNoPairedTarget)
        }
    }

    /// A host with a separator in it would change meaning inside a URL or a
    /// pin key, so it is skipped rather than escaped — the next candidate wins.
    func testASeparatorInAHostIsRefusedAndTheNextCandidateIsUsed() {
        var profile = HostProfile()
        profile.hostname = "bad host/name"
        profile.username = "alex"
        let target = SSHTargetResolver.resolve(profile: profile, pin: pin([("192.168.1.10", 8099)]))
        XCTAssertEqual(target?.host, "192.168.1.10")
        XCTAssertEqual(target?.source, .pairedEndpoint)

        XCTAssertFalse(SSHTargetResolver.isValidHost("a@b"))
        XCTAssertFalse(SSHTargetResolver.isValidHost("a:b"))
        XCTAssertFalse(SSHTargetResolver.isValidAccount("root@host"))
    }

    func testAnOutOfRangePortFallsToTwentyTwoRatherThanBeingSent() {
        var profile = HostProfile()
        profile.hostname = "omarchy"
        profile.username = "alex"
        profile.port = 0
        XCTAssertEqual(SSHTargetResolver.resolve(profile: profile, pin: nil)?.port, 22)
        profile.port = 2222
        XCTAssertEqual(SSHTargetResolver.resolve(profile: profile, pin: nil)?.port, 2222)
    }

    /// Resolving must not move the Keychain account the private key lives under,
    /// which is derived from the profile id.
    func testResolvingTheAddressDoesNotMoveTheKeychainAccount() {
        var profile = HostProfile()
        profile.hostname = ""
        profile.username = "alex"
        let before = profile.keyAccount
        let target = try! XCTUnwrap(SSHTargetResolver.resolve(profile: profile, pin: pin([("192.168.1.10", 8099)])))
        let resolved = SSHTargetResolver.profile(profile, for: target)
        XCTAssertEqual(resolved.keyAccount, before)
        XCTAssertEqual(resolved.hostname, "192.168.1.10")
        XCTAssertEqual(resolved.id, profile.id)
    }

    /// SPEC-I: pairing carries the public key and the host writes it during the
    /// one Approve, so there is no instruction left to print - only a sentence
    /// for the case where that grant did not land.
    func testThereIsNothingLeftForTheUserToDoOnTheHost() {
        XCTAssertTrue(SSHAuthorizationHint.coreCommandAvailable)
        XCTAssertNil(SSHAuthorizationHint.unauthorized(grants: nil))
        XCTAssertNil(SSHAuthorizationHint.unauthorized(grants: .init(companion: true, media: true, ssh: true)))
        let text = try! XCTUnwrap(SSHAuthorizationHint.unauthorized(
            grants: .init(companion: true, media: true, ssh: false)))
        XCTAssertEqual(text, Strings.sshKeyNotAuthorized)
    }

    /// §2.6: the whole target comes from the claim, so the SSH surface opens
    /// without anyone having typed a host, a port or an account.
    func testThePairedTargetAnswersAllThreeFieldsWithoutTheProfile() {
        var profile = HostProfile()
        profile.hostname = "stale-name"
        profile.username = "someone-else"
        profile.port = 2200
        var paired = pin([("192.168.1.10", 8099)])
        paired.ssh = .init(user: "alex", host: "192.168.1.10", port: 22)
        let target = try! XCTUnwrap(SSHTargetResolver.resolve(profile: profile, pin: paired))
        XCTAssertEqual([target.username, target.host, "\(target.port)"], ["alex", "192.168.1.10", "22"])
        XCTAssertEqual(target.source, .pairedTarget)
        // Half a target is no target: it falls back rather than inventing one.
        paired.ssh = .init(user: "alex", host: "", port: 22)
        XCTAssertEqual(SSHTargetResolver.resolve(profile: profile, pin: paired)?.source, .profile)
    }

    // MARK: - SSH assist row (§2, A-14)

    /// A-14: the row is the keys a software keyboard cannot produce, and the
    /// Herdr prefix keys are not among them any more.
    func testTheAssistRowIsOnlyTheKeysASoftwareKeyboardCannotSend() {
        let labels = SSHModifierRow.keys.map(\.0)
        XCTAssertEqual(labels, ["esc", "⇥", "←", "↓", "↑", "→"])
        XCTAssertEqual(SSHModifierRow.keys.first { $0.0 == "esc" }?.1, [27])
        XCTAssertEqual(SSHModifierRow.keys.first { $0.0 == "↑" }?.1, [27, 91, 65])
        XCTAssertFalse(labels.contains("Prefix"), "the Herdr prefix is not an SSH key")
    }
}
