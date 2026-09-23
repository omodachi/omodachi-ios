import Foundation

public struct InputPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct InputSize: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct InputRect: Equatable, Sendable {
    public var origin: InputPoint
    public var size: InputSize
    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = InputPoint(x: x, y: y)
        size = InputSize(width: width, height: height)
    }
    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var isValid: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
    }
    public func contains(_ point: InputPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
    public func inset(by insets: InputInsets) -> InputRect {
        InputRect(x: minX + insets.leading, y: minY + insets.top,
                  width: size.width - insets.leading - insets.trailing,
                  height: size.height - insets.top - insets.bottom)
    }
}

public struct InputInsets: Equatable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double
    public var isFinite: Bool {
        top.isFinite && leading.isFinite && bottom.isFinite && trailing.isFinite
    }
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
}

public struct StreamPixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var isValid: Bool { width > 0 && height > 0 }
}

public struct StreamTransform: Equatable, Sendable {
    public var scaleX: Double
    public var scaleY: Double
    public var offsetX: Double
    public var offsetY: Double
    public var isFinite: Bool {
        scaleX.isFinite && scaleY.isFinite && offsetX.isFinite && offsetY.isFinite
    }
    public init(scaleX: Double = 1, scaleY: Double = 1, offsetX: Double = 0, offsetY: Double = 0) {
        self.scaleX = scaleX; self.scaleY = scaleY; self.offsetX = offsetX; self.offsetY = offsetY
    }
}

/// Geometry is expressed in one viewport coordinate space. `videoRect` is the
/// actual displayed video rectangle in that space; letterbox and panel areas
/// remain outside it and do not produce input. Safe-area insets constrain the
/// accepted touch region without inventing host coordinates.
public struct VideoInputGeometry: Equatable, Sendable {
    public var viewport: InputRect
    public var videoRect: InputRect
    public var streamPixels: StreamPixelSize
    public var safeAreaInsets: InputInsets
    public var streamTransform: StreamTransform

    public init(viewport: InputRect, videoRect: InputRect, streamPixels: StreamPixelSize,
                safeAreaInsets: InputInsets = .init(), streamTransform: StreamTransform = .init()) {
        self.viewport = viewport
        self.videoRect = videoRect
        self.streamPixels = streamPixels
        self.safeAreaInsets = safeAreaInsets
        self.streamTransform = streamTransform
    }

    /// Maps a viewport point to stream pixels. The nine-point mapping (corners,
    /// edge midpoints and center) is the same normalized affine transform; the
    /// result is clamped to the last valid pixel and rejects outside/letterbox
    /// points before applying scale and offset.
    public func map(_ point: InputPoint) -> InputPoint? {
        guard point.x.isFinite, point.y.isFinite,
              viewport.isValid, videoRect.isValid, streamPixels.isValid,
              safeAreaInsets.isFinite, streamTransform.isFinite else { return nil }
        let acceptedRect = viewport.inset(by: safeAreaInsets)
        guard acceptedRect.isValid, acceptedRect.contains(point), videoRect.contains(point) else { return nil }
        let u = (point.x - videoRect.minX) / videoRect.size.width
        let v = (point.y - videoRect.minY) / videoRect.size.height
        // Match LiSendMousePositionEvent's reference-space contract: the
        // normalized point is scaled by the full reference width/height and
        // only then clamped to the last valid pixel.
        let rawX = u * Double(streamPixels.width)
        let rawY = v * Double(streamPixels.height)
        let transformedX = rawX * streamTransform.scaleX + streamTransform.offsetX
        let transformedY = rawY * streamTransform.scaleY + streamTransform.offsetY
        guard transformedX.isFinite, transformedY.isFinite else { return nil }
        return InputPoint(x: min(Double(streamPixels.width - 1), max(0, transformedX)),
                          y: min(Double(streamPixels.height - 1), max(0, transformedY)))
    }

    /// Converts a relative point delta into stream-pixel delta using the actual
    /// displayed video rectangle rather than the viewport or device scale.
    public func relativeDelta(_ delta: InputPoint, sensitivity: Double = 1) -> InputPoint {
        guard delta.x.isFinite, delta.y.isFinite, sensitivity.isFinite,
              videoRect.isValid, streamPixels.isValid else { return .init(x: 0, y: 0) }
        let result = InputPoint(x: delta.x * Double(streamPixels.width) / videoRect.size.width * sensitivity,
                                y: delta.y * Double(streamPixels.height) / videoRect.size.height * sensitivity)
        guard result.x.isFinite, result.y.isFinite else { return .init(x: 0, y: 0) }
        return result
    }
}
