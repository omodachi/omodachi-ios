import XCTest
@testable import Omodachi

/// CLIP-1, both halves.
///
/// §1 is a list that no longer carries five rows nothing can run, and a switch
/// in ⑥ that puts them back. §2 is the clipboard, and the tests that matter
/// there are about what does *not* happen: no sync while either switch is off,
/// no pasteboard read outside the front, no echo of what just arrived.
@MainActor final class ClipboardHiddenRowTests: XCTestCase {

    private func snapshot(hidden: Bool?) throws -> ShortcutSnapshot {
        let field = hidden.map { ",\"hidden\":\($0)" } ?? ""
        let json = """
        {"contract_revision":"omodachi.v1","revision":"r1","source":"hyprland","available":true,"reason":null,
         "items":[{"id":"copy","label":"Universal copy","shortcut_display":"SUPER + C","order":0,
                   "enabled":false,"disabled_reason":"binding_adapter_unavailable",
                   "disabled_reason_detail":"host record carries no executable binding",
                   "action_ref":null,"requires_target":false\(field)},
                  {"id":"term","label":"Terminal","shortcut_display":"SUPER + RETURN","order":1,
                   "enabled":true,"disabled_reason":null,"disabled_reason_detail":null,
                   "action_ref":"omodachi.shortcut.term","requires_target":false\(hidden == nil ? "" : ",\"hidden\":false")}]}
        """
        return try JSONDecoder().decode(ShortcutListDTO.self, from: Data(json.utf8)).snapshot()
    }

    private var context: ShortcutContext {
        ShortcutContext(hostID: "omarchy", surface: .controller, stateRevision: 1)
    }

    func testARowTheHostCallsHiddenIsNotInTheList() throws {
        var model = ShortcutPanelModel()
        model.snapshot = try snapshot(hidden: true)
        XCTAssertEqual(model.visibleEntries(in: context).map(\.label), ["Terminal"])
        XCTAssertEqual(model.unrunnableCount(), 1)
    }

    func testTheSwitchPutsItBackStillGreyedWithTheHostsOwnReason() throws {
        var model = ShortcutPanelModel()
        model.snapshot = try snapshot(hidden: true)
        model.showsUnrunnableEntries = true
        let entries = model.visibleEntries(in: context)
        XCTAssertEqual(entries.map(\.label), ["Universal copy", "Terminal"])
        let copy = try XCTUnwrap(entries.first)
        // Showing is not enabling: the row is still refused, with core's words.
        XCTAssertFalse(copy.enabled)
        XCTAssertEqual(model.disabledReason(for: copy, context: context),
                       "host record carries no executable binding")
    }

    func testAHostFromBeforeClip1HidesNothing() throws {
        // No `hidden` field at all. A missing field is not a hidden row, so an
        // un-upgraded host's list is exactly what it was.
        var model = ShortcutPanelModel()
        model.snapshot = try snapshot(hidden: nil)
        XCTAssertEqual(model.visibleEntries(in: context).map(\.label), ["Universal copy", "Terminal"])
        XCTAssertEqual(model.unrunnableCount(), 0)
    }

    func testHidingAndCoverageAreDifferentQuestions() throws {
        // A row the app's own controls cover is hidden behind the expandable
        // footer and can be brought back and *run*. A row the host cannot run
        // is a different thing, and the two switches do not interfere.
        var model = ShortcutPanelModel()
        model.snapshot = try snapshot(hidden: true)
        model.showsCoveredEntries = true
        XCTAssertEqual(model.visibleEntries(in: context).map(\.label), ["Terminal"])
        model.showsUnrunnableEntries = true
        XCTAssertEqual(model.visibleEntries(in: context).count, 2)
    }

    func testTheDeviceSwitchIsOffUntilSomebodyTurnsItOn() {
        XCTAssertFalse(ShellPreferences().showsUnrunnableKeybindings)
        XCTAssertEqual(ShellPreferences().clipboardSync, .off)
    }
}

// MARK: - The clipboard

/// A pasteboard that counts every read, because on a real device every read is
/// a banner the person sees.
@MainActor final class FakePasteboard: DevicePasteboard {
    var stored: String?
    var changeCount = 0
    var reads = 0
    var writes: [String] = []

    var hasStrings: Bool { stored?.isEmpty == false }
    func read() -> String? {
        reads += 1
        return stored
    }
    func write(_ text: String) {
        stored = text
        changeCount += 1
        writes.append(text)
    }
    /// Somebody copied something on this device.
    func copied(_ text: String) {
        stored = text
        changeCount += 1
    }
}

final class FakeClipboardService: ClipboardServing, @unchecked Sendable {
    var hostText = "from the desktop"
    var mode = "both"
    var written: [String] = []
    var failure: ClipboardHostError?
    var modeFailure: Error?

    func fetchClipboard() async throws -> String {
        if let failure { throw failure }
        return hostText
    }
    @discardableResult func putClipboard(_ text: String) async throws -> Int {
        if let failure { throw failure }
        written.append(text)
        hostText = text
        return text.utf8.count
    }
    func fetchClipboardMode() async throws -> String {
        if let modeFailure { throw modeFailure }
        return mode
    }
}

@MainActor final class ClipboardSyncTests: XCTestCase {

    private func coordinator(host: String = "both", device: ClipboardSyncChoice = .both)
        async -> (ClipboardSyncCoordinator, FakeClipboardService, FakePasteboard) {
        let service = FakeClipboardService()
        service.mode = host
        let board = FakePasteboard()
        let value = ClipboardSyncCoordinator(pasteboard: board)
        // `attach` starts a refresh of its own. Let it finish here: a refresh
        // that lands later would clear a failure a test had just provoked.
        value.attach(service: service, deviceMode: device)
        await quiesce()
        return (value, service, board)
    }

    func testBothSwitchesHaveToBeOnAndTheNarrowerOneWins() async {
        var (sync, _, _) = await coordinator(host: "both", device: .both)
        XCTAssertEqual(sync.effective, .both)
        (sync, _, _) = await coordinator(host: "both", device: .hostToDevice)
        XCTAssertEqual(sync.effective, .hostToDevice)
        (sync, _, _) = await coordinator(host: "host_to_device", device: .both)
        XCTAssertEqual(sync.effective, .hostToDevice)
        (sync, _, _) = await coordinator(host: "off", device: .both)
        XCTAssertEqual(sync.effective, .off)
        (sync, _, _) = await coordinator(host: "both", device: .off)
        XCTAssertEqual(sync.effective, .off)
    }

    func testAModeThisBuildDoesNotKnowIsOff() async {
        let (sync, _, _) = await coordinator(host: "everything", device: .both)
        XCTAssertEqual(sync.hostMode, .off)
        XCTAssertEqual(sync.effective, .off)
    }

    func testTheHostsClipboardReachesThePasteboardWithoutReadingIt() async throws {
        let (sync, _, board) = await coordinator()
        sync.hostClipboardChanged()
        try await settle(sync)
        XCTAssertEqual(board.writes, ["from the desktop"])
        XCTAssertEqual(board.reads, 0, "arriving text is written; nothing is read to accept it")
        XCTAssertEqual(sync.received, 1)
    }

    func testNothingArrivesWhileEitherSwitchIsOff() async throws {
        for (host, device) in [("off", ClipboardSyncChoice.both), ("both", .off)] {
            let (sync, _, board) = await coordinator(host: host, device: device)
            sync.hostClipboardChanged()
            try await settle(sync)
            XCTAssertTrue(board.writes.isEmpty)
        }
    }

    func testWhatJustArrivedIsNotPushedBack() async throws {
        let (sync, service, board) = await coordinator()
        sync.hostClipboardChanged()
        try await settle(sync)
        sync.appBecameActive()
        try await settle(sync)
        XCTAssertEqual(service.written, [], "the host's own text does not go back to the host")
        XCTAssertEqual(board.reads, 0, "and the pasteboard is not even read to find that out")
    }

    func testComingToTheFrontPushesWhatWasCopiedHere() async throws {
        let (sync, service, board) = await coordinator()
        board.copied("from the iPad")
        sync.appBecameActive()
        try await settle(sync)
        XCTAssertEqual(service.written, ["from the iPad"])
        XCTAssertEqual(sync.sent, 1)
    }

    func testComingToTheFrontTwiceWithNothingCopiedReadsNothing() async throws {
        // Every read of the pasteboard is a system banner. Two trips to the
        // app with nothing copied in between must produce one at most.
        let (sync, service, board) = await coordinator()
        board.copied("from the iPad")
        sync.appBecameActive()
        try await settle(sync)
        let reads = board.reads
        sync.appBecameActive()
        sync.appBecameActive()
        try await settle(sync)
        XCTAssertEqual(board.reads, reads, "changeCount did not move, so nothing was read")
        XCTAssertEqual(service.written, ["from the iPad"])
    }

    func testOneWayNeverPushes() async throws {
        let (sync, service, board) = await coordinator(host: "host_to_device", device: .both)
        board.copied("from the iPad")
        sync.appBecameActive()
        try await settle(sync)
        XCTAssertEqual(service.written, [])
        XCTAssertEqual(board.reads, 0, "a device that may not write does not read either")
    }

    func testMoreThanSixtyFourKilobytesIsRefusedHereWithAReason() async throws {
        let (sync, service, board) = await coordinator()
        board.copied(String(repeating: "a", count: CompanionHostClient.clipboardLimit + 1))
        sync.appBecameActive()
        try await settle(sync)
        XCTAssertEqual(service.written, [])
        XCTAssertEqual(sync.failure, ReasonText.message("clipboard_too_large", domain: .host, status: 413))
    }

    func testTheHostsRefusalIsAboutTheSwitchAndNotAboutPairing() async throws {
        let (sync, service, _) = await coordinator()
        service.failure = ClipboardHostError(code: "clipboard_sync_disabled", status: 403)
        sync.hostClipboardChanged()
        try await settle(sync)
        XCTAssertEqual(sync.failure, Strings.reasonClipboardSyncDisabled)
        XCTAssertTrue(ClipboardHostError(code: "clipboard_write_disabled", status: 403).isRefusedByPreference)
        XCTAssertFalse(ClipboardHostError(code: "clipboard_unavailable", status: 503).isRefusedByPreference)
    }

    func testAHostWithoutClip1IsNotAnErrorItIsAHostWithoutTheFeature() async {
        let service = FakeClipboardService()
        service.modeFailure = CompanionHostError.unavailable(code: "route_unavailable", message: "")
        let sync = ClipboardSyncCoordinator(pasteboard: FakePasteboard())
        sync.attach(service: service, deviceMode: .both)
        await sync.refresh()
        XCTAssertFalse(sync.supported)
        XCTAssertNil(sync.failure)
        XCTAssertEqual(sync.effective, .off)
    }

    func testOneSwitchOnAndTheOtherOffSaysSoRatherThanGoingQuiet() async {
        var (sync, _, _) = await coordinator(host: "off", device: .both)
        XCTAssertTrue(sync.waitingOnTheOtherSwitch)
        (sync, _, _) = await coordinator(host: "host_to_device", device: .both)
        XCTAssertTrue(sync.waitingOnTheOtherSwitch)
        (sync, _, _) = await coordinator(host: "both", device: .both)
        XCTAssertFalse(sync.waitingOnTheOtherSwitch)
        (sync, _, _) = await coordinator(host: "both", device: .off)
        XCTAssertFalse(sync.waitingOnTheOtherSwitch, "this device said no; nothing is waiting")
    }

    func testDetachForgetsEverythingIncludingTheDigest() async throws {
        let (sync, service, board) = await coordinator()
        board.copied("from the iPad")
        sync.appBecameActive()
        try await settle(sync)
        sync.detach()
        XCTAssertEqual(sync.hostMode, .off)
        XCTAssertEqual(sync.sent, 0)
        XCTAssertEqual(sync.received, 0)
        XCTAssertEqual(service.written, ["from the iPad"])
    }

    /// The coordinator does its work in a `Task`; this lets those run.
    private func settle(_ sync: ClipboardSyncCoordinator) async throws {
        await quiesce()
    }

    private func quiesce() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor final class ClipboardForegroundOrderTests: XCTestCase {
    /// The bug the first host walk found. Coming back from the background
    /// reconnects, and a reconnect resets the host's half to off until
    /// `GET /v1/preferences` answers — so at the instant the app is in front
    /// it does not yet know whether it may push. The push waits for the answer
    /// rather than being dropped.
    func testAPushSurvivesTheGapBetweenForegroundAndKnowingTheHostsHalf() async {
        let service = FakeClipboardService()
        let board = FakePasteboard()
        board.copied("from the iPad")
        let sync = ClipboardSyncCoordinator(pasteboard: board)
        // The app is in front before anything is known about the host.
        sync.appBecameActive()
        XCTAssertEqual(service.written, [], "nothing can be sent before the host has answered")
        sync.attach(service: service, deviceMode: .both)
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(service.written, ["from the iPad"])
        XCTAssertEqual(sync.sent, 1)
    }

    /// And it is one push, not a standing order: the same trip to the front
    /// does not keep pushing every time the host answers again.
    func testTheDebtIsClearedOnceItIsPaid() async {
        let service = FakeClipboardService()
        let board = FakePasteboard()
        board.copied("from the iPad")
        let sync = ClipboardSyncCoordinator(pasteboard: board)
        sync.attach(service: service, deviceMode: .both)
        sync.appBecameActive()
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<40 { await Task.yield() }
        await sync.refresh()
        await sync.refresh()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(service.written, ["from the iPad"])
        XCTAssertEqual(board.reads, 1, "one trip to the front is one read, so one system alert")
    }
}
