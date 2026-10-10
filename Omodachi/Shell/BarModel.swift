import Foundation
import SwiftUI

/// A-49 / A-60. What is in the bar's three segments, and what happens when they
/// do not fit.
///
/// The bar is one row: left is the logo, the connection dot and the workspaces;
/// the centre is empty except under Remote, where it is three quick actions; the
/// right is the panel entries. The arithmetic is Study 04 §6's, in logical
/// points:
///
/// | | non-Remote | Remote |
/// |---|---|---|
/// | left | 44 + 10 + N×44 | same |
/// | centre | 0 | 3×44 = 132 |
/// | right | entries×44 | same |
///
/// Every screen but one fits at full size once the microphone left (rev 5): the
/// iPhone in portrait needs 318 + 132 + 264 + 34 = 748 ≤ 852. The Duo's outer
/// screen is 678 and cannot, which is what the ladder below is for.

/// A-60's quick actions, three since POLISH-R. There is no microphone: rev 5
/// took it out of the study entirely, and N-35 leaves the app with none at all.
///
/// POLISH-R (Leo, 2026-10-05) took two more out:
/// * `endSession`, a stop square (U+F04D) that did not end anything — it only
///   opened the Remote panel, whose session card holds the real two-step End.
///   Leo read it as a pause button that does nothing, which is what it was.
///   The panel is one tap away from the logo mark and the Remote entry, so
///   nothing was folded in its place.
/// * `rotationLock`, drawn as a bare padlock (U+F023). Its own lever was one
///   UIKit never reads, and the system's orientation lock in Control Center
///   already does the job, so Leo removed it rather than have it fixed.
enum QuickAction: String, CaseIterable, Identifiable, Sendable {
    case keyboard, pointerMode, hostAudio
    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard: Strings.quickKeyboard
        case .pointerMode: Strings.quickPointerMode
        case .hostAudio: Strings.quickHostAudio
        }
    }

    func icon(on: Bool) -> (symbol: String, nerd: String) {
        switch self {
        case .keyboard: on ? Icon.keyboardDown : Icon.keyboard
        case .pointerMode: Icon.pointer
        case .hostAudio: on ? Icon.speaker : Icon.speakerOff
        }
    }

    /// The value VoiceOver reads after the name (A-65).
    func value(on: Bool, enabled: Bool, reason: String?) -> String {
        guard enabled else { return reason ?? Strings.quickUnavailable }
        switch self {
        case .keyboard: return on ? Strings.quickKeyboardUp : Strings.quickKeyboardDown
        case .pointerMode: return on ? Strings.quickPointerTouchpad : Strings.quickPointerDirect
        case .hostAudio: return on ? Strings.quickOn : Strings.quickOff
        }
    }
}

/// One quick action, evaluated against what the session can actually do.
///
/// Study 04 §21 board ④d is the table this implements. Only one of the three
/// depends on the backend: VNC has no audio channel at all
/// (`capabilities.vnc.audio == false`), and host audio playback is a preference
/// in ⑥ on top of that. The rest are local switches, so they are never dimmed.
struct QuickActionState: Equatable, Identifiable, Sendable {
    let action: QuickAction
    var enabled: Bool
    var on: Bool
    /// A-65: dimmed is also disabled, and the reason is what the 26-high toast
    /// says if the user presses it anyway.
    var reason: String?
    var id: String { action.rawValue }
}

/// What the backend and the preferences allow, so the bar does not have to
/// reach into the Remote layer to find out (ARCH-1 §1.3).
struct QuickActionContext: Equatable, Sendable {
    var hasSession = false
    var keyboardVisible = false
    var relativeTouchpad = false
    /// `capabilities.<backend>.audio`. False for VNC, always.
    var backendHasAudio = true
    /// ⑥'s `host_audio_playback`.
    var hostAudioAllowed = true
    var hostAudioOn = false

    func states() -> [QuickActionState] {
        QuickAction.allCases.map { action in
            switch action {
            case .keyboard:
                return .init(action: action, enabled: true, on: keyboardVisible)
            case .pointerMode:
                return .init(action: action, enabled: true, on: relativeTouchpad)
            case .hostAudio:
                if !backendHasAudio {
                    return .init(action: action, enabled: false, on: false,
                                 reason: Strings.quickAudioNoChannel)
                }
                if !hostAudioAllowed {
                    return .init(action: action, enabled: false, on: false,
                                 reason: Strings.quickAudioOff)
                }
                return .init(action: action, enabled: true, on: hostAudioOn)
            }
        }
    }
}

/// A-60's ladder, in the order the study fixes it.
enum BarLadder: Int, Comparable, Sendable {
    /// Every slot at 44.
    case full = 0
    /// The centre's slots narrow to 32; the entries never do.
    case compactCentre = 1
    /// Keyboard / pointer, plus a `…` that opens the rest on a 26-high row
    /// inside the bar. With three actions it saves nothing over the compact
    /// centre (POLISH-R), so `plan` skips it and keeps all three visible.
    case overflowCentre = 2
    /// The workspace collection drops the always-drawn 1–5 and shows only the
    /// ones holding a window.
    case occupiedWorkspaces = 3
    /// The one screen the ladder cannot save (Duo outer, 678). The workspace
    /// segment scrolls; the entries and the centre stay put (Study 04 §7 ②).
    case scrollingWorkspaces = 4

    static func < (lhs: BarLadder, rhs: BarLadder) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The measurements and the ladder, as one pure function so it can be asserted
/// without a window.
enum BarMetrics {
    static let slot = NativeBarMetrics.hit
    static let compactSlot: CGFloat = 32
    static let logo = NativeBarMetrics.hit
    static let connectionDot: CGFloat = 10
    /// A-60's overflow keeps the two used mid-stroke and adds a `…`.
    static let overflowActions: [QuickAction] = [.keyboard, .pointerMode]

    static func leftWidth(workspaces: Int) -> CGFloat {
        logo + connectionDot + CGFloat(workspaces) * slot
    }

    static func centreWidth(_ ladder: BarLadder, actions: Int) -> CGFloat {
        switch ladder {
        case .full: CGFloat(actions) * slot
        case .compactCentre: CGFloat(actions) * compactSlot
        default: CGFloat(min(actions, overflowActions.count + 1)) * compactSlot
        }
    }

    static func rightWidth(entries: Int) -> CGFloat { CGFloat(entries) * slot }

    /// The plan for one bar, given the long edge it has to fit in.
    struct Plan: Equatable, Sendable {
        var ladder: BarLadder
        /// Which workspaces are drawn, after the ladder has had its say.
        var workspaces: [Int]
        /// True only in the last rung: the workspace segment scrolls and the
        /// other two are pinned.
        var scrollsWorkspaces: Bool
        /// The width one centre slot is drawn at.
        var centreSlot: CGFloat
        /// The quick actions on the bar itself; the rest are behind `…`.
        var visibleActions: [QuickAction]
        var overflowActions: [QuickAction]
    }

    /// `available` is the bar's own long edge minus what the window reserves at
    /// its two ends (A-32). `workspaces` is already the collection
    /// `Workspaces.qml` would draw; `occupied` is the subset holding a window.
    static func plan(available: CGFloat, workspaces: [Int], occupied: Set<Int>,
                     entries: Int, actions: [QuickAction]) -> Plan {
        let right = rightWidth(entries: entries)
        func fits(_ ladder: BarLadder, _ rows: [Int]) -> Bool {
            leftWidth(workspaces: rows.count) + centreWidth(ladder, actions: actions.count) + right <= available
        }
        // No session: the centre is empty, and only the workspaces can give.
        guard !actions.isEmpty else {
            if leftWidth(workspaces: workspaces.count) + right <= available {
                return Plan(ladder: .full, workspaces: workspaces, scrollsWorkspaces: false,
                            centreSlot: slot, visibleActions: [], overflowActions: [])
            }
            let rows = workspaces.filter { occupied.contains($0) }
            let ladder: BarLadder = fits(.full, rows) ? .occupiedWorkspaces : .scrollingWorkspaces
            return Plan(ladder: ladder, workspaces: rows,
                        scrollsWorkspaces: ladder == .scrollingWorkspaces,
                        centreSlot: slot, visibleActions: [], overflowActions: [])
        }
        if fits(.full, workspaces) {
            return Plan(ladder: .full, workspaces: workspaces, scrollsWorkspaces: false,
                        centreSlot: slot, visibleActions: actions, overflowActions: [])
        }
        if fits(.compactCentre, workspaces) {
            return Plan(ladder: .compactCentre, workspaces: workspaces, scrollsWorkspaces: false,
                        centreSlot: compactSlot, visibleActions: actions, overflowActions: [])
        }
        // A `…` that would stand in for a single action saves no width, so it
        // is only used when it hides at least two.
        let folds = actions.count > overflowActions.filter { actions.contains($0) }.count + 1
        let kept = folds ? overflowActions.filter { actions.contains($0) } : actions
        let hidden = actions.filter { !kept.contains($0) }
        if folds, fits(.overflowCentre, workspaces) {
            return Plan(ladder: .overflowCentre, workspaces: workspaces, scrollsWorkspaces: false,
                        centreSlot: compactSlot, visibleActions: kept, overflowActions: hidden)
        }
        // The last rung the study allows before giving up: draw only the
        // workspaces that hold something. The entries and the centre never
        // shrink further — "入口段、通知永远不许收".
        let rows = workspaces.filter { occupied.contains($0) }
        if fits(.overflowCentre, rows) {
            return Plan(ladder: .occupiedWorkspaces, workspaces: rows, scrollsWorkspaces: false,
                        centreSlot: compactSlot, visibleActions: kept, overflowActions: hidden)
        }
        return Plan(ladder: .scrollingWorkspaces, workspaces: rows, scrollsWorkspaces: true,
                    centreSlot: compactSlot, visibleActions: kept, overflowActions: hidden)
    }
}
