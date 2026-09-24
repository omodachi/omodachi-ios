import CoreGraphics
import Foundation

/// REMOTE-SAFE-1. How far the display's rounded corners reach into the ends of
/// the host's bar on the Extend picture.
///
/// In Extend mode the host's output is this device's exact shape and the
/// picture is edge to edge (A-58), so the host bar runs the full length of an
/// edge and its end items sit under the corners — on a real iPhone
/// `omarchy.power` was 7 logical px from the bottom edge and visibly cut. The
/// App knows its corners; the host knows its bar. So the App reports, with the
/// viewport it already reports, how many of its own points each end of a bar of
/// the host's thickness loses to the corners, and the host's plugin moves that
/// bar's end sections inward on that output only.
///
/// Where the numbers come from. No private API: `UIScreen._displayCornerRadius`
/// is exactly what App Review asks about, so it is never read. The radius per
/// model is the `DeviceCornerRadius` Xcode 27's own device profiles ship
/// (`/Library/Developer/CoreSimulator/Profiles/DeviceTypes/*/capabilities.plist`,
/// keyed by `representedModelIdentifiers`), and the *shape* is not a circle:
/// Apple's display corner is the continuous ("squircle") curve, which starts
/// ~1.3 R along the edge and stays further out than a circle near it. `profile`
/// is that curve, measured off the same profiles' `framebufferMask` PDFs and
/// normalised by R (REMOTE-SAFE-1 report §1 has the measurement).
struct DisplayCorners: Equatable, Sendable {
    /// Radius of each corner of *this window*, in points; zero where the
    /// window's corner is not one of the display's (Split View, Stage Manager,
    /// a home-button device).
    var topLeft: CGFloat = 0
    var topRight: CGFloat = 0
    var bottomLeft: CGFloat = 0
    var bottomRight: CGFloat = 0

    static let square = DisplayCorners()

    /// The fraction of the host bar's thickness, from the display edge inward,
    /// at which the corner is measured. Omarchy's bar glyph is the middle half
    /// of the bar (research §3: x = 6.5…19.5 of a 26 px bar, i.e. from 0.25);
    /// 0.2 leaves room for a text widget that is a little wider than a glyph.
    static let contentDepth: CGFloat = 0.2
    /// Omarchy 4's vertical bar thickness (`Style.bar.sizeVertical`, measured
    /// 26 on the host) - used until the host has told us its real bar.
    static let defaultBarThickness: CGFloat = 26

    // MARK: - The per-model radius

    /// One built-in display: its corner radius in points and its native
    /// pixels (portrait), which is how a window on an *external* display is
    /// told apart — that screen has square corners whatever the model.
    struct Display: Equatable, Sendable {
        let radius: CGFloat
        let native: CGSize
        init(_ radius: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            self.radius = radius
            native = CGSize(width: width, height: height)
        }
    }

    /// Face-ID-class devices only; every home-button model is square and is
    /// simply absent (the fallback then finds no home indicator). Generated
    /// from Xcode 27's device profiles — `DeviceCornerRadius` and the main
    /// screen's pixels — and checked against them by
    /// `DisplayCornersTests.testTheTableIsXcodesOwnDeviceProfiles`.
    static let displays: [String: Display] = [
        "iPhone10,3": .init(39, 1125, 2436), "iPhone10,6": .init(39, 1125, 2436),  // iPhone X
        "iPhone11,2": .init(39, 1125, 2436),  // iPhone Xs
        "iPhone11,4": .init(39, 1242, 2688), "iPhone11,6": .init(39, 1242, 2688),  // iPhone Xs Max
        "iPhone11,8": .init(41.5, 828, 1792),  // iPhone XR
        "iPhone12,1": .init(41.5, 828, 1792),  // iPhone 11
        "iPhone12,3": .init(39, 1125, 2436),  // iPhone 11 Pro
        "iPhone12,5": .init(39, 1242, 2688),  // iPhone 11 Pro Max
        "iPhone13,1": .init(44, 1080, 2340),  // iPhone 12 mini
        "iPhone13,2": .init(47, 1170, 2532),  // iPhone 12
        "iPhone13,3": .init(47, 1170, 2532),  // iPhone 12 Pro
        "iPhone13,4": .init(53, 1284, 2778),  // iPhone 12 Pro Max
        "iPhone14,2": .init(47.33, 1170, 2532),  // iPhone 13 Pro
        "iPhone14,3": .init(53.33, 1284, 2778),  // iPhone 13 Pro Max
        "iPhone14,4": .init(44, 1080, 2340),  // iPhone 13 mini
        "iPhone14,5": .init(47.33, 1170, 2532),  // iPhone 13
        "iPhone14,7": .init(47.33, 1170, 2532),  // iPhone 14
        "iPhone14,8": .init(53.33, 1284, 2778),  // iPhone 14 Plus
        "iPhone15,2": .init(55, 1179, 2556),  // iPhone 14 Pro
        "iPhone15,3": .init(55, 1290, 2796),  // iPhone 14 Pro Max
        "iPhone15,4": .init(55, 1179, 2556),  // iPhone 15
        "iPhone15,5": .init(55, 1290, 2796),  // iPhone 15 Plus
        "iPhone16,1": .init(55, 1179, 2556),  // iPhone 15 Pro
        "iPhone16,2": .init(55, 1290, 2796),  // iPhone 15 Pro Max
        "iPhone17,1": .init(62, 1206, 2622),  // iPhone 16 Pro
        "iPhone17,2": .init(62, 1320, 2868),  // iPhone 16 Pro Max
        "iPhone17,3": .init(55, 1179, 2556),  // iPhone 16
        "iPhone17,4": .init(55, 1290, 2796),  // iPhone 16 Plus
        "iPhone17,5": .init(47.33, 1170, 2532),  // iPhone 16e
        "iPhone18,1": .init(62, 1206, 2622),  // iPhone 17 Pro
        "iPhone18,2": .init(62, 1320, 2868),  // iPhone 17 Pro Max
        "iPhone18,3": .init(62, 1206, 2622),  // iPhone 17
        "iPhone18,4": .init(62, 1260, 2736),  // iPhone Air
        "iPhone18,5": .init(47.33, 1170, 2532),  // iPhone 17e
        "iPhone19,2": .init(62, 1206, 2622),  // iPhone 18 Pro
        "iPhone19,3": .init(62, 1320, 2868), "iPhone19,7": .init(62, 1320, 2868),  // iPhone 18 Pro Max
        "iPad13,1": .init(18, 1640, 2360), "iPad13,2": .init(18, 1640, 2360),  // iPad Air (4th generation)
        "iPad13,4": .init(18, 1668, 2388), "iPad13,5": .init(18, 1668, 2388), "iPad13,6": .init(18, 1668, 2388), "iPad13,7": .init(18, 1668, 2388),  // iPad Pro (11-inch) (3rd generation)
        "iPad13,8": .init(18, 2048, 2732), "iPad13,9": .init(18, 2048, 2732), "iPad13,10": .init(18, 2048, 2732), "iPad13,11": .init(18, 2048, 2732),  // iPad Pro (12.9-inch) (5th generation)
        "iPad13,16": .init(18, 1640, 2360), "iPad13,17": .init(18, 1640, 2360),  // iPad Air (5th generation)
        "iPad13,18": .init(25, 1640, 2360), "iPad13,19": .init(25, 1640, 2360),  // iPad (10th generation)
        "iPad14,1": .init(21.5, 1488, 2266), "iPad14,2": .init(21.5, 1488, 2266),  // iPad mini (6th generation)
        "iPad14,3": .init(18, 1668, 2388), "iPad14,4": .init(18, 1668, 2388),  // iPad Pro (11-inch) (4th generation)
        "iPad14,5": .init(18, 2048, 2732), "iPad14,6": .init(18, 2048, 2732),  // iPad Pro (12.9-inch) (6th generation)
        "iPad14,8": .init(18, 1640, 2360), "iPad14,9": .init(18, 1640, 2360),  // iPad Air 11-inch (M2)
        "iPad14,10": .init(18, 2048, 2732), "iPad14,11": .init(18, 2048, 2732),  // iPad Air 13-inch (M2)
        "iPad15,3": .init(18, 1640, 2360), "iPad15,4": .init(18, 1640, 2360),  // iPad Air 11-inch (M3)
        "iPad15,5": .init(18, 2048, 2732), "iPad15,6": .init(18, 2048, 2732),  // iPad Air 13-inch (M3)
        "iPad15,7": .init(25, 1640, 2360), "iPad15,8": .init(25, 1640, 2360),  // iPad (A16)
        "iPad16,1": .init(21.5, 1488, 2266), "iPad16,2": .init(21.5, 1488, 2266),  // iPad mini (A17 Pro)
        "iPad16,3": .init(30, 1668, 2420), "iPad16,4": .init(30, 1668, 2420),  // iPad Pro 11-inch (M4)
        "iPad16,5": .init(30, 2064, 2752), "iPad16,6": .init(30, 2064, 2752),  // iPad Pro 13-inch (M4)
        "iPad16,8": .init(18, 1640, 2360), "iPad16,9": .init(18, 1640, 2360),  // iPad Air 11-inch (M4)
        "iPad16,10": .init(18, 2048, 2732), "iPad16,11": .init(18, 2048, 2732),  // iPad Air 13-inch (M4)
        "iPad17,1": .init(30, 1668, 2420), "iPad17,2": .init(30, 1668, 2420),  // iPad Pro 11-inch (M5)
        "iPad17,3": .init(30, 2064, 2752), "iPad17,4": .init(30, 2064, 2752),  // iPad Pro 13-inch (M5)
        "iPad8,1": .init(18, 1668, 2388), "iPad8,2": .init(18, 1668, 2388), "iPad8,3": .init(18, 1668, 2388), "iPad8,4": .init(18, 1668, 2388),  // iPad Pro (11-inch) (1st generation)
        "iPad8,5": .init(18, 2048, 2732), "iPad8,6": .init(18, 2048, 2732), "iPad8,7": .init(18, 2048, 2732), "iPad8,8": .init(18, 2048, 2732),  // iPad Pro (12.9-inch) (3rd generation)
        "iPad8,9": .init(18, 1668, 2388), "iPad8,10": .init(18, 1668, 2388),  // iPad Pro (11-inch) (2nd generation)
        "iPad8,11": .init(18, 2048, 2732), "iPad8,12": .init(18, 2048, 2732),  // iPad Pro (12.9-inch) (4th generation)
    ]

    /// The radius in points of each model the table knows.
    static var radii: [String: CGFloat] { displays.mapValues(\.radius) }

    /// The largest radius of each idiom in `radii`, for a Face-ID-class device
    /// this build has never heard of. Over-estimating moves the host bar's end
    /// items a few pixels further in than they had to go; under-estimating
    /// would put them back under the corner.
    static let unknownPhoneRadius: CGFloat = 62
    static let unknownPadRadius: CGFloat = 30

    /// The radius for a model identifier, falling back to what the window's
    /// safe area says about a device the table does not know: a device with a
    /// home indicator (a non-zero bottom inset in any orientation, on the edge
    /// the indicator lives on) has rounded corners; one without has none.
    ///
    /// `nativePixels` is the window's screen's `nativeBounds.size`. A known
    /// model whose screen is not its own built-in panel is an external display
    /// (Stage Manager on a monitor), which has square corners.
    static func radius(model: String, isPad: Bool, homeIndicatorInset: CGFloat,
                       nativePixels: CGSize? = nil) -> CGFloat {
        if let known = displays[model] {
            if let pixels = nativePixels, pixels != known.native,
               pixels != CGSize(width: known.native.height, height: known.native.width) { return 0 }
            return known.radius
        }
        guard homeIndicatorInset > 0 else { return 0 }
        return isPad ? unknownPadRadius : unknownPhoneRadius
    }

    // MARK: - The shape

    /// Apple's continuous corner, normalised: at depth `d/R` from the edge,
    /// the corner covers `R * profile(d/R)` along the edge. The upper envelope
    /// of every rounded device profile in Xcode 27 (iPhone X … 18 Pro Max,
    /// iPad Air/Pro/mini); a circle would be 1 - sqrt(1 - (1 - x)²) and is
    /// 5–15 % short near the edge.
    static let profile: [(depth: CGFloat, along: CGFloat)] = [
        (0.000, 1.313), (0.010, 1.042), (0.020, 0.941), (0.030, 0.872), (0.040, 0.819),
        (0.050, 0.775), (0.060, 0.737), (0.080, 0.672), (0.100, 0.620), (0.125, 0.562),
        (0.150, 0.514), (0.200, 0.433), (0.250, 0.367), (0.300, 0.312), (0.400, 0.224),
        (0.500, 0.158), (0.600, 0.108), (0.700, 0.071), (0.800, 0.044), (0.900, 0.026),
        (1.000, 0.013),
    ]

    /// How far along the edge a corner of radius `radius` reaches at `depth`
    /// points in from that edge. Zero for a square corner and past the curve.
    static func occlusion(radius: CGFloat, depth: CGFloat) -> CGFloat {
        guard radius > 0, radius.isFinite, depth.isFinite else { return 0 }
        let x = max(0, depth) / radius
        guard x < 1 else { return 0 }
        for index in 1..<profile.count where x <= profile[index].depth {
            let low = profile[index - 1], high = profile[index]
            let t = (x - low.depth) / (high.depth - low.depth)
            return radius * (low.along + t * (high.along - low.along))
        }
        return 0
    }

    /// What the host needs: for a bar of `thickness` points on any edge, how
    /// many points each end loses. `top`/`bottom` are the ends of a vertical
    /// bar (it may be on the left or the right edge, so the worse of the two
    /// corners at that end), `left`/`right` those of a horizontal one.
    func barOcclusion(thickness: CGFloat) -> RemoteBarOcclusion {
        let depth = max(0, thickness) * Self.contentDepth
        func along(_ radius: CGFloat) -> CGFloat { Self.occlusion(radius: radius, depth: depth) }
        func points(_ value: CGFloat) -> Double { Double((value * 10).rounded(.up) / 10) }
        return RemoteBarOcclusion(top: points(max(along(topLeft), along(topRight))),
                                  bottom: points(max(along(bottomLeft), along(bottomRight))),
                                  left: points(max(along(topLeft), along(bottomLeft))),
                                  right: points(max(along(topRight), along(bottomRight))))
    }

    /// This window's corners: a window corner is a display corner only where it
    /// sits on the screen's own corner (within a point). Everything in points,
    /// in the screen's current interface orientation — all four display
    /// corners of every device in `radii` share one radius, so which physical
    /// corner is which does not matter.
    static func window(frame: CGRect, screen: CGRect, radius: CGFloat) -> DisplayCorners {
        guard radius > 0, !frame.isEmpty, !screen.isEmpty else { return .square }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        let left = near(frame.minX, screen.minX), right = near(frame.maxX, screen.maxX)
        let top = near(frame.minY, screen.minY), bottom = near(frame.maxY, screen.maxY)
        return DisplayCorners(topLeft: top && left ? radius : 0, topRight: top && right ? radius : 0,
                              bottomLeft: bottom && left ? radius : 0, bottomRight: bottom && right ? radius : 0)
    }
}

/// `bar_occlusion_points` on the wire (core `remote/corners.py`).
struct RemoteBarOcclusion: Codable, Equatable, Sendable {
    var top: Double
    var bottom: Double
    var left: Double
    var right: Double

    var isZero: Bool { top <= 0 && bottom <= 0 && left <= 0 && right <= 0 }
}
