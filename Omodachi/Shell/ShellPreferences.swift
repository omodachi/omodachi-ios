import Foundation

/// CLIP-1. What this device is willing to do with the host's clipboard.
///
/// It mirrors core's `clipboard_sync` because the two switches are the same
/// question asked of both ends, and the narrower of the two wins: a device set
/// to `both` against a host set to `hostToDevice` still only reads.
enum ClipboardSyncChoice: String, Codable, CaseIterable, Sendable {
    case off, hostToDevice, both

    /// Whether this device may put the host's clipboard on its own pasteboard.
    var reads: Bool { self != .off }
    /// Whether this device may push its own pasteboard to the host.
    var writes: Bool { self == .both }
}

/// The preferences panel ⑥ writes and the Shell reads.
///
/// They are this device's, not the host's: which edge the bar takes, how a
/// badge is drawn, whether the host's sound is played here. The host's own
/// preferences stay on the host — ⑥ shows them and says where they live
/// (N-27), because a switch this device cannot move is a lie.
struct ShellPreferences: Codable, Equatable, Sendable {
    /// Study 04 §7 open question 1. The host's `notification-center` widget
    /// defaults to `Dot`, so this does too, and rev 5 spreads the choice across
    /// every entry that can carry a badge (③ pending, ⑤ dropped, ⑦ unread).
    var badgeStyle: BarBadgeStyle = .dot
    /// A-60's `host_audio_playback`: whether the stream's audio is played on
    /// this device at all. The quick action is dimmed when it is off, and says
    /// so when pressed.
    var hostAudioPlayback = true
    /// A-02: which long edge the bar takes, per orientation.
    var barEdges = NativeBarEdgePreferences()
    /// MENU-2 / A-67. The picture answers the host bar's logo and this app's
    /// icon itself, so a hidden bar leaves no way back to a panel from inside
    /// the picture except the hardware aliases. This draws one 26 pt handle in
    /// the corner when — and only when — there is nothing on the bar to hit.
    /// Off by default: a handle over somebody's desktop is furniture, and most
    /// people never hide the bar.
    var cornerHandleWhenBarHidden = false
    /// CLIP-1 §1. Whether the Keybindings list shows the rows the host says
    /// cannot run from here. Off: five permanently dead rows are not worth the
    /// five lines they take. On: they are back, greyed, with the host's reason.
    var showsUnrunnableKeybindings = false
    /// CLIP-1 §2, this device's half of the clipboard switch. The host has its
    /// own; both have to be on. Off is the shipped value on both sides.
    var clipboardSync = ClipboardSyncChoice.off

    private static let key = "omodachi.shell.preferences.v1"

    static func load(defaults: UserDefaults = .standard) -> ShellPreferences {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(ShellPreferences.self, from: data) else {
            return ShellPreferences()
        }
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
