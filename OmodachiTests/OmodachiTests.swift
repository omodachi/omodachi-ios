import XCTest
import SwiftTerm
import UIKit
@testable import Omodachi

@MainActor final class OmodachiTests: XCTestCase {
    /// ARCH-1 replaced the two layout policies this file used to assert.
    /// `NativeLayoutPolicy`'s 56pt Remote strip was deleted by A-40 and the
    /// pinned grid by A-50; `PanelLayoutPolicy`'s sidebar/overlay widths were
    /// deleted by A-55, which has one panel filling one block. What took their
    /// place is `PanelMeasure`, and this is the rule that matters: side by side
    /// needs the orientation **and** the width (A-54 rev 5).
    func testPanelOneFoldsUnlessItIsLandscapeAndWideEnough() {
        XCTAssertEqual(PanelMeasure.sideBySide, 785, "360 + gaps_in 5 + 420")
        XCTAssertTrue(PanelMeasure.sideBySide(landscape: true, width: 1194))
        XCTAssertTrue(PanelMeasure.sideBySide(landscape: true, width: 890), "Duo inner, landscape")
        XCTAssertFalse(PanelMeasure.sideBySide(landscape: true, width: 320),
                       "Stage Manager: landscape, and far too narrow")
        XCTAssertFalse(PanelMeasure.sideBySide(landscape: false, width: 790),
                       "portrait folds even when it would fit, so turning the device is predictable")
        XCTAssertTrue(PanelMeasure.isNarrow(349), "iPhone portrait")
        XCTAssertTrue(PanelMeasure.isNarrow(422), "Duo outer")
        XCTAssertFalse(PanelMeasure.isNarrow(760))
    }

    func testCatalogOwnsWorkspaceSearchWithoutSyntheticDuplicate() throws {
        let bundle = Bundle(for: Self.self)
        let root = try XCTUnwrap(bundle.url(forResource: "CoreFixtures", withExtension: nil))
        let data = try Data(contentsOf: root.appendingPathComponent("catalog.json"))
        let catalog = try JSONDecoder().decode(HostCatalogDTO.self, from: data)
        let roots = HostMenu.build(from: catalog.entries)
        let all = roots.flatMap(\.all)
        let workspace3 = all.filter { $0.id == "omodachi.workspace.select.3" || $0.aliases.contains("3") }
        XCTAssertEqual(workspace3.count, 1, "Workspace 3 must come only from the host catalog")
        XCTAssertFalse(all.contains { $0.id == "workspace.3" || $0.id == "trigger.workspace.3" })
    }
    /// N-39 rev 5: a pin is `{host_id, kind, stable_key, label}`, and a stale
    /// one is a tombstone rather than a deletion.
    func testAPinIsKeyedByHostAndPathAndSurvivesTheRowGoingAway() {
        let defaults = UserDefaults(suiteName: "omodachi-pin-\(UUID())")!
        let store = PanelPinStore(defaults: defaults)
        let item = MenuItem(id: "style.theme", label: "Theme", path: ["Style"])
        XCTAssertEqual(item.pinKey, "Style › Theme")
        let pin = PanelPin(hostID: "host-a", kind: .menu, stableKey: item.pinKey, label: item.label)
        XCTAssertFalse(store.isPinned(pin))
        _ = store.toggle(pin)
        XCTAssertTrue(store.isPinned(pin))
        XCTAssertFalse(store.isPinned(PanelPin(hostID: "host-b", kind: .menu,
                                               stableKey: item.pinKey, label: item.label)),
                       "pins belong to a host, not to the app")
        // The catalog no longer has the row: the pin is still there, with the
        // label it was last seen under.
        XCTAssertEqual(store.pins(hostID: "host-a", kind: .menu).map(\.label), ["Theme"])
        _ = store.toggle(pin)
        XCTAssertFalse(store.isPinned(pin), "the same row again unpins it")
    }
    func testAgentAttachUsesNamedDefault() {
        XCTAssertEqual(HerdrCommandAdapter.agentAttach().argv, ["herdr", "agent", "attach", "default"])
        XCTAssertEqual(HerdrCommandAdapter.herdr(session: "owned-session").argv, ["herdr", "session", "attach", "owned-session"])
    }
    func testHomeKeepsOneConnectionAndTerminalAcrossNavigation() async throws {
        let defaults = isolatedDefaults()
        let transport = RecordingTransport()
        let store = SessionStore(defaults: defaults, factory: { _ in transport })
        let descriptor = SurfaceRouteTargets.agent(host: HostProfile())
        let runtime = store.create(descriptor)
        let view = runtime.terminal
        runtime.appeared()
        try await eventually { runtime.state == .connected }
        runtime.appeared() // returning from Home
        XCTAssertTrue(store.create(SurfaceRouteTargets.agent(host: descriptor.host)).terminal === view)
        XCTAssertEqual(transport.connections, 1)
        XCTAssertEqual(runtime.connectionCount, 1)
        XCTAssertEqual(store.runtimes.count, 1)
        let metadata = try XCTUnwrap(defaults.data(forKey: "omodachi.sessions.v3"))
        let json = String(decoding: metadata, as: UTF8.self)
        XCTAssertFalse(json.contains("output")); XCTAssertFalse(json.contains("private"))
        await runtime.disconnect()
    }

    func testCompanionEndpointChangeReusesSSHRuntimeIdentity() async throws {
        let defaults = isolatedDefaults()
        let transport = RecordingTransport()
        let store = SessionStore(defaults: defaults, factory: { _ in transport })

        var beforePairing = HostProfile()
        beforePairing.id = UUID()
        beforePairing.companionURL = "https://127.0.0.1:58143"
        let first = store.create(SurfaceRouteTargets.agent(host: beforePairing))
        first.appeared()
        try await eventually { first.state == .connected }

        var afterPairing = beforePairing
        afterPairing.companionURL = "https://localhost:58143"
        let second = store.create(SurfaceRouteTargets.agent(host: afterPairing))

        XCTAssertTrue(second === first)
        XCTAssertEqual(store.runtimes.count, 1)
        XCTAssertEqual(first.connectionCount, 1)
        XCTAssertEqual(first.descriptor.host.companionURL, beforePairing.companionURL)
        await first.disconnect()
    }

    func testSSHIdentitySeparatesCredentialEndpointAndNamedTargets() {
        let defaults = isolatedDefaults()
        let store = SessionStore(defaults: defaults, factory: { _ in RecordingTransport() })
        let base = HostProfile()
        let baseRuntime = store.create(SurfaceRouteTargets.agent(host: base))

        var differentUser = base
        differentUser.username = "other"
        XCTAssertFalse(store.create(SurfaceRouteTargets.agent(host: differentUser)) === baseRuntime)

        var differentPort = base
        differentPort.port = 2200
        XCTAssertFalse(store.create(SurfaceRouteTargets.agent(host: differentPort)) === baseRuntime)

        var differentKey = base
        differentKey.id = UUID()
        XCTAssertFalse(store.create(SurfaceRouteTargets.agent(host: differentKey)) === baseRuntime)

        var differentMockMode = base
        differentMockMode.mock = false
        XCTAssertFalse(store.create(SurfaceRouteTargets.agent(host: differentMockMode)) === baseRuntime)

        var namedA = base
        namedA.herdrSession = "omodachi"
        let namedRuntime = store.create(SurfaceRouteTargets.agent(host: namedA))
        var namedB = base
        namedB.herdrSession = "other-session"
        XCTAssertFalse(store.create(SurfaceRouteTargets.agent(host: namedB)) === namedRuntime)

        let sameArgvA = SessionDescriptor(title: "Herdr A", kind: .herdr, host: namedA, argv: ["herdr"])
        var sameArgvHostB = namedA
        sameArgvHostB.herdrSession = "same-argv-different-target"
        let sameArgvB = SessionDescriptor(title: "Herdr B", kind: .herdr, host: sameArgvHostB, argv: ["herdr"])
        let sameArgvRuntime = store.create(sameArgvA)
        XCTAssertFalse(store.create(sameArgvB) === sameArgvRuntime)
    }

    func testCommandsRemainNewInvocationsEvenWhenIdentityMatches() {
        let defaults = isolatedDefaults()
        let store = SessionStore(defaults: defaults, factory: { _ in RecordingTransport() })
        let descriptor = SurfaceRouteTargets.shell(host: HostProfile(), title: "Install", argv: ["installer"])
        let first = store.create(descriptor)
        let second = store.create(descriptor)
        XCTAssertFalse(first === second)
        XCTAssertEqual(store.runtimes.count, 2)
    }
    func testResumeReattachesHerdrButDoesNotReplayCommand() async throws {
        var made: [RecordingTransport] = []
        let factory: SessionStore.TransportFactory = { _ in let t = RecordingTransport(); made.append(t); return t }
        let store = SessionStore(defaults: isolatedDefaults(), factory: factory)
        let herdr = store.create(SurfaceRouteTargets.herdr(host: HostProfile()))
        let command = store.create(SurfaceRouteTargets.shell(host: HostProfile(), title: "Install", argv: ["installer"]))
        herdr.appeared(); command.appeared()
        try await eventually { herdr.state == .connected && command.state == .connected }
        store.setForeground(false)
        try await eventually { herdr.state == .suspended && command.state == .suspended }
        store.setForeground(true)
        try await eventually { herdr.state == .connected }
        XCTAssertEqual(herdr.connectionCount, 2)
        XCTAssertEqual(command.connectionCount, 1)
        XCTAssertEqual(command.state, .suspended)
        command.connect(explicit: true)
        XCTAssertEqual(command.connectionCount, 1)
        XCTAssertNotNil(command.errorMessage)
        await herdr.disconnect(); await command.disconnect()
    }
    func testSwiftTermUnicodeAndContainerResizeUseActualCells() async throws {
        let transport = RecordingTransport()
        let runtime = TerminalRuntime(descriptor: SurfaceRouteTargets.agent(host: HostProfile()), restored: false, factory: { _ in transport })
        let view = runtime.terminal
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        view.layoutIfNeeded()
        runtime.appeared()
        try await eventually { runtime.state == .connected }
        // A marked composition is not submitted until committed by UIKit.
        view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(transport.inputs.isEmpty)
        view.insertText("中文")
        try await eventually { !transport.inputs.isEmpty }
        XCTAssertEqual(transport.inputs.reduce(Data(), +), Data("中文".utf8))
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        view.setNeedsLayout(); view.layoutIfNeeded()
        try await eventually { runtime.columns == view.getTerminal().cols && runtime.rows == view.getTerminal().rows && transport.sizes.last?.0 == runtime.columns && transport.sizes.last?.1 == runtime.rows }
        XCTAssertEqual(runtime.columns, view.getTerminal().cols)
        XCTAssertEqual(runtime.rows, view.getTerminal().rows)
        await runtime.disconnect()
    }
    func testRestoredNamedAgentActivatesOnceOnExplicitSurfaceEntry() async throws {
        let defaults = isolatedDefaults()
        let seed = SessionStore(defaults: defaults, factory: { _ in RecordingTransport() })
        var host = HostProfile()
        host.herdrSession = "omodachi"
        let descriptor = SurfaceRouteTargets.agent(host: host)
        _ = seed.create(descriptor)

        var transports: [RecordingTransport] = []
        let restoredStore = SessionStore(defaults: defaults, factory: { _ in
            let transport = RecordingTransport()
            transports.append(transport)
            return transport
        })
        let restored = try XCTUnwrap(restoredStore.runtime(id: descriptor.id))
        XCTAssertEqual(restored.state, .disconnected)
        XCTAssertEqual(restored.connectionCount, 0)

        restored.activate()
        try await eventually { restored.state == .connected }
        XCTAssertEqual(restored.connectionCount, 1)
        XCTAssertEqual(transports.count, 1)

        // Returning to the same surface is not another user activation.
        restored.activate()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(restored.connectionCount, 1)
        XCTAssertEqual(transports.count, 1)
        await restored.disconnect()
    }

    func testRestoredMenuCommandNeedsNewInvocation() async throws {
        let defaults = isolatedDefaults()
        let store = SessionStore(defaults: defaults, factory: { _ in RecordingTransport() })
        let command = store.create(SurfaceRouteTargets.shell(host: HostProfile(), title: "Update", argv: ["update"]))
        let restored = SessionStore(defaults: defaults, factory: { _ in RecordingTransport() })
        let runtime = try XCTUnwrap(restored.runtime(id: command.id))
        runtime.appeared(); runtime.connect(explicit: true)
        XCTAssertEqual(runtime.connectionCount, 0)
        XCTAssertEqual(runtime.state, .disconnected)
        XCTAssertNotNil(runtime.errorMessage)
    }
    func testCopyAndChinesePasteUseSwiftTermInTheAppProcess() async throws {
        let transport = RecordingTransport()
        let runtime = TerminalRuntime(descriptor: SurfaceRouteTargets.shell(host: HostProfile(), title: "Terminal", argv: []), restored: false, factory: { _ in transport })
        runtime.appeared()
        try await eventually { runtime.state == .connected }
        let view = runtime.terminal
        view.feed(text: "clipboard-probe 中文")
        view.selectAll(nil)
        view.copy(nil)
        XCTAssertTrue(UIPasteboard.general.string?.contains("clipboard-probe 中文") == true)
        UIPasteboard.general.string = "粘贴中文 ✓"
        view.paste(nil)
        try await eventually { !transport.inputs.isEmpty }
        XCTAssertEqual(transport.inputs.reduce(Data(), +), Data("粘贴中文 ✓".utf8))
        UIPasteboard.general.items = []
        await runtime.disconnect()
    }
    func testFirstHostTrustIsExplicitAndMismatchCannotBeConfirmed() async throws {
        let pins = HostKeyStore(service: "com.omodachi.trust-test.\(UUID())")
        let coordinator = HostTrustCoordinator(pins: pins)
        let challenge = SSHHostKeyChallenge(host: "fixture", port: 22222, algorithm: "ssh-ed25519", openSSHPublicKey: "ssh-ed25519 Zml4dHVyZQ==", fingerprintSHA256: "synthetic")
        let first = Task { try await coordinator.validate(challenge) }
        try await eventually { coordinator.request != nil }
        XCTAssertNil(try pins.pinnedFingerprint(host: "fixture:22222"))
        coordinator.resolve(accept: false)
        do { try await first.value; XCTFail("Declined key accepted") } catch {}
        let second = Task { try await coordinator.validate(challenge) }
        try await eventually { coordinator.request != nil }
        coordinator.resolve(accept: true)
        try await second.value
        XCTAssertNotNil(try pins.pinnedFingerprint(host: "fixture:22222"))
        let changed = SSHHostKeyChallenge(host: "fixture", port: 22222, algorithm: "ssh-ed25519", openSSHPublicKey: "ssh-ed25519 Y2hhbmdlZA==", fingerprintSHA256: "synthetic")
        do { try await coordinator.validate(changed); XCTFail("Changed key accepted") } catch {}
        XCTAssertNil(coordinator.request, "A mismatch must not offer first-use acceptance")
        try pins.reset(host: "fixture", port: 22222)
    }
    private func isolatedDefaults() -> UserDefaults { UserDefaults(suiteName: "omodachi.tests.\(UUID())")! }
    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("State condition was not reached")
    }
}

@MainActor private final class RecordingTransport: PTYTransport {
    let output: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var connections = 0
    var inputs: [Data] = []
    var sizes: [(Int, Int)] = []
    init() { let pair = AsyncThrowingStream<Data, Error>.makeStream(); output = pair.stream; continuation = pair.continuation }
    func connect(cols: Int, rows: Int) async throws { connections += 1; sizes.append((cols, rows)) }
    func send(_ data: Data) async throws { inputs.append(data) }
    func resize(cols: Int, rows: Int) async throws { sizes.append((cols, rows)) }
    func disconnect() async { continuation.finish() }
}
