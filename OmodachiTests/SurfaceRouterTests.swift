import XCTest
@testable import Omodachi

/// ARCH-1 §1.3 and §5. The panel registry, the bar's arithmetic and the
/// router's three arbitrations (A-55, A-59's toggle, N-32's `returnTo`), with
/// no window and no host.
@MainActor final class PanelRegistryTests: XCTestCase {
    private func registry() -> PanelRegistry {
        let defaults = UserDefaults(suiteName: "arch1.registry.\(UUID().uuidString)")!
        return PanelRegistry(hostID: "host-a", defaults: defaults)
    }

    func testTheSixEntriesAreInTheStudysOrder() {
        XCTAssertEqual(registry().entries.map(\.id),
                       [.remote, .agent, .herdr, .ssh, .settings, .notifications])
    }

    func testPanelOneHasNoEntryBecauseTheLogoOpensIt() {
        XCTAssertFalse(registry().entries.contains { $0.id == .menu })
    }

    func testTurningAnEntryOffTakesItOffTheBarAndNothingElse() {
        let registry = registry()
        registry.setEnabled(.herdr, false)
        XCTAssertEqual(registry.barEntries.map(\.id), [.remote, .agent, .ssh, .settings, .notifications])
        XCTAssertFalse(registry.isEnabled(.herdr))
        // The panel is still a panel; only its slot is gone.
        XCTAssertTrue(registry.entries.contains { $0.id == .herdr })
    }

    func testSettingsCannotBeTurnedOffBecauseItIsTheWayBack() {
        let registry = registry()
        registry.setEnabled(.settings, false)
        XCTAssertTrue(registry.isEnabled(.settings))
    }

    func testTheSwitchesAreRememberedPerHost() {
        let defaults = UserDefaults(suiteName: "arch1.registry.\(UUID().uuidString)")!
        let registry = PanelRegistry(hostID: "host-a", defaults: defaults)
        registry.setEnabled(.ssh, false)
        registry.hostID = "host-b"
        XCTAssertTrue(registry.isEnabled(.ssh), "another host has its own switches")
        registry.hostID = "host-a"
        XCTAssertFalse(registry.isEnabled(.ssh))
        // And they survive the object, because they are a preference.
        XCTAssertFalse(PanelRegistry(hostID: "host-a", defaults: defaults).isEnabled(.ssh))
    }
}

@MainActor final class SurfaceRouterTests: XCTestCase {
    private var registry: PanelRegistry!
    private var router: SurfaceRouter!

    override func setUp() async throws {
        registry = PanelRegistry(hostID: "host-a",
                                 defaults: UserDefaults(suiteName: "arch1.router.\(UUID().uuidString)")!)
        router = SurfaceRouter(registry: registry)
    }

    // MARK: - A-55

    func testAnEntryOpensItsPanelAndTheSameEntryAgainReturnsToOne() {
        XCTAssertEqual(router.panel, .menu)
        router.tapEntry(.agent)
        XCTAssertEqual(router.panel, .agent)
        router.tapEntry(.agent)
        XCTAssertEqual(router.panel, .menu)
    }

    func testTappingAnotherEntryReplacesRatherThanStacks() {
        router.tapEntry(.agent)
        router.tapEntry(.notifications)
        XCTAssertEqual(router.panel, .notifications)
        router.tapEntry(.notifications)
        XCTAssertEqual(router.panel, .menu, "there is no stack to pop back through")
    }

    func testTheLogoIsAlwaysPanelOne() {
        router.tapEntry(.settings)
        router.tapLogo()
        XCTAssertEqual(router.panel, .menu)
        router.tapLogo()
        XCTAssertEqual(router.panel, .menu)
    }

    // MARK: - A-59's toggle

    private func summon(_ view: PanelSummon.View) -> SurfaceRouter.SummonOutcome {
        router.consume(PanelSummon(sessionID: "rs_1", revision: 1, view: view))
    }

    func testASummonOpensSwitchesAndThenDismisses() {
        router.enterPicture()
        XCTAssertFalse(router.overlayVisible)
        XCTAssertEqual(summon(.overview), .opened)
        XCTAssertTrue(router.overlayVisible)
        XCTAssertEqual(router.panel, .menu)
        XCTAssertEqual(router.column, .menu)

        XCTAssertEqual(summon(.settings), .switched)
        XCTAssertTrue(router.overlayVisible)
        XCTAssertEqual(router.panel, .settings)

        XCTAssertEqual(summon(.settings), .dismissed)
        XCTAssertFalse(router.overlayVisible)
    }

    func testTheTwoHalvesOfPanelOneAreDifferentViewsOfTheSamePanel() {
        router.enterPicture()
        XCTAssertEqual(summon(.overview), .opened)
        XCTAssertEqual(summon(.keybindings), .switched,
                       "same panel, other column: a switch, not a dismissal")
        XCTAssertEqual(router.column, .keybindings)
        XCTAssertTrue(router.focusKeybindingsSearch, "A-25: SUPER+K lands on that search field")
        XCTAssertEqual(summon(.keybindings), .dismissed)
    }

    func testDismissingAnOverlayIsWhatTappingThePictureDoes() {
        router.enterPicture()
        _ = summon(.overview)
        router.dismissOverlay()
        XCTAssertFalse(router.overlayVisible)
        XCTAssertFalse(router.focusKeybindingsSearch)
    }

    func testASummonBeatsADisabledEntry() {
        registry.setEnabled(.settings, false)   // refused, so use one that can be
        registry.setEnabled(.notifications, false)
        router.enterPicture()
        XCTAssertEqual(summon(.settings), .opened)
        XCTAssertEqual(router.panel, .settings)
        // And off the picture too: the preference hides the slot, not the panel.
        router.endSession()
        router.show(.notifications)
        XCTAssertEqual(router.panel, .notifications)
    }

    func testASummonWithNoSessionStillMovesThePanelArea() {
        XCTAssertEqual(summon(.settings), .switched)
        XCTAssertEqual(router.panel, .settings)
        XCTAssertFalse(router.overlayVisible, "there is no picture to overlay")
    }

    // MARK: - N-32's returnTo

    func testReturnToIsThePanelShowingWhenStartWasPressed() {
        router.tapEntry(.agent)
        router.tapEntry(.remote)          // opening ② is not "where you came from"
        router.rememberReturn()
        router.enterPicture()
        router.endSession()
        XCTAssertEqual(router.panel, .menu, "②'s own panel cannot be the way back")
    }

    func testTheRealComingFromIsRemembered() {
        router.tapEntry(.herdr)
        router.rememberReturn()
        router.enterPicture()
        router.endSession()
        XCTAssertEqual(router.panel, .herdr)
    }

    func testPanelsOpenedDuringASessionDoNotChangeWhereItEnds() {
        router.tapEntry(.agent)
        router.rememberReturn()
        router.enterPicture()
        _ = summon(.overview)
        router.tapEntry(.notifications)
        router.tapEntry(.settings)
        router.endSession()
        XCTAssertEqual(router.panel, .agent)
    }

    func testAReturnToThatIsNoLongerOnTheBarLandsOnPanelOne() {
        router.tapEntry(.ssh)
        router.rememberReturn()
        router.enterPicture()
        registry.setEnabled(.ssh, false)
        router.endSession()
        XCTAssertEqual(router.panel, .menu)
    }

    func testAllFourEndingsAreTheSameEnding() {
        // The router has one `endSession`; the four paths differ only in who
        // calls it. Each is asserted by calling it from the same state.
        for _ in 0..<4 {
            router.show(.agent)
            router.rememberReturn()
            router.enterPicture()
            XCTAssertEqual(router.stage, .picture)
            router.endSession()
            XCTAssertEqual(router.stage, .panels)
            XCTAssertEqual(router.panel, .agent)
            XCTAssertFalse(router.hasSession)
        }
    }

    func testDuringASessionTheRemoteEntryOpensTheSessionCardAndThenClosesIt() {
        router.tapEntry(.agent)
        router.rememberReturn()
        router.enterPicture()
        _ = summon(.overview)
        router.tapEntry(.remote)
        XCTAssertEqual(router.panel, .remote, "A-57: the panel is the session card")
        XCTAssertTrue(router.hasSession, "opening ② does not end anything")
        router.tapEntry(.remote)
        XCTAssertFalse(router.overlayVisible, "REMOTE-3: tapping it again closes onto the picture")
        XCTAssertTrue(router.hasSession, "A-55 governs the entry, not the session")
    }

    // MARK: - A-66 (UX-2 §4): a call hands the picture back

    /// Leo: the panel he summoned to run something stayed on top of the thing
    /// he had just run, every time.
    func testARowThatRanOnTheHostGivesThePictureBack() {
        router.rememberReturn()
        router.enterPicture()
        _ = summon(.overview)
        XCTAssertTrue(router.overlayVisible)
        router.invokedHostAction()
        XCTAssertFalse(router.overlayVisible, "A-66: the call has gone out, the machine is what to look at")
        XCTAssertEqual(router.stage, .picture)
        XCTAssertTrue(router.hasSession, "closing the overlay ends nothing")
        XCTAssertEqual(router.returnTo, .menu, "N-32 is not a party to this either")
    }

    /// Off the picture there is nothing to hand back, and ① is not a thing to
    /// be dismissed out of.
    func testARowThatRanOnTheHostChangesNothingOffThePicture() {
        router.tapEntry(.settings)
        router.invokedHostAction()
        XCTAssertEqual(router.stage, .panels)
        XCTAssertEqual(router.panel, .settings, "the panel stage is the app; there is nowhere to go")
    }

    /// The overlay is already down (the user tapped the picture). A late
    /// receipt must not re-open anything or end anything.
    func testALateReceiptWithNoOverlayIsANoOp() {
        router.rememberReturn()
        router.enterPicture()
        _ = summon(.overview)
        router.dismissOverlay()
        router.invokedHostAction()
        XCTAssertFalse(router.overlayVisible)
        XCTAssertEqual(router.stage, .picture)
    }

    /// N-32 across A-66: whatever the overlay did on the way, the session ends
    /// where "开始接管" was pressed.
    func testReturnToSurvivesEveryCallMadeFromTheOverlay() {
        router.tapEntry(.herdr)
        router.rememberReturn()
        router.enterPicture()
        for view in [PanelSummon.View.overview, .settings, .keybindings] {
            _ = summon(view)
            router.invokedHostAction()
            XCTAssertFalse(router.overlayVisible)
        }
        // The overlay is down again, so the entry needs the host's icon first
        // — that is the whole of A-59: from the picture there is no bar to tap.
        _ = summon(.overview)
        router.tapEntry(.remote)
        XCTAssertEqual(router.panel, .remote, "UX-2 §3: the entry lands on ② while a session is up")
        router.invokedHostAction()
        router.endSession()
        XCTAssertEqual(router.panel, .herdr)
        XCTAssertEqual(router.returnTo, .menu, "spent, and reset")
    }

    // MARK: - REMOTE-3: the bar's own entries close onto the picture

    /// Leo, on the iPad: "remote 里再次点击 logo icon 不能回到 remote 桌面".
    func testInRemoteTheLogoAgainIsThePictureBack() {
        router.tapEntry(.agent)
        router.rememberReturn()
        router.enterPicture()
        XCTAssertEqual(summon(.overview), .opened)
        XCTAssertTrue(router.panelAreaVisible)

        router.tapLogo()
        XCTAssertFalse(router.overlayVisible, "the same entry again closes it (A-55 + A-59)")
        XCTAssertEqual(router.stage, .picture, "closing an overlay is not ending a session")
        XCTAssertTrue(router.hasSession)
        XCTAssertFalse(router.panelAreaVisible, "INPUT-2's gate reopens off this one flag")
        XCTAssertEqual(router.returnTo, .agent, "N-32: nothing here touches where the session ends")

        // And the session still ends where it was going to.
        router.endSession()
        XCTAssertEqual(router.panel, .agent)
    }

    func testInRemoteAnEntryAgainIsThePictureBackToo() {
        router.enterPicture()
        _ = summon(.overview)
        router.tapEntry(.settings)
        XCTAssertEqual(router.panel, .settings)
        XCTAssertTrue(router.overlayVisible, "another entry is a switch, not a close")

        router.tapEntry(.settings)
        XCTAssertFalse(router.overlayVisible)
        XCTAssertEqual(router.stage, .picture)
    }

    /// The logo over a panel that is not ① still has somewhere to go: ①. Only
    /// the tap after that one closes.
    func testInRemoteTheLogoOverAnotherPanelSwitchesFirstAndClosesSecond() {
        router.enterPicture()
        XCTAssertEqual(summon(.settings), .opened)
        router.tapLogo()
        XCTAssertEqual(router.panel, .menu)
        XCTAssertTrue(router.overlayVisible)
        router.tapLogo()
        XCTAssertFalse(router.overlayVisible)
    }

    /// A summon that landed on the keybindings half is still panel ①, and the
    /// logo is panel ①'s entry: it closes, and takes A-25's focus with it.
    func testTheLogoClosesTheKeybindingsHalfAndDropsItsFocus() {
        router.enterPicture()
        _ = summon(.keybindings)
        XCTAssertTrue(router.focusKeybindingsSearch)
        router.tapLogo()
        XCTAssertFalse(router.overlayVisible)
        XCTAssertFalse(router.focusKeybindingsSearch)
    }

    /// Off the picture nothing changed: A-55's tap-again is still ①, and the
    /// bar cannot be tapped at all while the picture is bare.
    func testOffThePictureTapAgainIsStillPanelOne() {
        router.tapEntry(.herdr)
        router.tapEntry(.herdr)
        XCTAssertEqual(router.panel, .menu)
        XCTAssertEqual(router.stage, .panels)

        router.rememberReturn()
        router.enterPicture()
        XCTAssertFalse(router.panelAreaVisible, "there is no bar on a bare picture")
        router.tapLogo()
        XCTAssertEqual(router.panel, .menu)
        XCTAssertFalse(router.overlayVisible, "and a tap that cannot happen opens nothing")
    }

    func testGoingBackToThePictureLeavesTheSessionAlone() {
        router.rememberReturn()
        router.enterPicture()
        _ = summon(.overview)
        router.resumePicture()
        XCTAssertEqual(router.stage, .picture)
        XCTAssertFalse(router.overlayVisible)
        XCTAssertTrue(router.hasSession)
    }

    /// N-32: the full-screen picture does not exist without a session. A router
    /// that has never had one cannot be put on it.
    func testThereIsNoPictureWithoutASession() {
        XCTAssertEqual(router.stage, .panels)
        router.resumePicture()
        XCTAssertEqual(router.stage, .panels)
    }
}

final class BarModelTests: XCTestCase {
    private let entries = 6
    private let five = QuickAction.allCases

    /// Study 04 §6, line by line. `available` is the long edge minus the safe
    /// area the window reserves at its two ends.
    func testEveryScreenInTheStudyFitsAtFullSize() {
        let workspaces = [1, 2, 3, 4, 5, 7]
        for (name, available) in [("iPad landscape", CGFloat(1194 - 20)),
                                  ("iPad portrait", CGFloat(1194 - 20)),
                                  ("iPhone landscape", CGFloat(852 - 21)),
                                  ("iPhone portrait", CGFloat(852 - 34))] {
            let plan = BarMetrics.plan(available: available, workspaces: workspaces,
                                       occupied: [1, 2, 7], entries: entries, actions: five)
            XCTAssertEqual(plan.ladder, .full, name)
            XCTAssertEqual(plan.workspaces, workspaces, name)
        }
    }

    /// 318 + 220 + 264 + 34 = 836 ≤ 852. rev 5's headline: with the microphone
    /// gone the phone no longer gives anything up.
    func testThePhoneInPortraitNoLongerNeedsTheLadder() {
        let plan = BarMetrics.plan(available: 852 - 34, workspaces: [1, 2, 3, 4, 5, 7],
                                   occupied: [1, 2, 7], entries: 6, actions: five)
        XCTAssertEqual(plan.ladder, .full)
        XCTAssertEqual(plan.centreSlot, 44)
        XCTAssertEqual(plan.visibleActions.count, 5)
    }

    /// The Duo's outer screen is the one combination the study admits it cannot
    /// always solve: 678 high, six workspaces, five actions. Study 04 §7 open
    /// question 2 does the arithmetic — with four or fewer occupied workspaces
    /// the ladder's last rung is enough, and beyond that the workspace segment
    /// has to scroll.
    func testTheDuoOuterScreenWalksTheWholeLadder() {
        let workspaces = [1, 2, 3, 4, 5, 7]
        let three = BarMetrics.plan(available: 678 - 34, workspaces: workspaces,
                                    occupied: [1, 2, 7], entries: 6, actions: five)
        XCTAssertEqual(three.ladder, .occupiedWorkspaces)
        XCTAssertFalse(three.scrollsWorkspaces)
        XCTAssertEqual(three.workspaces, [1, 2, 7], "only the ones holding something")
        XCTAssertEqual(three.visibleActions, BarMetrics.overflowActions)
        XCTAssertEqual(three.overflowActions, [.rotationLock, .hostAudio])

        // Five occupied: 44 + 10 + 5×44 + 4×32 + 264 = 666 > 644. The entries
        // and the centre are already as small as they are allowed to get, so
        // the squares scroll rather than the way in shrinking.
        let five = BarMetrics.plan(available: 678 - 34, workspaces: workspaces,
                                   occupied: [1, 2, 3, 4, 7], entries: 6, actions: Self.actions)
        XCTAssertEqual(five.ladder, .scrollingWorkspaces)
        XCTAssertTrue(five.scrollsWorkspaces)
        XCTAssertEqual(five.visibleActions.count, 3, "入口段永远不许收")
    }

    private static let actions = QuickAction.allCases

    func testTheLadderIsWalkedInOrder() {
        let workspaces = [1, 2, 3, 4, 5, 7]
        // Just short of full: 318 + 220 + 264 = 802.
        XCTAssertEqual(BarMetrics.plan(available: 801, workspaces: workspaces, occupied: [1],
                                       entries: 6, actions: five).ladder, .compactCentre)
        // Short of the compact centre too: 318 + 160 + 264 = 742.
        XCTAssertEqual(BarMetrics.plan(available: 741, workspaces: workspaces, occupied: [1],
                                       entries: 6, actions: five).ladder, .overflowCentre)
    }

    func testTheEntriesAndTheCentreNeverShrinkPastTheOverflow() {
        let plan = BarMetrics.plan(available: 320, workspaces: [1, 2, 3, 4, 5, 7],
                                   occupied: [1], entries: 6, actions: five)
        XCTAssertEqual(BarMetrics.rightWidth(entries: 6), 264, "入口段永远不许收")
        XCTAssertEqual(plan.visibleActions.count, 3)
        XCTAssertEqual(plan.centreSlot, 32)
    }

    func testWithNoSessionTheCentreIsEmptyAndOnlyTheWorkspacesCanGive() {
        let plan = BarMetrics.plan(available: 678 - 34, workspaces: [1, 2, 3, 4, 5, 7],
                                   occupied: [1, 2, 7], entries: 6, actions: [])
        XCTAssertEqual(plan.ladder, .full, "616 ≤ 644")
        XCTAssertTrue(plan.visibleActions.isEmpty)
        XCTAssertEqual(plan.workspaces.count, 6)
    }

    func testDisablingEntriesGivesTheBarRoomBack() {
        let workspaces = [1, 2, 3, 4, 5, 7]
        let six = BarMetrics.plan(available: 741, workspaces: workspaces, occupied: [1],
                                  entries: 6, actions: five)
        let four = BarMetrics.plan(available: 741, workspaces: workspaces, occupied: [1],
                                   entries: 4, actions: five)
        XCTAssertEqual(six.ladder, .overflowCentre)
        XCTAssertEqual(four.ladder, .full, "two entries off is 88 points back")
    }
}

final class QuickActionTests: XCTestCase {
    /// Study 04 §21 board ④d: only one of the five depends on the backend.
    func testOnlyHostAudioEverDimsForTheBackend() {
        let states = QuickActionContext(hasSession: true, backendHasAudio: false).states()
        let dimmed = states.filter { !$0.enabled }.map(\.action)
        XCTAssertEqual(dimmed, [.hostAudio])
        XCTAssertEqual(states.first { $0.action == .hostAudio }?.reason, Strings.quickAudioNoChannel,
                       "the reason is the catalog's, so this passes in either language")
    }

    func testThePreferenceIsASecondReasonWithItsOwnSentence() {
        let states = QuickActionContext(hasSession: true, backendHasAudio: true,
                                        hostAudioAllowed: false).states()
        XCTAssertEqual(states.first { $0.action == .hostAudio }?.reason, Strings.quickAudioOff)
    }

    func testTheLocalSwitchesAreNeverDimmed() {
        let states = QuickActionContext(hasSession: true).states()
        for action in [QuickAction.keyboard, .rotationLock, .pointerMode] {
            XCTAssertTrue(states.first { $0.action == action }?.enabled == true, "\(action)")
        }
    }

    /// The centre segment only exists while a session does, so `endSession` is
    /// never on screen in the state that would dim it.
    func testEndSessionIsTheOneThatCannotDimAlone() {
        XCTAssertFalse(QuickActionContext(hasSession: false).states()
            .first { $0.action == .endSession }?.enabled == true)
    }

    /// N-35 rev 5: the microphone is not one of them, anywhere.
    func testThereIsNoMicrophone() {
        XCTAssertEqual(QuickAction.allCases.count, 5)
        XCTAssertFalse(QuickAction.allCases.map(\.rawValue).contains { $0.contains("mic") })
    }

    /// A-65: every item reads as a name plus a state, and a dimmed one says why.
    func testEveryActionHasAnAccessibilityValue() {
        for state in QuickActionContext(hasSession: true, backendHasAudio: false).states() {
            let value = state.action.value(on: state.on, enabled: state.enabled, reason: state.reason)
            XCTAssertFalse(value.isEmpty, "\(state.action)")
            XCTAssertFalse(state.action.title.isEmpty)
        }
    }
}
