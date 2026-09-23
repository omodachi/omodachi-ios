import CoreGraphics
import Foundation

/// MENU-2 / A-67. Where the host bar's Omarchy logo is on the picture.
///
/// It answers one question — *which rectangle of this view is the Omarchy
/// logo* — and `RemoteBarMarks` draws our mark there. Nothing here touches
/// input: the mark is an ordinary view above the stream, so UIKit gives it its
/// tap and gives the picture everything else.
///
/// **Only the logo.** The Omodachi plugin's own bar slot is one widget among a
/// dozen third-party ones and moves whenever any of them changes, so the host
/// does not locate it and this app does not cover it. A tap there passes
/// through to the host's own icon in both modes, and that icon decides for
/// itself what a takeover means (it opens nothing and says so — the same answer
/// a local mouse click gets).
///
/// The mapping is deliberately free of stream pixels. Core reports the bar in
/// the owned output's logical pixels together with that output's logical size;
/// the picture is that whole output drawn into `videoRect`. So the rectangle is
/// a *fraction* of the output, and the fraction is what survives every resize,
/// every scale change and every encoder resolution the host may pick — the
/// stream's pixel count cancels out of both sides.
struct RemoteBarHitTest: Equatable, Sendable {
    /// What the mark stands on. There is one, and the type exists so the call
    /// sites read as what they are rather than as a bare boolean.
    enum Target: Int, Equatable, Sendable, CaseIterable {
        case logo = 1

        /// The panel it recalls — A-59 rev 5's alias, asked for now by a mark
        /// on the picture rather than by a keyboard.
        var source: String { "host_bar_logo" }
        var view: PanelSummon.View { .overview }
    }

    let geometry: HostBarGeometry

    /// The mark's rectangle as a fraction of the host's own output: x and y in
    /// 0…1, which is the space the picture hands this type.
    func fractions(for target: Target) -> CGRect? {
        let rectangle: CGRect? = switch target { case .logo: geometry.logo }
        guard let source = rectangle, geometry.logicalSize.width > 0,
              geometry.logicalSize.height > 0, source.width > 0, source.height > 0 else { return nil }
        let rect = CGRect(x: source.minX / geometry.logicalSize.width,
                          y: source.minY / geometry.logicalSize.height,
                          width: source.width / geometry.logicalSize.width,
                          height: source.height / geometry.logicalSize.height)
        guard rect.isFinite else { return nil }
        return rect
    }

    /// The same rectangle in view points. `videoRect` is the picture inside the
    /// view — the rectangle `OMRemoteClient` hands the input adapter,
    /// letterboxing already removed.
    func rect(for target: Target, videoRect: CGRect) -> CGRect? {
        guard let fraction = fractions(for: target), videoRect.width > 0, videoRect.height > 0 else { return nil }
        let mapped = CGRect(x: videoRect.minX + fraction.minX * videoRect.width,
                            y: videoRect.minY + fraction.minY * videoRect.height,
                            width: fraction.width * videoRect.width,
                            height: fraction.height * videoRect.height)
        guard mapped.isFinite, mapped.width >= 1, mapped.height >= 1 else { return nil }
        return mapped
    }

    /// What is at this fraction of the picture. `nil` is the ordinary case:
    /// the touch is the host's and goes to the host untouched.
    func target(atFraction point: CGPoint) -> Target? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        for candidate in Target.allCases where fractions(for: candidate)?.contains(point) == true {
            return candidate
        }
        return nil
    }

    /// Convenience for a caller that has view points in hand — the tests, and
    /// anything that wants to know what is under a point without asking UIKit.
    func target(at point: CGPoint, videoRect: CGRect) -> Target? {
        guard videoRect.width > 0, videoRect.height > 0, videoRect.contains(point) else { return nil }
        return target(atFraction: CGPoint(x: (point.x - videoRect.minX) / videoRect.width,
                                          y: (point.y - videoRect.minY) / videoRect.height))
    }

    /// Where the decoded stream is drawn inside a view of this size.
    ///
    /// Both backends lay the picture out aspect-fit and centred
    /// (`VideoDecoderRenderer.layoutVideo`, `OMVNCRemoteView.videoRect`), and
    /// this is the one place that fact is written in Swift — so the mark and
    /// the picture under it cannot end up computing it differently.
    static func aspectFit(_ pixels: CGSize, in bounds: CGSize) -> CGRect {
        guard pixels.width > 0, pixels.height > 0, bounds.width > 0, bounds.height > 0,
              pixels.width.isFinite, pixels.height.isFinite else { return .zero }
        let scale = min(bounds.width / pixels.width, bounds.height / pixels.height)
        guard scale > 0, scale.isFinite else { return .zero }
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

private extension CGRect {
    var isFinite: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
    }
}
