import Foundation

/// A-64 / N-37 / A-62 — the picture's own gestures, decided in one place.
///
/// Study 04 §13 hands the whole gesture vocabulary to the desktop inside the
/// stream: three fingers left / right are the neighbouring workspace, three up
/// is the scratchpad, a three-finger pinch is full screen, and one or two
/// fingers are always the pointer. Every one of them is an **alias of a row the
/// host already has** (N-37), never a second set of bindings: the host rebinds
/// the key and the gesture follows it, and a host without that row simply has
/// no such gesture.
///
/// This file is the whole of the decision. `OMRemoteRenderView` (Sunshine) and
/// `OMVNCRemoteView` (VNC) report touches into it and ask it questions; neither
/// one contains a threshold, a direction or an alias, which is how the two
/// backends are kept from drifting apart (GEST-1 §2).
enum RemotePictureGesture: Int, CaseIterable, Sendable, Hashable {
    /// A-62. The one gesture that is local: it toggles this device's soft
    /// keyboard and is never sent anywhere.
    case keyboard = 1
    case workspaceNext = 2
    case workspacePrevious = 3
    case scratchpad = 4
    case fullScreen = 5

    /// The four that resolve to something on the host. The keyboard is not one
    /// of them, so it can never be "unregistered" by a host that lacks a row.
    static let hostGestures: [RemotePictureGesture] = [.workspaceNext, .workspacePrevious, .scratchpad, .fullScreen]

    var title: String {
        switch self {
        case .keyboard: Strings.gestureThreeFingerTap
        case .workspaceNext: Strings.gestureThreeFingerLeft
        case .workspacePrevious: Strings.gestureThreeFingerRight
        case .scratchpad: Strings.gestureThreeFingerUp
        case .fullScreen: Strings.gesturePinch
        }
    }
}

// MARK: - The state machine

/// Tap / swipe / pinch / nothing, from raw finger positions.
///
/// It is a value type with no UIKit in it, so every branch below is reachable
/// from a unit test — which matters more here than usual, because three-finger
/// swipes cannot be synthesized on this runtime (REMOTE-2, UX-2 §0) and a test
/// against the real recogniser is not available at any price.
struct RemoteGestureRecognizer: Sendable, Equatable {
    struct Point: Sendable, Equatable {
        var x: Double
        var y: Double
        init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// UX-2 §2's window, reused deliberately. 130 ms is already the moment the
    /// picture decides that a single finger really is a single finger — the
    /// deferred press is released then — so it is also the moment three fingers
    /// that have not moved are three fingers that are not going anywhere.
    static let decisionWindow: Double = 0.130
    /// Centroid travel, in the view's points, before the cycle is a swipe.
    static let travelThreshold: Double = 24.0
    /// Relative change in the mean distance from the centroid before the cycle
    /// is a pinch. 0.18 is a fifth: a three-finger swipe rolls the fingers
    /// enough to move this a few percent, never a fifth.
    static let spreadThreshold: Double = 0.18
    /// A-64 after rev 5: three, and only three. Four is iPadOS's.
    static let fingerCount: Int = 3

    enum State: Sendable, Equatable {
        /// No fingers down.
        case idle
        /// Three fingers down, nothing has crossed a threshold, the decision
        /// window is still open.
        case watching
        /// The window expired with nothing crossed. A lift from here is still
        /// the keyboard — the window decides whether these fingers are *going*
        /// somewhere, it is not a limit on how long a tap may be held — and a
        /// later crossing still claims the swipe.
        case tapCandidate
        /// Claimed, fired, and done for this cycle.
        case claimed(RemotePictureGesture)
        /// This cycle can never be a picture gesture: a fourth finger, a
        /// direction A-64 does not define, or a gesture the host has no row for.
        case inert
    }

    private(set) var state: State = .idle
    /// UX-2 §2. Latches for the whole cycle the moment a second finger appears.
    private(set) var multiTouchSeen = false
    /// The verdict of the cycle that just finished, kept until the next one
    /// starts so the tap recogniser — which fires *after* UIKit cancels the
    /// touches — can still ask what this cycle was.
    private(set) var lastVerdict: RemotePictureGesture?

    private var registered: Set<RemotePictureGesture> = []
    private var anchor: Point?
    private var anchorSpread = 0.0
    private var anchoredAt = 0.0
    private var peakFingers = 0
    private var active = 0

    mutating func updateRegistered(_ gestures: Set<RemotePictureGesture>) {
        registered = gestures.subtracting([.keyboard])
    }

    /// A-62 asks this at the end of a cycle: was that really a tap?
    var keyboardTapConfirmed: Bool {
        if lastVerdict == .keyboard { return true }
        // The recogniser can fire before the last finger's report arrives.
        switch state {
        case .watching, .tapCandidate: return peakFingers == Self.fingerCount
        default: return false
        }
    }

    var singleTouchAllowed: Bool { !multiTouchSeen }

    /// One report. `points` is every finger **still down**; an empty array ends
    /// the cycle. Answers the gesture this report claimed, once.
    @discardableResult
    mutating func report(points: [Point], at time: Double) -> RemotePictureGesture? {
        guard points.count <= 16, time.isFinite else { return nil }
        if active == 0, !points.isEmpty { beginCycle() }
        active = points.count
        peakFingers = max(peakFingers, points.count)
        if points.count > 1 { multiTouchSeen = true }
        if peakFingers > Self.fingerCount { state = .inert }

        guard !points.isEmpty else { return endCycle() }
        guard points.count == Self.fingerCount, peakFingers == Self.fingerCount else { return nil }

        let centre = Self.centroid(points)
        let spread = Self.spread(points, around: centre)
        guard let anchor else {
            self.anchor = centre; anchorSpread = spread; anchoredAt = time
            return nil
        }
        switch state {
        case .watching, .tapCandidate: break
        default: return nil
        }
        let dx: Double = centre.x - anchor.x
        let dy: Double = centre.y - anchor.y
        let travel: Double = (dx * dx + dy * dy).squareRoot()
        // The ternary's `0` is a literal with no type of its own; annotating
        // the binding keeps the whole comparison in Double.
        let stretch: Double = anchorSpread > 1 ? abs(spread / anchorSpread - 1) : 0
        let swipe: Double = travel / Self.travelThreshold
        let pinch: Double = stretch / Self.spreadThreshold
        if max(swipe, pinch) >= 1 {
            return claim(pinch >= swipe ? .fullScreen : Self.gesture(dx: dx, dy: dy))
        }
        if state == .watching, time - anchoredAt >= Self.decisionWindow { state = .tapCandidate }
        return nil
    }

    /// A-64's four directions. Down is not one of them — iPadOS's own Dock and
    /// app switcher live there — so a downward three-finger swipe claims the
    /// cycle and does nothing, rather than falling through to the keyboard.
    static func gesture(dx: Double, dy: Double) -> RemotePictureGesture? {
        if abs(dx) >= abs(dy) { return dx < 0 ? .workspaceNext : .workspacePrevious }
        return dy < 0 ? .scratchpad : nil
    }

    /// Two `reduce(0)`s and a division inside one initialiser call is the same
    /// trap as `replayForOperator`'s: the `0` is untyped, so every numeric type
    /// in the expression is still a candidate while the initialiser is being
    /// resolved. Written as a loop over annotated values there is nothing left
    /// to infer.
    static func centroid(_ points: [Point]) -> Point {
        var sumX: Double = 0
        var sumY: Double = 0
        for point in points {
            sumX += point.x
            sumY += point.y
        }
        let count: Double = Double(points.count)
        return Point(x: sumX / count, y: sumY / count)
    }

    static func spread(_ points: [Point], around centre: Point) -> Double {
        var total: Double = 0
        for point in points {
            let dx: Double = point.x - centre.x
            let dy: Double = point.y - centre.y
            total += (dx * dx + dy * dy).squareRoot()
        }
        let count: Double = Double(points.count)
        return total / count
    }

    private mutating func beginCycle() {
        state = .watching
        multiTouchSeen = false
        lastVerdict = nil
        anchor = nil
        anchorSpread = 0
        anchoredAt = 0
        peakFingers = 0
    }

    /// N-37 in one line: a gesture the host has no row for is not registered,
    /// so the cycle is spent and nothing happens. It does not become a tap —
    /// the fingers moved.
    private mutating func claim(_ gesture: RemotePictureGesture?) -> RemotePictureGesture? {
        guard let gesture, registered.contains(gesture) else { state = .inert; return nil }
        state = .claimed(gesture)
        lastVerdict = gesture
        return gesture
    }

    private mutating func endCycle() -> RemotePictureGesture? {
        var delivered: RemotePictureGesture?
        switch state {
        case .watching, .tapCandidate:
            // A-62. The window decides whether three fingers are *going*
            // somewhere; it is not a limit on how long a tap may be held. A
            // 250 ms three-finger tap is the ordinary shape of the gesture and
            // it is still the keyboard.
            if peakFingers == Self.fingerCount { delivered = .keyboard; lastVerdict = .keyboard }
        case .claimed, .idle, .inert:
            break   // a claim was already delivered mid-cycle
        }
        state = .idle
        anchor = nil
        peakFingers = 0
        return delivered
    }
}

// MARK: - N-37: the alias, and what it resolves to

/// What a gesture is an alias *of*. Both shapes are the host's own; neither is
/// a command this client composed.
enum RemoteGestureRow: Equatable, Sendable {
    /// A-64 rev 5 / review #24. The neighbouring workspace is the **host's** to
    /// name: core's `POST /v1/workspaces/relative/{e+1|e-1}/select` reads the
    /// collection it has just published and wraps, and inside a session it
    /// acts on the output the session owns. A client that computed the
    /// neighbour from its own snapshot would compute it from a snapshot that
    /// may already be stale.
    case relativeWorkspace(step: RemoteWorkspaceStep)
    /// A row in the host's keybinding catalog, by its id, with the label the
    /// host published for it.
    case shortcut(id: String, actionRef: String, label: String)

    /// The row's name, which is what the toast and settings ⑥ both print.
    var label: String {
        switch self {
        case .relativeWorkspace(let step): step == .next ? Strings.gestureWorkspaceNext : Strings.gestureWorkspacePrevious
        case .shortcut(_, _, let label): label
        }
    }
}

public enum RemoteWorkspaceStep: String, Sendable, Equatable, CaseIterable {
    case next = "e+1"
    case previous = "e-1"
}

/// One gesture's answer: the row it resolves to, or why it has none.
struct RemoteGestureBinding: Equatable, Sendable {
    let gesture: RemotePictureGesture
    /// `nil` = the gesture is not registered (N-37).
    var row: RemoteGestureRow?
    /// The host's own sentence when there is one, our own when the row is
    /// simply absent. Only ever read when `row` is `nil`.
    var unavailable: String?

    /// What settings ⑥ prints on the right of the row.
    var resolution: String { row?.label ?? unavailable ?? Strings.gestureNoHostBinding }
}

/// The four bindings, as one value the picture and settings ⑥ both read.
struct RemoteGestureBindings: Equatable, Sendable {
    var bindings: [RemoteGestureBinding] = RemotePictureGesture.hostGestures.map {
        RemoteGestureBinding(gesture: $0, row: nil, unavailable: nil)
    }

    subscript(gesture: RemotePictureGesture) -> RemoteGestureBinding? {
        bindings.first { $0.gesture == gesture }
    }
    /// What the picture is told to listen for.
    var registered: Set<RemotePictureGesture> {
        Set(bindings.filter { $0.row != nil }.map(\.gesture))
    }
}

/// N-37, applied. The label the host publishes is the handle, not the key
/// combination: N-37 says a host that rebinds the key keeps the gesture, which
/// is only true if the gesture follows the row rather than the keys. A row
/// core has greyed (`enabled == false`) is treated exactly as a row that is not
/// there — SHORTCUT-1's `universal` contract makes core's `enabled` the whole
/// greying rule, and this does not add a second one.
enum RemoteGestureResolver {
    /// Omarchy's own labels for the two rows A-64 names. Compared case- and
    /// space-insensitively, because they are host text.
    static let scratchpadLabel = "toggle scratchpad"          // non-copy: the host's own row label
    static let fullScreenLabel = "full screen"                // non-copy: the host's own row label

    static func resolve(shortcuts: ShortcutSnapshot?, workspacesSelectable: Bool) -> RemoteGestureBindings {
        var value = RemoteGestureBindings()
        value.bindings = RemotePictureGesture.hostGestures.map { gesture in
            switch gesture {
            case .workspaceNext, .workspacePrevious:
                guard workspacesSelectable else {
                    return .init(gesture: gesture, row: nil, unavailable: Strings.gestureNoWorkspaces)
                }
                return .init(gesture: gesture,
                             row: .relativeWorkspace(step: gesture == .workspaceNext ? .next : .previous))
            case .scratchpad:
                return row(gesture, label: scratchpadLabel, in: shortcuts)
            case .fullScreen:
                return row(gesture, label: fullScreenLabel, in: shortcuts)
            case .keyboard:
                return .init(gesture: gesture, row: nil, unavailable: nil)
            }
        }
        return value
    }

    private static func row(_ gesture: RemotePictureGesture, label: String,
                            in shortcuts: ShortcutSnapshot?) -> RemoteGestureBinding {
        guard let shortcuts, shortcuts.available else {
            return .init(gesture: gesture, row: nil, unavailable: Strings.gestureNoHostBinding)
        }
        guard let entry = shortcuts.entries.first(where: { normalized($0.label) == label }) else {
            return .init(gesture: gesture, row: nil, unavailable: Strings.gestureNoHostBinding)
        }
        guard entry.enabled, let ref = entry.actionRef, !ref.isEmpty else {
            return .init(gesture: gesture, row: nil,
                         unavailable: entry.disabledReasonDetail ?? ShortcutPanelModel.explain(entry.disabledReason))
        }
        return .init(gesture: gesture, row: .shortcut(id: entry.id, actionRef: ref, label: entry.label))
    }

    static func normalized(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - The Objective-C seam

/// The arbiter each backend owns. It holds the state machine and answers the
/// two questions the views ask; it decides nothing of its own.
@MainActor final class RemoteGestureArbiter: NSObject, @preconcurrency OMRemoteGestureArbitrating {
    private var recognizer = RemoteGestureRecognizer()
    /// Everything the picture recognised, in order. The keyboard is not on it:
    /// the tap recogniser owns that half and only asks this one to confirm.
    var onGesture: ((RemotePictureGesture) -> Void)?

    var singleTouchAllowed: Bool { recognizer.singleTouchAllowed }
    var keyboardTapConfirmed: Bool { recognizer.keyboardTapConfirmed }
    /// Readable for the tests that pin the state machine to the two views.
    var state: RemoteGestureRecognizer.State { recognizer.state }

    func updateRegistered(gestures: [NSNumber]) {
        recognizer.updateRegistered(Set(gestures.compactMap { RemotePictureGesture(rawValue: $0.intValue) }))
    }

    func report(phase: OMRemoteTouchPhase, coordinates: [NSNumber], timestamp: Double) -> OMRemoteGesture {
        var points: [RemoteGestureRecognizer.Point] = []
        points.reserveCapacity(coordinates.count / 2)
        var index = 0
        while index + 1 < coordinates.count {
            points.append(.init(x: coordinates[index].doubleValue, y: coordinates[index + 1].doubleValue))
            index += 2
        }
        guard let gesture = recognizer.report(points: points, at: timestamp) else { return .none }
        if gesture != .keyboard { onGesture?(gesture) }
        return OMRemoteGesture(rawValue: gesture.rawValue) ?? .none
    }

    /// Operator-only replay: the three touch reports UIKit would have
    /// delivered for that gesture, fed in at this seam. Everything downstream
    /// — the state machine, N-37's registration check, the alias, the host
    /// request, the 26-high row — is the product path, unchanged.
    ///
    /// Everything below is spelled out with a type on it. The first version of
    /// this was one `flatMap` over an array of tuples that built `NSNumber`s
    /// out of untyped literals — three overload sets (`+`, `*`, and
    /// `NSNumber.init(value:)`, which takes eleven different things) folded
    /// into one expression. The simulator build swallowed it; the device build
    /// answered "unable to type-check this expression in reasonable time".
    func replayForOperator(_ gesture: RemotePictureGesture, at time: Double) {
        let centreX: Double = 400
        let centreY: Double = 300
        let spacing: [Double] = [-60, 0, 60]

        func points(dx: Double, dy: Double, spread: Double) -> [NSNumber] {
            var coordinates: [NSNumber] = []
            coordinates.reserveCapacity(spacing.count * 2)
            for offset in spacing {
                let x: Double = centreX + offset * spread + dx
                let y: Double = centreY + dy
                coordinates.append(NSNumber(value: x))
                coordinates.append(NSNumber(value: y))
            }
            return coordinates
        }

        let dx: Double
        let dy: Double
        let spread: Double
        switch gesture {
        case .workspaceNext: dx = -80; dy = 0; spread = 1
        case .workspacePrevious: dx = 80; dy = 0; spread = 1
        case .scratchpad: dx = 0; dy = -80; spread = 1
        case .fullScreen: dx = 0; dy = 0; spread = 1.6
        case .keyboard: dx = 0; dy = 0; spread = 1
        }
        let start: [NSNumber] = points(dx: 0, dy: 0, spread: 1)
        let moved: [NSNumber] = points(dx: dx, dy: dy, spread: spread)
        _ = report(phase: .began, coordinates: start, timestamp: time)
        _ = report(phase: .moved, coordinates: moved, timestamp: time + 0.05)
        _ = report(phase: .ended, coordinates: [], timestamp: time + 0.1)
    }
}
