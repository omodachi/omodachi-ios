import CoreGraphics
import Foundation
import OSLog

/// PERF-1 geometry trace. Debug-only, three lines per session: what the app
/// asked the host for, what the host planned, and the rectangle the picture was
/// actually drawn into. A letterbox is one of those three disagreeing with
/// another, and the trace says which one.
///
/// Nothing here is a control path: it reads values that already exist and never
/// changes a request, a profile or a frame.
enum RemoteGeometryTrace {
    #if DEBUG
    private static let log = Logger(subsystem: "app.omodachi", category: "perf")
    private static func emit(_ line: String) { log.info("\(line, privacy: .public)") }
    #else
    private static func emit(_ line: String) {}
    #endif

    private static func round(_ value: Double) -> String { String(format: "%.4f", value) }

    static func request(_ value: RemoteGeometryRequest, mode: RemoteMode, backend: RemoteBackend) {
        let size = value.viewport_points
        let aspect = size.height > 0 ? size.width / size.height : 0
        emit("remote.geometry_request mode=\(mode.rawValue) backend=\(backend.rawValue)"
             + " viewport=\(round(size.width))x\(round(size.height)) aspect=\(round(aspect))"
             + " orientation=\(value.orientation) long_edge=\(value.logical_long_edge)"
             + " quality_fps=\(value.quality.fps) quality_bitrate_kbps=\(value.quality.bitrate_kbps)"
             + " quality_max_pixels=\(value.quality.max_pixels)")
    }

    static func planned(_ session: RemoteSessionDTO) {
        guard let profile = session.profile else {
            emit("remote.geometry_planned mode=\(session.mode.rawValue) state=\(session.state) profile=absent")
            return
        }
        let mode = profile.output_mode_pixels
        let stream = profile.stream_pixels
        let streamAspect = Double(stream.width) / Double(max(1, stream.height))
        let modeAspect = Double(mode.width) / Double(max(1, mode.height))
        emit("remote.geometry_planned mode=\(session.mode.rawValue) backend=\(session.backend.rawValue)"
             + " output_mode=\(mode.width)x\(mode.height) output_aspect=\(round(modeAspect))"
             + " scale=\(round(profile.output_scale))"
             + " logical=\(round(profile.logical_size.width))x\(round(profile.logical_size.height))"
             + " stream=\(stream.width)x\(stream.height) stream_aspect=\(round(streamAspect))"
             + " fps=\(profile.fps) bitrate_kbps=\(profile.bitrate_kbps)")
    }

    static func presented(pixels: RemotePixels, rect: CGRect, viewport: CGSize) {
        let decoded = Double(pixels.width) / Double(max(1, pixels.height))
        let canvas = viewport.height > 0 ? viewport.width / viewport.height : 0
        emit("remote.geometry_presented decoded=\(pixels.width)x\(pixels.height) decoded_aspect=\(round(decoded))"
             + " video_rect=\(round(rect.origin.x)),\(round(rect.origin.y))"
             + " \(round(rect.width))x\(round(rect.height))"
             + " canvas=\(round(viewport.width))x\(round(viewport.height)) canvas_aspect=\(round(canvas))"
             + " letterbox_x=\(round(viewport.width - rect.width))"
             + " letterbox_y=\(round(viewport.height - rect.height))")
    }
}
