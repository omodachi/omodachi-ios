import SwiftUI

/// The root embeds this only when the selected backend is VNC. It introduces no
/// route, bar, overlay or automatic connection.
struct VNCBackendCanvas: UIViewRepresentable {
    let adapter: VNCBackendAdapter
    func makeUIView(context: Context) -> OMVNCRemoteView { adapter.view }
    func updateUIView(_ uiView: OMVNCRemoteView, context: Context) {}
}
