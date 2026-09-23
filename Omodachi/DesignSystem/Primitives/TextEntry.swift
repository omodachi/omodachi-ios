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
}
