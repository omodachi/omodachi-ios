import UIKit
import SwiftTerm

/// SwiftTerm owns UITextInput/IME, Ctrl/Option/arrow events and text selection.
/// Only app-specific shortcuts are added, on the actual terminal first responder.
///
/// SPEC-F3 §1 took the Herdr prefix keys out of here. Herdr is reached through
/// core's bridge now, and its controls are routes; injecting `Ctrl+B v` into an
/// SSH shell was a guess at the user's Herdr config and is gone.
final class NativeTerminalView: TerminalView {
    var onHome: (() -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(title: Strings.panelMenu, action: #selector(home), input: "h", modifierFlags: [.command, .shift])
        ]
    }
    @objc private func home() { onHome?() }
}
