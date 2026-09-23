import SwiftUI

/// The v6 Omodachi mark, path for path from
/// `omodachi-brand/concepts/v6-omodachi-symbol.svg` — the same outline the
/// study's artboards inline, on a 96×96 canvas with the glyph translated by 4.
/// It fills with the current foreground, never with a colour of its own, and
/// never appears next to the wordmark.
struct OmodachiSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 96
        let origin = CGPoint(x: rect.midX - 48 * scale, y: rect.midY - 48 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + (x + 4) * scale, y: origin.y + (y + 4) * scale)
        }
        func polygon(_ path: inout Path, _ steps: [(CGFloat, CGFloat)]) {
            guard let first = steps.first else { return }
            path.move(to: point(first.0, first.1))
            for step in steps.dropFirst() { path.addLine(to: point(step.0, step.1)) }
            path.closeSubpath()
        }
        var path = Path()
        // Outer ring: "M0 20H4V12H8V8H12V4H20V0H68V4H76V8H80V12H84V20H88V68H84V76
        // H80V80H76V84H68V88H20V84H12V80H8V76H4V68H0Z" — every step is an axis
        // move, which is what `shape-rendering="crispEdges"` is for.
        polygon(&path, [(0, 20), (4, 20), (4, 12), (8, 12), (8, 8), (12, 8), (12, 4), (20, 4),
                        (20, 0), (68, 0), (68, 4), (76, 4), (76, 8), (80, 8), (80, 12), (84, 12),
                        (84, 20), (88, 20), (88, 68), (84, 68), (84, 76), (80, 76), (80, 80),
                        (76, 80), (76, 84), (68, 84), (68, 88), (20, 88), (20, 84), (12, 84),
                        (12, 80), (8, 80), (8, 76), (4, 76), (4, 68), (0, 68)])
        // The counter, subtracted by the even-odd rule the source declares:
        // "M24 32V56H28V60H32V64H56V60H60V56H64V32H60V28H56V24H32V28H28V32Z".
        polygon(&path, [(24, 32), (24, 56), (28, 56), (28, 60), (32, 60), (32, 64), (56, 64),
                        (56, 60), (60, 60), (60, 56), (64, 56), (64, 32), (60, 32), (60, 28),
                        (56, 28), (56, 24), (32, 24), (32, 28), (28, 28), (28, 32)])
        // The two eyes sit inside the counter, so even-odd puts them back.
        polygon(&path, [(32, 36), (40, 36), (40, 48), (32, 48)])
        polygon(&path, [(48, 36), (56, 36), (56, 48), (48, 48)])
        return path
    }
}

extension OmodachiSymbol {
    /// The mark at a bar glyph size, in whatever colour the caller sets.
    static func view(size: CGFloat) -> some View {
        OmodachiSymbol().fill(style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
    }
}
