import SwiftUI

/// The one tappable thing in the app.
///
/// ARCH-1 §1: `Button` exists in exactly one layer. Every surface and the Shell
/// reach for this instead, so the four states `OmodachiControlStyle` draws
/// (`Button.qml 5–13, 112–126`: pressed → focus → selected → idle) cannot be
/// half-applied by a caller that forgot `.buttonStyle`, and A-65's rule that a
/// dimmed control is also a disabled one is enforced in one place rather than
/// remembered in ninety.
///
/// It is deliberately thin. It adds no padding, no frame and no shape: the hit
/// area (A-01) belongs to the label, because only the label knows whether it is
/// a 44 bar slot, a 50 menu row or a 58 detail row.
struct Tap<Label: View>: View {
    /// A-51's third state: this control's destination is what is on screen.
    var selected = false
    /// `[controls] normal-border`, for the controls the study draws boxed.
    var bordered = false
    /// The idle fill. Pressed, focused and selected are the style's business.
    var fill: Color = .clear
    /// A-65: a dimmed control must also be disabled, or VoiceOver reads it as
    /// available. One flag does both so they cannot disagree.
    var enabled = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(OmodachiControlStyle(selected: selected, bordered: bordered, fill: fill))
            .disabled(!enabled)
    }
}

/// A tap whose label is one line of the host's own type.
///
/// It is separate from `Tap` rather than an overload because a text control has
/// a decision `Tap` does not: which step it is drawn at, and whether it carries
/// the app's minimum touch height on its own.
struct TextTap: View {
    let title: String
    var step = "body-small"
    var role: ThemeColorRole?
    var selected = false
    var bordered = false
    var enabled = true
    /// A-01: 44 unless the caller is placing this inside something that already
    /// guarantees it.
    var minimumHeight: CGFloat = NativeBarMetrics.hit
    let action: () -> Void

    init(_ title: String, step: String = "body-small", role: ThemeColorRole? = nil,
         selected: Bool = false, bordered: Bool = false, enabled: Bool = true,
         minimumHeight: CGFloat = NativeBarMetrics.hit, action: @escaping () -> Void) {
        self.title = title
        self.step = step
        self.role = role
        self.selected = selected
        self.bordered = bordered
        self.enabled = enabled
        self.minimumHeight = minimumHeight
        self.action = action
    }

    var body: some View {
        Tap(selected: selected, bordered: bordered, enabled: enabled, action: action) {
            Text(title)
                .font(OmodachiTheme.font(step))
                .foregroundStyle(role.map { OmodachiTheme.current.color($0) } ?? OmodachiTheme.text)
                .lineLimit(1)
                .padding(.horizontal, OmodachiTheme.space("control-padding-x"))
                .frame(minHeight: minimumHeight)
                .contentShape(Rectangle())
        }
    }
}

extension Tap {
    /// The four-state style, applied to a control that was built first.
    ///
    /// It exists because the style used to be a `.buttonStyle` written after the
    /// `Button`, and keeping that reading order makes each call site say the
    /// same thing it said before: here is the control, and here is how it draws.
    /// It returns a `Tap` rather than `some View`, so the accessibility
    /// modifiers that follow still apply to the control itself.
    func control(selected: Bool = false, bordered: Bool = false, fill: Color = .clear) -> Tap {
        var copy = self
        copy.selected = selected
        copy.bordered = bordered
        copy.fill = fill
        return copy
    }
}

extension TextTap {
    /// A menu item: an icon and a name. The icon is the SF Symbol a context
    /// menu wants, and it stays a symbol — a context menu is UIKit's, drawn by
    /// the system, and the host's glyphs have no place in it.
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.init(title, action: action)
    }

    /// A bordered text control, for the places the study draws a boxed button.
    init(_ title: String, bordered: Bool, action: @escaping () -> Void) {
        self.init(title, bordered: bordered, enabled: true, action: action)
    }

    /// A destructive item, in the theme's own red rather than the system's.
    init(_ title: String, destructive: Bool, action: @escaping () -> Void) {
        self.init(title, role: destructive ? .red : nil, action: action)
    }
}
