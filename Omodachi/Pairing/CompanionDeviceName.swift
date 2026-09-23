import Foundation
import UIKit

/// The name this device sends with a pairing request, and therefore the name
/// that ends up beside its row in `omodachi-host devices list`.
///
/// It used to be the literal string `"Leo 的 iPhone"`, compiled in. That made
/// every install — Leo's phone, Leo's iPad, and every throwaway acceptance
/// simulator — arrive at the host under the same two names, so the device list
/// could not be used to tell them apart (PAIR-4 §5). It is now the device's own
/// name, shaped to what `PairingClient.begin` will actually send.
///
/// Those bounds are the host contract, not a style choice: `begin` refuses a
/// name that is empty after trimming, that is not 1…80 unicode scalars, or
/// that contains a control character. Anything this returns is accepted.
///
/// One caveat worth knowing before reading the host's device list: since
/// iOS 16, `UIDevice.current.name` returns the *model* name ("iPhone", "iPad")
/// unless the app carries the user-assigned-device-name entitlement. A
/// Simulator still reports its own simulator name, so this does separate a
/// simulator from a real device — but two real iPhones without that
/// entitlement still look alike, and only `device_id` tells them apart.
enum CompanionDeviceName {
    /// What this install calls itself. `UIDevice` has to be read on the main
    /// actor, which is where the connection screen builds its model.
    @MainActor static func current() -> String {
        resolve(raw: UIDevice.current.name, fallback: idiom())
    }

    @MainActor static func idiom() -> String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    /// Trim, drop control characters, cap at 80 scalars, and never return
    /// something the host would refuse. `fallback` is used whenever the raw
    /// name has nothing left in it; a fallback that is itself unusable still
    /// leaves a name rather than an empty field.
    static func resolve(raw: String, fallback: String) -> String {
        if let value = shape(raw) { return value }
        if let value = shape(fallback) { return value }
        return "iPhone"
    }

    private static func shape(_ value: String) -> String? {
        // Control characters are removed rather than being a reason to reject
        // the whole name: a stray tab in a device name is not worth losing it.
        let stripped = String(String.UnicodeScalarView(
            value.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }))
        var trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        // Truncating by `Character` rather than by scalar: cutting inside a
        // grapheme cluster would turn "🇯🇵" into half a flag, and an emoji
        // costs several scalars against the host's 80.
        while trimmed.unicodeScalars.count > 80 { trimmed.removeLast() }
        // Dropping characters can expose trailing space that was inside the
        // cut, so the trim happens again rather than only before it.
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
