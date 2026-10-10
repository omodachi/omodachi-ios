import SwiftUI

extension View {
    /// A-01, for text fields.
    ///
    /// A `TextField` is only as tall as its own line of text — measured 20
    /// points in the Agent composer and 22 in the Panel's search — while the
    /// box drawn around it is the app's 44. Everything between the two is
    /// padding, and padding is not part of the control: a tap that lands there
    /// falls through to the stack behind it, nothing becomes first responder,
    /// and no keyboard comes up.
    ///
    /// That is what Leo hit — "为什么…还需要三指唤出键盘而不是直接点击唤出". The
    /// tap was never eaten by a gesture recogniser; it was landing outside a
    /// target less than half the height of the thing you can see, so more than
    /// half of every attempt did nothing.
    ///
    /// Applied to the view that carries the border, this makes the drawn box
    /// the target. The field inside keeps priority, so a tap on the text itself
    /// still places the caret where it was tapped.
    func textEntryHitArea(_ focused: FocusState<Bool>.Binding, enabled: Bool = true) -> some View {
        contentShape(Rectangle())
            .onTapGesture { if enabled && !focused.wrappedValue { focused.wrappedValue = true } }
    }

    /// AGENT-UI-1: the box a message is written in is a surface, not an
    /// outline. Leo — "agent输入框是透明的 滚动的时候好脏": the composers drew
    /// only a 1px `[controls] normal-border` at 0.4 alpha on the panel's own
    /// background, so the box was the conversation's colour with a faint frame
    /// in it, and the lines scrolling up to it read as running on into it.
    ///
    /// The fill is the host's control state (A-08): `normal-fill` idle — the
    /// hint banner's band — and `focus-fill` while typing, the tokens a Tap is
    /// drawn with, laid on the theme background with its alpha ignored. So the
    /// box hides whatever is under it even when a theme makes its surfaces
    /// translucent or the box sits on a moving picture (Remote's bar).
    func textEntrySurface(focused: Bool) -> some View {
        background(focused ? OmodachiTheme.focusFill : OmodachiTheme.normalFill)
            .background(OmodachiTheme.solidBackground)
    }
}
