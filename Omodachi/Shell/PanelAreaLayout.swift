import SwiftUI

/// A-32. The glass has rounded corners, a camera island and a home indicator,
/// and none of them are places a control may live.
///
/// The rule is one sentence: **backgrounds go edge to edge, interactive content
/// does not.** The bar's own background still reaches the physical edge — it is
/// the shell surface and a gap there would read as a bug — but the stack of
/// buttons inside it starts after the window's safe-area inset on its own axis.
/// The panel area does the same, minus the edge the bar already occupies.
///
/// Both answers are computed here, from the window's own insets, so the bar and
/// every panel get the same answer instead of each one padding itself.
enum SafeAreaLayoutPolicy {
    /// What the bar's item stack has to clear.
    ///
    /// A bar runs the full length of its edge, so what can reach its items is
    /// whatever the window reserves at the two ends of that axis — the island
    /// and the corner radius in portrait, the indicator at the bottom. Its own
    /// edge is included for completeness; on a long-edge bar (A-02) that value
    /// is zero, because the bar is only ever on an edge the window does not
    /// reserve depth on.
    static func barContent(edge: HostBarPosition, window: EdgeInsets) -> EdgeInsets {
        switch edge {
        case .left:  EdgeInsets(top: window.top, leading: window.leading, bottom: window.bottom, trailing: 0)
        case .right: EdgeInsets(top: window.top, leading: 0, bottom: window.bottom, trailing: window.trailing)
        case .top:   EdgeInsets(top: window.top, leading: window.leading, bottom: 0, trailing: window.trailing)
        case .bottom: EdgeInsets(top: 0, leading: window.leading, bottom: window.bottom, trailing: window.trailing)
        }
    }

    /// What the panel area has to clear: three sides of the window's own insets.
    /// The fourth is the edge the bar is on, and the content does not start
    /// there — the bar does.
    static func stage(edge: HostBarPosition, window: EdgeInsets) -> EdgeInsets {
        switch edge {
        case .left:  EdgeInsets(top: window.top, leading: 0, bottom: window.bottom, trailing: window.trailing)
        case .right: EdgeInsets(top: window.top, leading: window.leading, bottom: window.bottom, trailing: 0)
        case .top:   EdgeInsets(top: 0, leading: window.leading, bottom: window.bottom, trailing: window.trailing)
        case .bottom: EdgeInsets(top: window.top, leading: window.leading, bottom: 0, trailing: window.trailing)
        }
    }

    /// A surface with no bar of its own clears all four. The Remote picture is
    /// not one of these: it is edge to edge on purpose (A-58).
    static func stage(window: EdgeInsets) -> EdgeInsets { window }

    /// The bar's own long edge, minus what the window reserves at its two ends.
    /// This is the number A-60's ladder is measured against.
    static func barExtent(edge: HostBarPosition, window: EdgeInsets, size: CGSize) -> CGFloat {
        NativeBarMetrics.isVertical(edge)
            ? max(0, size.height - window.top - window.bottom)
            : max(0, size.width - window.leading - window.trailing)
    }

    /// What is left for the panel area once the bar has its edge.
    static func panelAreaWidth(edge: HostBarPosition, size: CGSize) -> CGFloat {
        NativeBarMetrics.isVertical(edge)
            ? max(0, size.width - NativeBarMetrics.thickness)
            : size.width
    }
}
