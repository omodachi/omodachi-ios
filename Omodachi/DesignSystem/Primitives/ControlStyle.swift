import SwiftUI

extension View {
    func omodachiCard() -> some View {
        self.padding(OmodachiTheme.space("popup-padding"))
            .background(OmodachiTheme.elevated)
            .overlay(Rectangle().strokeBorder(OmodachiTheme.popupBorder, lineWidth: OmodachiTheme.popupBorderWidth))
    }
}

/// The source's four distinct states: pressed → focus → selected → idle
/// (`Button.qml 5–13, 112–126`). Touch has no hover, so that slot is empty and
/// the overlays reserve their geometry, which keeps a press from moving a label.
struct OmodachiControlStyle: ButtonStyle {
    var selected = false
    var bordered = false
    var fill: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        ControlBody(configuration: configuration, selected: selected, bordered: bordered, fill: fill)
    }

    private struct ControlBody: View {
        let configuration: Configuration
        let selected: Bool
        let bordered: Bool
        let fill: Color
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var currentFill: Color {
            guard enabled else { return fill }
            if configuration.isPressed { return OmodachiTheme.pressedFill }
            if focused { return OmodachiTheme.focusFill }
            if selected { return OmodachiTheme.selectedFill }
            return fill
        }

        private var currentBorder: Color {
            guard enabled else { return bordered ? OmodachiTheme.controlBorder : .clear }
            if focused { return OmodachiTheme.focusBorder }
            return bordered ? OmodachiTheme.controlBorder : .clear
        }

        var body: some View {
            configuration.label
                .background(currentFill)
                .overlay(Rectangle().strokeBorder(currentBorder, lineWidth: OmodachiTheme.controlBorderWidth)
                    .allowsHitTesting(false))
                .contentShape(Rectangle())
                // `WidgetButton.qml 67`: unavailable is expressed with opacity
                // and nothing else.
                .opacity(enabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focused)
        }
    }
}
