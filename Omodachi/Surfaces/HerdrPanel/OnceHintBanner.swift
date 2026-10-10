import SwiftUI

/// HERDR-4 §3.4. A one-time hint, until it is dismissed on this device
/// (`OnceHints`). Herdr and Agent each have one.
struct OnceHintBanner: View {
    @ObservedObject var hints: OnceHints
    let hint: OnceHints.Hint
    let text: String
    /// HERDR-8: shown on one visit only — it is marked seen the moment it
    /// appears and stays up until this visit ends (or "Got it"). The phone's
    /// Herdr hint, where every row counts.
    var once = false
    @State private var thisVisit = false

    var body: some View {
        if thisVisit || hints.shows(hint) {
            HintCard(text: text, dismissTitle: Strings.hintDismiss) {
                thisVisit = false
                hints.dismiss(hint)
            }
            .accessibilityIdentifier("hint-\(hint.rawValue)")
            .onAppear {
                guard once, hints.shows(hint) else { return }
                thisVisit = true
                hints.dismiss(hint)
            }
        }
    }
}
