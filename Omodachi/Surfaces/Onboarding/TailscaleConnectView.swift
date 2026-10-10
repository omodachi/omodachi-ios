import SwiftUI
import UIKit

/// TAIL-3b S01–S03 / I01. The first screen: the Tailscale road.
///
/// A name pasted here becomes a MagicDNS name before anything is dialled (S02
/// shows which), and only that name is ever dialled — so nothing on this page
/// can make iOS ask for Local Network access. People who do not use Tailscale
/// take the row at the bottom to the Wi-Fi road, which is the only place the
/// Bonjour browser starts.
struct TailscaleConnectView: View {
    @ObservedObject var flow: ConnectionFlowModel
    /// I01: iPad landscape puts the help in a second column.
    let wide: Bool
    /// The demo row is only on the unpaired first screen (STORE-1 §1).
    let showsDemo: Bool
    let onConnect: () -> Void
    let onLan: () -> Void
    let onDemo: () -> Void

    @FocusState private var focused: Bool
    @State private var tailscaleUp = TailscaleAddress.isUp
    @State private var showsWhere = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        main
                        FlowRule().padding(.top, 12)
                        entries
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    Rectangle().fill(OmodachiTheme.border.opacity(0.35)).frame(width: OmodachiTheme.controlBorderWidth)
                    VStack(alignment: .leading, spacing: 0) {
                        firstTime
                        whereSteps
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    main
                    if showsWhere, flow.tailscaleProblem == nil { whereSteps }
                    if flow.tailscaleProblem == nil { firstTime }
                    FlowRule().padding(.top, 12)
                    entries
                }
            }
        }
        .onAppear { tailscaleUp = TailscaleAddress.isUp }
        // Coming back from the Tailscale app is the moment it may have been
        // switched on.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            tailscaleUp = TailscaleAddress.isUp
        }
        .onChange(of: flow.tailscaleProblem) { _, _ in tailscaleUp = TailscaleAddress.isUp }
    }

    // MARK: - Field, status, Connect

    @ViewBuilder private var main: some View {
        Text(Strings.onbLede)
            .font(OmodachiTheme.bodyFont(size: 15))
            .foregroundStyle(OmodachiTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, 14)
        GroupLabel(text: Strings.tsNameLabel).padding(.top, 8)
        NameField(text: $flow.tailscaleInput, focused: $focused, onSubmit: connect) { flow.paste($0) }
        resolutionLine
        if let problem = flow.tailscaleProblem {
            problemBlock(problem)
        } else {
            note(Strings.tsFieldHint)
            StatusLine(text: tailscaleUp ? Strings.tsHereYes(DeviceWord.current) : Strings.tsHereNo(DeviceWord.current),
                       kind: tailscaleUp ? .ok : .warn, identifier: "connect-ts-here")
                .accessibilityHint(Strings.tsHereHow)
            FlowButton(title: Strings.actionConnect, enabled: canConnect, action: connect)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .accessibilityIdentifier("connect-ts-submit")
            if !wide {
                LinkLine(title: Strings.tsWhere, identifier: "connect-ts-where") { showsWhere.toggle() }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
        }
    }

    private var canConnect: Bool {
        !flow.tailscaleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !flow.running
    }

    private func connect() {
        guard canConnect else { return }
        focused = false
        onConnect()
    }

    /// S02: what the field will connect as, before Connect.
    @ViewBuilder private var resolutionLine: some View {
        switch flow.resolution {
        case .resolved(let url) where url.host?.lowercased() != flow.tailscaleInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased():
            StatusLine(text: Strings.tsResolved(url.host ?? ""), kind: .next, identifier: "connect-ts-resolved")
        case .resolving:
            StatusLine(text: Strings.tsResolving, kind: .next, identifier: "connect-ts-resolving")
        default:
            EmptyView()
        }
    }

    // MARK: - E03–E06, E04b: said here, not on a card

    @ViewBuilder private func problemBlock(_ problem: ConnectionFlowModel.TailscaleProblem) -> some View {
        let words = Self.words(problem, tailscaleUp: tailscaleUp)
        StatusLine(text: Strings.pairingNotStarted, kind: .error, identifier: "connect-ts-problem")
        Text(words.title)
            .font(OmodachiTheme.bodyFont(size: 18))
            .foregroundStyle(OmodachiTheme.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .accessibilityIdentifier("connect-ts-problem-title")
        note(words.detail)
        HStack(spacing: 8) {
            FlowButton(title: Strings.actionRetry, kind: .secondary, action: connect)
                .accessibilityIdentifier("connect-ts-retry")
            FlowButton(title: Strings.actionCancel, kind: .ghost) { flow.tailscaleInput = "" }
                .accessibilityIdentifier("connect-ts-cancel")
        }
        .padding(.horizontal, 12)
    }

    /// The title and sentence for each problem. A name that does not resolve
    /// or does not answer while this device has no Tailscale address is about
    /// this device, not the computer (E01's words).
    static func words(_ problem: ConnectionFlowModel.TailscaleProblem, tailscaleUp: Bool) -> (title: String, detail: String) {
        switch problem {
        case .noName(let name) where !tailscaleUp, .asleep(let name) where !tailscaleUp:
            return (Strings.errTsOffTitle(DeviceWord.current), Strings.errTsOffBody(name))
        case .notTailscale(let name): return (Strings.errNotTailscaleTitle(name), Strings.errNotTailscaleBody)
        case .noName(let name): return (Strings.errNoNameTitle(name), Strings.errNoNameBody)
        case .noPtr(let address): return (Strings.errNoPtrTitle(address), Strings.errNoPtrBody)
        case .asleep(let name): return (Strings.errAsleepTitle(name), Strings.errAsleepBody)
        case .noHost(let name): return (Strings.errNoHostTitle(name), Strings.errNoHostBody)
        }
    }

    // MARK: - Help

    @ViewBuilder private var firstTime: some View {
        GroupLabel(text: Strings.tsFirstTime).padding(.top, 10)
        NumberedStep(number: 1, text: Strings.tsStep1)
        NumberedStep(number: 2, text: Strings.tsStep2(DeviceWord.current), linkTitle: Strings.tsStep2Get,
                linkIdentifier: "connect-ts-appstore") { openURL(TailscaleAddress.appStoreURL) }
    }

    @ViewBuilder private var whereSteps: some View {
        GroupLabel(text: Strings.whereTitle).padding(.top, 10)
        NumberedStep(number: 1, text: Strings.where1(DeviceWord.current))
        NumberedStep(number: 2, text: Strings.where2)
        NumberedStep(number: 3, text: Strings.where3)
        if !wide { NumberedStep(number: 4, text: Strings.where4) }
        note(Strings.wherePanel)
        if !wide {
            LinkLine(title: Strings.whereDone, identifier: "connect-ts-where-done") { showsWhere = false }
                .padding(.horizontal, 12)
        }
    }

    // MARK: - The two other roads

    @ViewBuilder private var entries: some View {
        EntryRow(glyph: "\u{f1eb}", fallbackSymbol: "wifi", title: Strings.lanEntry, detail: Strings.lanEntryDetail,
                 action: onLan)
            .accessibilityIdentifier("lan-entry")
        if showsDemo {
            FlowRule()
            EntryRow(glyph: "\u{f144}", fallbackSymbol: "play.rectangle", title: Strings.demoEnter,
                     detail: Strings.demoEnterDetail, action: onDemo)
                .accessibilityIdentifier("demo-enter")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont(size: 11))
            .foregroundStyle(OmodachiTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}
