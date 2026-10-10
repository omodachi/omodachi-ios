import SwiftUI

/// HERDR-3. One key on a terminal's keys row: 28 tall inside the 44 a finger
/// needs (A-01), boxed like `SSHModifierRow`'s keys, its face a glyph or a key
/// name — never a sentence.
///
/// A key that `repeats` behaves like a keyboard's arrow: a tap sends it once;
/// holding it sends it again after 0.4 s and then every 80 ms until the finger
/// lifts. The press is read from the button's own pressed state, so the tap
/// that ends a hold does not send one more.
struct KeyCap: View {
    let face: String
    var repeats = false
    /// HERDR-4: a phone's second keys row fits ^C ^D, the digits and the
    /// presets in its width with slightly narrower caps (still 44 tall).
    var compact = false
    /// VERIFY-1: a phone's second row shares its width between every key
    /// (^C ^D, 1–5 and the presets) instead of scrolling past the edge: the
    /// caps lose their side padding and stretch evenly from 24 points.
    var fills = false
    let action: () -> Void

    @State private var hold = KeyHold()

    var body: some View {
        Button(action: {
            // A hold already sent its keys; the release that ends it is not
            // another press.
            if !hold.consumeRepeat() { action() }
        }) {
            Text(verbatim: face)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.text)
                .lineLimit(1)
                .padding(.horizontal, fills ? OmodachiTheme.space("xs") / 2 : OmodachiTheme.space(compact ? "sm" : "md"))
                .frame(minWidth: fills ? 24 : (compact ? 32 : 36), maxWidth: fills ? .infinity : nil,
                       minHeight: OmodachiTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyCapStyle(onPress: { pressed in
            if pressed, repeats { hold.begin(action) } else { hold.end() }
        }))
        .frame(minHeight: NativeBarMetrics.hit)
    }
}

/// The repeat timer behind a held key. A reference, because a button style's
/// press callback and the button's action both have to see the same one.
@MainActor final class KeyHold {
    static let firstRepeat: Duration = .milliseconds(400)
    static let interval: Duration = .milliseconds(80)

    private var task: Task<Void, Never>?
    private var repeated = false

    func begin(_ action: @escaping () -> Void) {
        task?.cancel()
        repeated = false
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.firstRepeat)
            while !Task.isCancelled {
                self?.repeated = true
                action()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func end() {
        task?.cancel()
        task = nil
    }

    /// Whether the press that just ended already sent its key by repeating.
    func consumeRepeat() -> Bool {
        let value = repeated
        repeated = false
        return value
    }
}

/// `OmodachiControlStyle`'s bordered look, with the press reported out.
private struct KeyCapStyle: ButtonStyle {
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        OmodachiControlStyle(bordered: true, fill: OmodachiTheme.normalFill)
            .makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}

/// HERDR-3. One row of a labelled menu: a name, an SF Symbol, and an optional
/// second line. The second line is how an item that cannot act right now says
/// why — the item stays tappable and says it again, because a greyed item
/// with the reason only on hover is unreadable on a phone.
struct LabelledMenuItem: View {
    let title: String
    var detail: String?
    /// OVERVIEW-1: nil for an item with no symbol (a session's name and counts).
    let symbol: String?
    var destructive = false
    let action: () -> Void

    var body: some View {
        // A menu reads a button's label as title, subtitle and image, in
        // that order — the form that gives an item its second line.
        Button(role: destructive ? .destructive : nil, action: action) {
            Text(title)
            if let detail { Text(detail) }
            if let symbol { Image(systemName: symbol) }
        }
    }
}
