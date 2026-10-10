import Combine
import Foundation

/// HERDR-4 §3.4. The one-time "what you can do here" hints (RESEARCH-2 §3
/// #48): shown until the person dismisses them, then never again on this
/// device. Remembered in this device's defaults only — a hint read on the
/// iPad is still news on the iPhone.
///
/// TUTORIAL-1: the one registry for everything the app explains once. The
/// first-steps tour is one more entry here (`.tour`, "seen"), so "Show the
/// tour again" in Settings is one `reset()` that brings the tour and the
/// per-panel hints back together, and nothing else keeps a flag of its own.
@MainActor final class OnceHints: ObservableObject {
    enum Hint: String, CaseIterable, Sendable {
        /// Herdr: type here, or use the keys; Type sends every key; Take
        /// keyboard is for full-screen apps.
        case herdr
        // AGENT-PLAN-1: the Agent hint ("tap / for commands") went with the
        // slash list it pointed at; its old defaults key is simply not read.
        /// TUTORIAL-1: the first-steps tour along the bar has been seen
        /// (finished, skipped or stepped out of).
        case tour

        var defaultsKey: String { "omodachi.hint." + rawValue + ".v1" } // non-copy: defaults key
    }

    @Published private(set) var dismissed: Set<Hint>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissed = Set(Hint.allCases.filter { defaults.bool(forKey: $0.defaultsKey) })
    }

    func shows(_ hint: Hint) -> Bool { !dismissed.contains(hint) }

    func dismiss(_ hint: Hint) {
        defaults.set(true, forKey: hint.defaultsKey)
        dismissed.insert(hint)
    }

    /// TUTORIAL-1: every hint comes back, the tour included.
    func reset() {
        for hint in Hint.allCases { defaults.removeObject(forKey: hint.defaultsKey) }
        dismissed = []
    }
}
