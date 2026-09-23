import CoreGraphics
import SwiftUI
import UIKit

/// A-48. **The theme supplies colour; the App supplies size.**
///
/// UX-1 item 5: Leo's first read on a real iPad was "可读性有点差". The reason is
/// arithmetic, not taste. Omarchy's `[font]` steps are written for a 1080p
/// desktop shell viewed at desk distance — `body` 12, `body-small` 11,
/// `caption` 10 — and the client passed them through unchanged
/// (`ThemeRuntime.font(_:)`), so an iPad held at reading distance drew 10pt
/// secondary text. Nothing in the theme is wrong; the client was simply using a
/// desktop number as a tablet number.
///
/// So the host's step stays the *source*, and this is the floor applied on top
/// of it. A-48's numbers: body ≥ 15, secondary ≥ 13, monospace ≥ 13. The lift
/// is `+2` before the floor so the host's own hierarchy survives — a theme that
/// sets `heading` 16 and `title` 14 still draws the heading larger — and the
/// floor is what guarantees the minimum whatever the host chose.
///
/// It is deliberately **not** Dynamic Type. Dynamic Type is a third scale on
/// top of the host's and this one, and `ui-study-02.md` open question 5 already
/// decided the client does not stack three.
enum OmodachiTypeScale {

    /// A-48 binds to the iPad, not to the resolved size class: a Slide Over
    /// column on an iPad is compact-width and still held at tablet distance,
    /// and an iPhone in landscape is regular-width and is not an iPad.
    ///
    /// Written once at first use from the device idiom. A test sets it
    /// explicitly, which is the only reason it is a `var`.
    nonisolated(unsafe) static var isTablet: Bool = {
        MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad }
    }()

    /// A-48's secondary floor. Every step lands at or above it.
    static let secondaryFloor: CGFloat = 13
    /// A-48's body floor, applied to the steps the study uses for body text and
    /// anything larger.
    static let bodyFloor: CGFloat = 15
    /// The steps A-48 calls 次要 — everything else is body or larger.
    static let secondarySteps: Set<String> = ["caption", "body-small", "icon-small"]

    /// The point size to actually draw, for a host step whose name is known.
    static func size(step: String, hostValue: CGFloat) -> CGFloat {
        guard isTablet else { return hostValue }
        let floor = secondarySteps.contains(step) ? secondaryFloor : bodyFloor
        return max(hostValue + 2, floor)
    }

    /// The point size for a call site that asks in points rather than by step
    /// name. It cannot know whether 11 means `body-small` or a one-off label, so
    /// it takes the secondary floor: a caller that wanted body already passed a
    /// larger number and keeps the `+2`.
    static func size(points: CGFloat) -> CGFloat {
        guard isTablet else { return points }
        return max(points + 2, secondaryFloor)
    }

    /// A-48's third number. SwiftUI draws a custom face at its own natural line
    /// height, which for the monospace faces Omarchy ships is about 1.2× the
    /// point size; `lineSpacing` is the only public lever that adds to it.
    ///
    /// It is applied once, at the root, because `lineSpacing` is inherited by
    /// every descendant `Text` — so one modifier covers every surface instead
    /// of each view remembering to.
    static var lineSpacing: CGFloat { isTablet ? 2.5 : 0 }

    /// What the line height actually comes out at, for the test that has to
    /// assert ≥ 1.3. `1.2` is the natural multiple the assertion is written
    /// against; the real face is measured in `PanelAppearanceTests`.
    static func lineHeightMultiple(pointSize: CGFloat, naturalMultiple: CGFloat = 1.2) -> CGFloat {
        guard pointSize > 0 else { return 0 }
        return (pointSize * naturalMultiple + lineSpacing) / pointSize
    }
}
