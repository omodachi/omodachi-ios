import SwiftUI
import UIKit

/// Study 03 §12 and §13. The first screen an unpaired app shows is the list of
/// computers on this Wi-Fi — not a form with a field called "电脑端服务地址".
///
/// The list and the waiting card are one panel: selecting a host changes the
/// title and the content in place and puts a back arrow in the corner (A-35).
/// There is no modal, no second window and no "connected" confirmation page —
/// the moment the claim lands, the Panel is what the user sees.
struct ConnectionScreen: View {
    @EnvironmentObject private var home: HomeStore
    @ObservedObject var directory: PairedHostDirectory
    @StateObject private var browser = HostBrowser()
    @StateObject private var flow: ConnectionFlowModel
    /// Set when the app already has a paired host: the list is then a way to
    /// add or switch, and there is a way back.
    var onDismiss: (() -> Void)?
    /// PAIR-5 §2. The hosts whose credential this launch threw away, by name.
    /// The row itself reads 未配对 like any other unpaired row — this is the
    /// one line that says why a device that *was* paired is looking at the
    /// list again.
    var staleCredentialHosts: [HostCredentialGate.StaleCredential] = []
    @FocusState private var manualFocused: Bool

    init(directory: PairedHostDirectory, onDismiss: (() -> Void)? = nil,
         staleCredentialHosts: [HostCredentialGate.StaleCredential] = []) {
        self.directory = directory
        self.onDismiss = onDismiss
        self.staleCredentialHosts = staleCredentialHosts
        // PAIR-4 §1: the model is the one thing that can see both halves of
        // "is this host paired" — the Keychain and this directory — so it is
        // given the directory rather than being asked about the Keychain alone.
        _flow = StateObject(wrappedValue: ConnectionFlowModel(
            deviceID: Self.deviceID(), deviceName: CompanionDeviceName.current(), directory: directory))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            FlowRule()
            ScrollView { content.padding(.bottom, 24) }
        }
        .background(OmodachiTheme.background)
        // PAIR-5. This screen has **one** name, and the Shell gives it:
        // `onboarding-gate` (`Shell/OmodachiApp.swift`). It used to carry
        // `connection-screen` here as well, which never reached anybody — an
        // identifier applied above this one replaces it, and nesting does not
        // help: SwiftUI flattens a container that holds a single container, so
        // the outer name is the only one in the tree (measured on the
        // Simulator, both with and without `accessibilityElement(children:)`).
        // Five acceptance suites were waiting for the name that lost, which is
        // half of what AGENT-2 §9.4 read as "it never returns to the list".
        .accessibilityElement(children: .contain)
        .task {
            browser.start()
            _ = OmodachiTheme.appearanceRevision
        }
        .onDisappear { browser.stop(); flow.cancel() }
        // A-32 / PAIR-2 §3.3: each discovered host is asked once, over the same
        // unauthenticated /health the waiting card's fingerprint comes from.
        .task(id: candidates.map(\.id).joined(separator: "\u{1}")) {
            flow.probePairingModes(candidates)
        }
        .onChange(of: flow.claimed) { _, record in
            guard let record else { return }
            directory.remember(record)
            var profile = home.profile
            profile.companionURL = record.account
            profile.mock = false
            // N-26: the name on screen is the host's own, not the address the
            // app happened to reach it on.
            if !record.hostName.isEmpty { profile.hostname = record.hostName }
            home.profile = profile
            Task { await home.connectCompanion() }
            onDismiss?()
        }
    }

    // MARK: - Chrome

    private var title: String { flow.stage == .pairing ? Strings.hostsTitlePairing : Strings.hostsTitleConnect }

    private var header: some View {
        HStack(spacing: 8) {
            if flow.stage != .list {
                Tap(action: { flow.backToList() }) {
                    HostGlyphView(glyph: "\u{f053}", fallbackSymbol: "chevron.left", size: 14)
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                
                .accessibilityIdentifier("connect-back")
            } else if onDismiss != nil {
                Tap(action: { onDismiss?() }) {
                    HostGlyphView(glyph: "\u{f00d}", fallbackSymbol: "xmark", size: 14)
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                
                .accessibilityIdentifier("connect-close")
            }
            Text(title)
                .font(OmodachiTheme.font("heading"))
                .foregroundStyle(OmodachiTheme.text)
            Spacer()
        }
        .padding(.horizontal, flow.stage == .list && onDismiss == nil ? OmodachiTheme.rowPaddingX : 4)
        .frame(height: 49)
    }

    @ViewBuilder private var content: some View {
        switch flow.stage {
        case .list:
            list
            demoRow
        case .manual: manual
        case .pairing: PairingCard(flow: flow)
        }
    }

    // MARK: - §12 the list and its three empty states

    private var candidates: [HostCandidate] {
        // PAIR-4 §2: `flow.revision` is read here so that forgetting a host —
        // which changes the Keychain, not this view's state — rebuilds the rows.
        _ = flow.revision
        return browser.hosts.compactMap(HostCandidate.init(discovered:)).map(flow.decorate)
    }

    /// PAIR-4 §2 / N-14. Every row this device is holding something for can be
    /// forgotten from the list itself, in two taps, with the host offline. It
    /// is the exit the old build had only inside Settings — which an unpaired
    /// app could not reach, because Settings lives behind the Panel and the
    /// Panel lives behind a directory record.
    @ViewBuilder private func forgetRow(_ candidate: HostCandidate) -> some View {
        if flow.hasStoredIdentity(candidate) {
            TwoStepButton(title: Strings.settingsForget, confirmTitle: Strings.settingsForgetConfirm) {
                flow.forget(account: candidate.account)
                // The list is reachable from the Panel too (N-26), so the row
                // being forgotten can be the host this app is connected to.
                if HostAccount.canonical(home.profile.companionURL) == candidate.account {
                    var profile = home.profile
                    profile.companionURL = ""
                    home.profile = profile
                    Task { await home.disconnectCompanion() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("host-forget-\(candidate.id)")
        }
    }

    @ViewBuilder private var list: some View {
        let rows = candidates
        switch browser.state {
        case .results, .empty, .searching where !rows.isEmpty:
            staleNote
            GroupLabel(text: Strings.hostsFoundOnWifi(Format.count(rows.count)))
            ForEach(rows) { candidate in
                HostRow(candidate: candidate) { start(candidate) }
                forgetRow(candidate)
            }
            if rows.isEmpty { emptyNone }
            FlowRule()
            manualRow
        case .searching:
            staleNote
            GroupLabel(text: Strings.hostsSearching)
            EmptyBlock(title: Strings.hostsSearchingDetail,
                       detail: Strings.hostsSearchingDetail)
                .accessibilityIdentifier("connect-empty-searching")
            FlowRule()
            manualRow
        case .denied:
            staleNote
            deniedState
        case .unavailable(let reason):
            staleNote
            GroupLabel(text: Strings.hostsLanSearch)
            EmptyBlock(title: reason, detail: Strings.hostsManualNote)
                .accessibilityIdentifier("connect-empty-unavailable")
            FlowRule()
            manualRow
        }
    }

    /// PAIR-5 §2's optional line, drawn above the list it explains.
    @ViewBuilder private var staleNote: some View {
        if !staleCredentialHosts.isEmpty {
            InlineError(message: Self.staleMessage(staleCredentialHosts),
                        identifier: "connect-credential-stale")
        }
    }

    /// CORE-2 §1: one sentence per reason the host gave. An expiry is one
    /// approval away from working again and says so; a revoke says it was
    /// taken back on the computer; a refusal with no reason reads as before.
    static func staleMessage(_ hosts: [HostCredentialGate.StaleCredential]) -> String {
        var lines: [String] = []
        for reason in CredentialRejection.allCases {
            let names = hosts.filter { $0.reason == reason }.map(\.hostName)
            guard !names.isEmpty else { continue }
            let joined = names.joined(separator: "\u{3001}")
            switch reason {
            case .unknown:
                lines.append(Strings.hostsCredentialStale(joined))
            case .expired:
                lines.append(Strings.hostsCredentialLine(joined, ReasonText.message(reason.rawValue, domain: .host),
                                                         Strings.hostsCredentialExpiredAction))
            case .revoked, .purged:
                lines.append(Strings.hostsCredentialLine(joined, ReasonText.message(reason.rawValue, domain: .host),
                                                         Strings.hostsCredentialRevokedAction))
            }
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var emptyNone: some View {
        EmptyBlock(title: Strings.hostsNone,
                   detail: Strings.hostsNoneDetail)
            .accessibilityIdentifier("connect-empty-none")
        FlowButton(title: Strings.hostsSearchAgain, kind: .secondary) { browser.retry() }
            .padding(.horizontal, 12)
            .accessibilityIdentifier("connect-retry")
    }

    /// A-33 / N-19's hardest board: on iPadOS the Settings row for local
    /// network does not exist until the app has triggered the system prompt
    /// once, so the primary exit is "ask again" and not "go to Settings".
    @ViewBuilder private var deniedState: some View {
        GroupLabel(text: Strings.hostsPermission)
        EmptyBlock(title: Strings.hostsPermissionDetail,
                   detail: Strings.hostsPermissionAskDetail)
            .accessibilityIdentifier("connect-empty-denied")
        HStack(spacing: 8) {
            FlowButton(title: Strings.hostsPermissionAsk) { browser.retry() }
                .accessibilityIdentifier("connect-retry")
            FlowButton(title: Strings.actionOpenSettings, kind: .secondary) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .accessibilityIdentifier("connect-open-settings")
        }
        .padding(.horizontal, 12)
        FlowRule()
        manualRow
    }

    private var manualRow: some View {
        Tap(action: { flow.stage = .manual }) {
            HStack(spacing: 10) {
                HostGlyphView(glyph: "\u{f067}", fallbackSymbol: "plus", size: 16)
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Strings.hostsManual)
                        .font(OmodachiTheme.font(size: 13))
                        .foregroundStyle(OmodachiTheme.text)
                    Text(Strings.hostsManualField)
                        .font(OmodachiTheme.font(size: 11))
                        .foregroundStyle(OmodachiTheme.tertiaryText)
                }
                Spacer()
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(height: ConnectionParts.actionHeight)
            .contentShape(Rectangle())
        }
        
        .accessibilityIdentifier("connect-add-manual")
    }

    /// STORE-1 §1. The first screen's last row: a way to see the app without
    /// an Omarchy computer — App Review's way in, among others. It is only on
    /// the unpaired first screen; the list reached from a paired Panel has a
    /// host to show already.
    @ViewBuilder private var demoRow: some View {
        if onDismiss == nil {
            FlowRule()
            Tap(action: { home.enterDemo() }) {
                HStack(spacing: 10) {
                    HostGlyphView(glyph: "\u{f144}", fallbackSymbol: "play.rectangle", size: 16)
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Strings.demoEnter)
                            .font(OmodachiTheme.font(size: 13))
                            .foregroundStyle(OmodachiTheme.text)
                        Text(Strings.demoEnterDetail)
                            .font(OmodachiTheme.font(size: 11))
                            .foregroundStyle(OmodachiTheme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .frame(minHeight: ConnectionParts.actionHeight)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("demo-enter")
        }
    }

    // MARK: - §12 ⑤ manual add

    @ViewBuilder private var manual: some View {
        GroupLabel(text: Strings.hostsManualTitle)
        TextField("omarchy", text: $flow.manualInput) // non-copy: an example host name
            .font(OmodachiTheme.font(size: 16))
            .foregroundStyle(OmodachiTheme.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .focused($manualFocused)
            .accessibilityIdentifier("connect-manual-field")
            .padding(.horizontal, 10)
            .frame(height: ConnectionParts.actionHeight)
            .overlay(Rectangle().stroke(OmodachiTheme.accent, lineWidth: OmodachiTheme.controlBorderWidth)
                .allowsHitTesting(false))
            // A-01: the whole drawn box focuses the field, not just its line.
            .textEntryHitArea($manualFocused)
            .padding(.horizontal, 12)
        note(Strings.hostManualHint)
        HStack(spacing: 8) {
            FlowButton(title: Strings.actionConnect, enabled: HostCandidate.manual(flow.manualInput) != nil) {
                if let candidate = HostCandidate.manual(flow.manualInput) {
                    start(flow.decorate(candidate))
                }
            }
            .accessibilityIdentifier("connect-manual-submit")
            FlowButton(title: Strings.actionCancel, kind: .ghost) { flow.stage = .list }
        }
        .padding(.horizontal, 12)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont(size: 11))
            .foregroundStyle(OmodachiTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private func start(_ candidate: HostCandidate) {
        // N-28: the key is made once, here, and never shown to anyone.
        // UX-4 §2: the account goes with the key, because a claim that did not
        // carry the key — an adoption — still has to be able to offer it.
        flow.select(candidate,
                    sshPublicKey: CompanionSSHKey.publicKeyLine(account: home.profile.keyAccount),
                    sshKeyAccount: home.profile.keyAccount)
    }

    /// Stable for the lifetime of this install, so re-pairing after a revoke is
    /// the same device rather than a new row in the host's registry.
    // One reader of the stable device id, on `HomeStore`: AUTH-1 signs it, so
    // two implementations that could drift is two implementations too many.
    private static func deviceID() -> String { HomeStore.companionDeviceID() }
}
