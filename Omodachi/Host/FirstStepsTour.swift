import Combine
import Foundation

/// TUTORIAL-1. One stop of the first-steps tour: what it points at on the bar.
///
/// The tour never opens a panel. Opening Agent would ensure the host's agent,
/// opening Remote would read the host's capabilities; a tour that only points
/// at the bar can be walked on a computer that is asleep, in the demo, and
/// without anything being sent anywhere.
enum TourStep: String, CaseIterable, Sendable {
    /// The whole bar: the logo, names on a hold, the other edge.
    case bar
    case remote, agent, herdr, notifications, settings

    /// The anchor the step's spotlight looks for (`View.tourAnchor`): the
    /// bar itself, or one entry's slot by its panel id.
    var anchor: String { rawValue }

    /// The bar entry this step is about, as a panel id; `nil` for the bar.
    var entry: String? { self == .bar ? nil : rawValue }

    /// The steps there is something on screen for. An entry the person has
    /// switched off in Settings has no slot to point at, so its step is left
    /// out rather than pointing at nothing. The bar and Settings are always
    /// there (Settings cannot be switched off).
    @MainActor static func available(entryEnabled: (String) -> Bool) -> [TourStep] {
        allCases.filter { step in
            guard let entry = step.entry, step != .settings else { return true }
            return entryEnabled(entry)
        }
    }
}

/// TUTORIAL-1. The first-steps tour: at most six short stops along the bar,
/// shown once after the first successful pairing and when the demo is
/// entered, skippable at every stop, and again from Settings.
///
/// Everything it remembers is on this device: "seen" is `OnceHints.tour`
/// (one registry with the per-panel hints), and "still to show" is one
/// defaults key, so a pairing that ends with the app being closed still gets
/// its tour on the next launch. Nothing about it is ever sent to a host.
@MainActor final class FirstStepsTour: ObservableObject {
    /// The stops of the tour that is up, in order; empty when none is.
    @Published private(set) var steps: [TourStep] = []
    /// Which stop is up; `nil` when the tour is not showing.
    @Published private(set) var index: Int?
    /// Armed by a first pairing or the demo, waiting for the Shell to be on
    /// its first panel. Cleared only when the tour ends.
    @Published private(set) var pending: Bool

    /// Whether a pairing or the demo arms the tour by itself. A UI-test
    /// launch turns it off unless it asks for the tour (`--tour`), so the
    /// hundred walks that enter the demo are not walking into a callout;
    /// "Show the tour again" works either way.
    var startsByItself = true

    let hints: OnceHints
    private let defaults: UserDefaults
    static let pendingKey = "omodachi.tour.pending.v1" // non-copy: defaults key

    init(hints: OnceHints, defaults: UserDefaults = .standard) {
        self.hints = hints
        self.defaults = defaults
        pending = defaults.bool(forKey: Self.pendingKey)
    }

    var step: TourStep? { index.flatMap { steps.indices.contains($0) ? steps[$0] : nil } }
    var isShowing: Bool { step != nil }
    var isLast: Bool { index.map { $0 == steps.count - 1 } ?? false }
    /// 1-based, for "2 / 6".
    var position: (number: Int, count: Int)? { index.map { ($0 + 1, steps.count) } }

    /// A first pairing landed, or the demo was entered. Arms the tour unless
    /// this device has already seen it.
    func arm() {
        guard startsByItself, hints.shows(.tour), !isShowing else { return }
        setPending(true)
    }

    /// The Shell is on its first panel with nothing over it: an armed tour
    /// starts now. Returns whether it did.
    @discardableResult
    func startIfPending(available: [TourStep]) -> Bool {
        guard pending, !isShowing else { return false }
        guard hints.shows(.tour) else { setPending(false); return false }
        return begin(available)
    }

    /// "Show the tour again": every hint comes back, and the tour starts
    /// where the person is, whatever panel that is.
    func replay(available: [TourStep]) {
        hints.reset()
        setPending(true)
        begin(available)
    }

    func next() {
        guard let index else { return }
        if index + 1 < steps.count { self.index = index + 1 } else { finish() }
    }

    /// Skip, Done, and the person stepping into a panel themselves all end
    /// the tour the same way: seen, and not coming back by itself.
    func finish() {
        let wasUp = isShowing || pending
        index = nil
        steps = []
        setPending(false)
        if wasUp { hints.dismiss(.tour) }
    }

    /// The bar went away under the tour (the demo was left, the last host
    /// forgotten): put it down without calling it seen, so it starts again
    /// from the top the next time there is a bar to walk along.
    func suspend() {
        guard isShowing else { return }
        index = nil
        steps = []
    }

    @discardableResult
    private func begin(_ available: [TourStep]) -> Bool {
        let ordered = TourStep.allCases.filter(available.contains)
        guard !ordered.isEmpty else { return false }
        steps = ordered
        index = 0
        return true
    }

    private func setPending(_ value: Bool) {
        pending = value
        if value { defaults.set(true, forKey: Self.pendingKey) } else { defaults.removeObject(forKey: Self.pendingKey) }
    }
}
