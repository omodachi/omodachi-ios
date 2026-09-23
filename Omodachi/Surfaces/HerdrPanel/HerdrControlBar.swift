import SwiftUI

/// A-13. 44 high, pinned to the top of the software keyboard when there is one
/// and to the bottom when there is not; the controls inside stay 28 (A-01), and
/// the extra is whitespace.
///
/// Every button resolves through `HerdrControlMapper`, so none of them can send
/// a key code. A control the host bridge has no route for is drawn disabled
/// with the reason rather than hidden — a missing button is indistinguishable
/// from a button that does nothing.
struct HerdrControlBar: View {
    @ObservedObject var store: HerdrStore
    var onTogglePanel: () -> Void = {}
    var onConfirm: (HerdrControlRequest) -> Void = { _ in }

    private var actions: [HerdrControlAction] { HerdrControlAction.allCases }

    var body: some View {
        HStack(spacing: 0) {
            Tap(action: onTogglePanel) {
                OmodachiSymbol.view(size: NativeBarMetrics.glyph)
                    .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                    .contentShape(Rectangle())
            }
            
            .accessibilityLabel(Strings.barLogoLabel)
            .accessibilityIdentifier("herdr-panel")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OmodachiTheme.space("xs")) {
                    ForEach(actions) { action in
                        control(action)
                    }
                }
                .padding(.horizontal, OmodachiTheme.space("xs"))
            }

            Text(modeLabel)
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(store.connection == .controlling ? OmodachiTheme.accent : OmodachiTheme.muted)
                .padding(.horizontal, OmodachiTheme.space("lg"))
                .accessibilityIdentifier("herdr-mode")
        }
        .frame(height: NativeBarMetrics.hit)
        .frame(maxWidth: .infinity)
        .background(OmodachiTheme.barBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(OmodachiTheme.border)
                .frame(height: NativeBarMetrics.edgeRule).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-control-bar")
    }

    private var modeLabel: String {
        switch store.connection {
        case .controlling: Strings.herdrModeControl
        case .observing: Strings.herdrModeObserve
        case .connecting: "…"
        case .retrying(let attempt): Strings.herdrModeRetry(Format.count(attempt))
        case .unavailable: Strings.herdrModeOffline
        case .idle: "—"
        }
    }

    @ViewBuilder private func control(_ action: HerdrControlAction) -> some View {
        let request = HerdrControlMapper.request(action, layout: store.layout, selected: store.selected)
        let unsupported: String? = if case .unsupported(let reason) = request { reason } else { nil }
        Tap(action: {
            if action.confirms { onConfirm(request) } else { store.perform(request, confirmed: true) }
        }) {
            Glyph(symbol: action.symbol, points: OmodachiTheme.fontSize("icon-small"))
                .frame(minWidth: OmodachiTheme.controlHeight, minHeight: OmodachiTheme.controlHeight)
        }
        .control(bordered: true, fill: OmodachiTheme.normalFill)
        .frame(minWidth: NativeBarMetrics.hit, minHeight: NativeBarMetrics.hit)
        .disabled(unsupported != nil)
        .help(unsupported ?? action.title)
        .accessibilityLabel(unsupported.map { Strings.pair(action.title, $0) } ?? action.title)
        .accessibilityIdentifier("herdr-action-\(action.rawValue)")
    }
}
