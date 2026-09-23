import SwiftUI

/// Panel ④ — Herdr (A-56 "work surface", A-63).
///
/// A-63 and N-33: entering connects. There is no "Herdr available" to read and
/// no "连接" to press — the surface's own progress row says what is happening
/// while it happens, and a failure says what to do about it.
struct HerdrPanelView: View {
    @ObservedObject var store: HerdrStore

    var body: some View {
        HerdrSurface(store: store)
    }
}
