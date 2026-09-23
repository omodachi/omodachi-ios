import SwiftUI

/// Panel ⑥ — Settings (A-56 "read and choose", N-27, N-38, N-26 rev 5).
///
/// What is here is what had nowhere better to be: preferences with no other
/// home, the switches that decide what the bar shows, and revocation. What is
/// *not* here is as decided — switching host is panel ①'s title (N-26),
/// connecting is the host list (N-19), Remote's mode and backend are its own
/// panel's cards (N-22), and Do Not Disturb is panel ⑦'s head (N-36), because
/// it is a state that changes on its own rather than a preference.
///
/// There is no × (A-55): the gear again is what puts panel ① back. And there is
/// no sheet — the one host's detail opens *in* this page, because a panel fills
/// the panel area and a modal over it would be a second navigation model.
struct SettingsPanelView: View {
    @ObservedObject var directory: PairedHostDirectory
    @ObservedObject var registry: PanelRegistry
    @Binding var preferences: ShellPreferences
    @ObservedObject var router: SurfaceRouter
    /// N-37. The four picture gestures and what each one resolves to on this
    /// host right now. Settings ⑥ only reads it; the picture registers them.
    @ObservedObject var remote: RemoteSessionController

    @EnvironmentObject private var home: HomeStore
    @State private var remotePreferences = RemotePreferences.load()
    @State private var openHost: PairedHostRecord?
    @State private var relativeTouchpad = NativePointerPreference.relativeTouchpad()
    @State private var message: String?
    /// UX-4 §2. What this device would offer SSH, beside what the host has
    /// written down. Read once when the page is drawn, like the transcripts.
    @State private var sshKey: SSHKeyReport?
    @State private var sshKeyUnread = false
    /// STORE-2 §4. The licence page opens in ⑥, under its row (A-55).
    @State private var licenceOpen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { proxy in
            let narrow = PanelMeasure.isNarrow(proxy.size.width)
            PanelArea(Strings.panelSettings, identifier: "settings-screen") {
                hosts
                FlowRule()
                remote(narrow: narrow)
                FlowRule()
                stream(narrow: narrow)
                FlowRule()
                gestures
                FlowRule()
                barEntries
                FlowRule()
                keybindings
                FlowRule()
                clipboard(narrow: narrow)
                FlowRule()
                device(narrow: narrow)
                FlowRule()
                approval
                FlowRule()
                diagnostics
                FlowRule()
                about
            }
        }
        .task { await readSSHKey() }
        .task { await remote.refreshHostPreferences() }
    }

    // MARK: - Hosts

    @ViewBuilder private var hosts: some View {
        GroupLabel(text: Strings.gateSshHostKeyHost)
        if directory.records.isEmpty {
            EmptyState(title: Strings.settingsNoHosts, detail: Strings.settingsNoHostsDetail)
        }
        ForEach(directory.records) { record in
            if let candidate = record.candidate {
                HostRow(candidate: candidate,
                        trailing: record.account == home.profile.companionURL && home.companionConnected
                            ? Strings.settingsConnected : nil) {
                    openHost = openHost?.id == record.id ? nil : record
                }
                if openHost?.id == record.id {
                    HostDetailView(record: record, directory: directory) { forgot in
                        openHost = nil
                        if forgot { afterForgetting(record) }
                    }
                    .environmentObject(home)
                }
            }
        }
        Row(title: Strings.settingsFindHosts, icon: Icon.search, identifier: "settings-find-hosts") {
            router.show(.menu)
        }
        if let message {
            InlineError(message: message, identifier: "settings-message")
        }
    }

    /// Review item 16 / rev 5: after forgetting a host, go somewhere real.
    private func afterForgetting(_ record: PairedHostRecord) {
        guard let next = directory.records.first(where: { $0.account != record.account }) else {
            // Zero hosts left: the unpaired first screen is the app now (N-19),
            // and the Shell puts it up on its own once the directory empties.
            message = nil
            return
        }
        var profile = home.profile
        profile.companionURL = next.account
        profile.mock = false
        if !next.hostName.isEmpty { profile.hostname = next.hostName }
        home.profile = profile
        Task { await home.connectCompanion() }
        message = Strings.settingsSwitchedTo(next.hostName)
    }

    // MARK: - Remote

    @ViewBuilder private func remote(narrow: Bool) -> some View {
        GroupLabel(text: Strings.settingsRemote)
        settingRow(Strings.settingsMode, narrow: narrow) {
            SegmentedRow(options: RemoteMode.allCases.map { ($0.title, $0) },
                         selection: binding(\.mode))
                .accessibilityIdentifier("settings-remote-mode")
        }
        settingRow(Strings.settingsBackend, narrow: narrow) {
            SegmentedRow(options: RemoteBackendChoice.allCases.map { ($0.title, $0) },
                         selection: binding(\.backend))
                .accessibilityIdentifier("settings-remote-backend")
        }
        settingRow(Strings.settingsPlacement, narrow: narrow) {
            SegmentedRow(options: [(Strings.settingsPlacementLeft, RemotePlacement.left), (Strings.settingsPlacementRight, .right),
                                   (Strings.settingsPlacementAbove, .above), (Strings.settingsPlacementBelow, .below)],
                         selection: binding(\.placement))
                .accessibilityIdentifier("settings-remote-placement")
        }
        settingRow(Strings.settingsTouchMode, narrow: narrow) {
            SegmentedRow(options: [(Strings.settingsTouchDirect, false), (Strings.settingsTouchTouchpad, true)],
                         selection: Binding(get: { relativeTouchpad },
                                            set: { relativeTouchpad = $0
                                                   NativePointerPreference.save(relativeTouchpad: $0) }))
                .accessibilityIdentifier("settings-remote-touch-mode")
        }
        SquareToggleRow(title: Strings.quickHostAudio, identifier: "settings-host-audio",
                        detail: Strings.settingsHostAudioDetail,
                        isOn: Binding(get: { preferences.hostAudioPlayback },
                                      set: { preferences.hostAudioPlayback = $0; preferences.save() }))
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
        // MENU-2 / A-67. The picture answers the host bar's own two icons, so
        // a hidden bar is the one case with nothing on the picture to press.
        SquareToggleRow(title: Strings.settingsCornerHandle, identifier: "settings-corner-handle",
                        detail: Strings.settingsCornerHandleDetail,
                        isOn: Binding(get: { preferences.cornerHandleWhenBarHidden },
                                      set: { preferences.cornerHandleWhenBarHidden = $0; preferences.save() }))
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
    }

    // MARK: - STREAM-1: the stream's own preset

    /// Two rows of three: the host's three named rows, then the three ways of
    /// not picking one of them yourself. Each shows its numbers as the host
    /// publishes them; nothing here holds a copy of the table.
    @ViewBuilder private func stream(narrow: Bool) -> some View {
        GroupLabel(text: Strings.settingsStream)
        note(Strings.settingsStreamDetail)
        settingRow(Strings.settingsStreamPreset, detail: streamDetail, narrow: narrow) {
            VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                SegmentedRow(options: [RemoteStreamPreset.performance, .balanced, .quality].map { ($0.title, $0) },
                             selection: streamBinding(\.preset))
                    .accessibilityIdentifier("settings-stream-preset-named")
                SegmentedRow(options: [RemoteStreamPreset.host, .auto, .custom].map { ($0.title, $0) },
                             selection: streamBinding(\.preset))
                    .accessibilityIdentifier("settings-stream-preset-other")
            }
        }
        if remote.streamChoice.preset == .custom {
            settingRow(Strings.settingsStreamFrameRate, narrow: narrow) {
                SegmentedRow(options: customFrameRates.map { ("\($0) fps", $0) }, // non-copy: a measurement
                             selection: streamBinding(\.customFPS))
                    .accessibilityIdentifier("settings-stream-custom-fps")
            }
            settingRow(Strings.settingsStreamBitrate, narrow: narrow) {
                StepSlider(value: streamBinding(\.customBitrateKbps), range: customBitrateRange, step: 1_000,
                           format: { "\($0 / 1_000) Mbps" }, // non-copy: a measurement
                           label: Strings.settingsStreamBitrate, identifier: "settings-stream-custom-bitrate")
            }
        }
    }

    private var customFrameRates: [Int] { remote.hostPreferences?.custom?.fps ?? [30, 60] }
    private var customBitrateRange: ClosedRange<Int> {
        let custom = remote.hostPreferences?.custom
        return (custom?.min_bitrate_kbps ?? 4_000)...(custom?.max_bitrate_kbps ?? 40_000)
    }

    /// What the selected row means on this host, in its own numbers.
    private var streamDetail: String {
        let choice = remote.streamChoice
        if choice.preset == .auto { return Strings.settingsStreamAutoDetail }
        let plan = RemoteRatePlan.resolve(choice, tier: .quality, host: remote.hostPreferences)
        let rates = "\(plan.fps) fps · \(plan.bitrateKbps / 1_000) Mbps" // non-copy: a measurement
        guard choice.preset == .host else { return rates }
        let name = remote.hostPreferences?.preset.flatMap { RemoteStreamPreset(rawValue: $0)?.title }
        return name.map { Strings.streamHostDefaultIs($0) + " " + rates } ?? rates
    }

    private func streamBinding<Value: Equatable>(_ path: WritableKeyPath<RemoteStreamChoice, Value>) -> Binding<Value> {
        Binding(get: { remote.streamChoice[keyPath: path] }, set: { value in
            var next = remote.streamChoice
            next[keyPath: path] = value
            remote.setStreamChoice(next)
        })
    }

    // MARK: - A-64 / N-37: the picture's gestures

    /// Four rows, each naming the host row it is an alias of — or saying that
    /// the host has no such row, which is the whole of N-37. Nothing here is a
    /// switch: a gesture is not a preference, it is a binding the host owns.
    @ViewBuilder private var gestures: some View {
        GroupLabel(text: Strings.gestureSection)
        note(Strings.gestureSectionNote)
        ForEach(remote.gestureBindings.bindings, id: \.gesture) { binding in
            ValueLine(name: binding.gesture.title, value: binding.resolution,
                      identifier: "settings-gesture-\(binding.gesture.rawValue)")
                .opacity(binding.row == nil ? 0.45 : 1)
                .disabled(binding.row == nil)
        }
        // A-62: the fifth gesture is this device's own and never travels.
        ValueLine(name: RemotePictureGesture.keyboard.title, value: Strings.gestureKeyboardLocal,
                  identifier: "settings-gesture-1")
        // A-64 rev 5 / review #23: the four-finger row is deleted because
        // iPadOS owns it, and the three-finger ones still share a device with
        // the multitasking gestures. This is a sentence, not a switch — the app
        // cannot turn a system setting off.
        note(Strings.settingsMultitaskingGestures)
    }

    // MARK: - N-38's switches

    @ViewBuilder private var barEntries: some View {
        GroupLabel(text: Strings.settingsBarEntries)
        note(Strings.settingsBarEntriesNote)
        ForEach(registry.entries) { entry in
            HStack(spacing: OmodachiTheme.space("lg")) {
                Glyph(entry.icon)
                    .foregroundStyle(OmodachiTheme.text)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(OmodachiTheme.font("subtitle"))
                        .foregroundStyle(OmodachiTheme.text)
                    if !entry.canDisable {
                        Text(Strings.settingsBarEntryLocked)
                            .font(OmodachiTheme.bodyFont("body-small"))
                            .foregroundStyle(OmodachiTheme.tertiaryText)
                    }
                }
                Spacer(minLength: OmodachiTheme.space("lg"))
                SquareToggle(isOn: Binding(get: { entry.enabled },
                                           set: { registry.setEnabled(entry.id, $0) }),
                             label: Strings.settingsBarEntryLabel(entry.title),
                             identifier: "settings-entry-\(entry.id.rawValue)-toggle")
                    .opacity(entry.canDisable ? 1 : 0.45)
                    .disabled(!entry.canDisable)
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(minHeight: RowHeight.line)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-entry-\(entry.id.rawValue)")
        }
    }

    // MARK: - Keybindings (CLIP-1 §1)

    /// Five of this host's 227 bindings — `Universal copy`, `Universal paste`,
    /// `Universal cut`, `Zoom in`, `Reset zoom` — are bound to Lua functions
    /// that Omarchy's own record format cannot carry, so the host publishes no
    /// executable binding for them and nothing here can ever run one. They are
    /// left out of the list rather than greyed in it. This switch puts them
    /// back for somebody who wants to see what the computer has.
    @ViewBuilder private var keybindings: some View {
        GroupLabel(text: Strings.panelKeybindings)
        SquareToggleRow(title: Strings.settingsShowUnrunnable,
                        identifier: "settings-show-unrunnable",
                        detail: Strings.settingsShowUnrunnableDetail,
                        isOn: Binding(get: { preferences.showsUnrunnableKeybindings },
                                      set: { preferences.showsUnrunnableKeybindings = $0; preferences.save() }))
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
    }

    // MARK: - Clipboard (CLIP-1 §2)

    /// This device's half of the clipboard switch. Like the approval switch
    /// above it, the host has its own, and the narrower of the two is what
    /// happens — so this page says what the host is set to as well, because
    /// "nothing is happening" with no explanation is the failure this shape is
    /// meant to avoid.
    @ViewBuilder private func clipboard(narrow: Bool) -> some View {
        GroupLabel(text: Strings.settingsClipboard)
        settingRow(Strings.settingsClipboardDirection,
                   detail: Strings.settingsClipboardDetail, narrow: narrow) {
            SegmentedRow(options: [(Strings.settingsClipboardOff, ClipboardSyncChoice.off),
                                   (Strings.settingsClipboardOneWay, .hostToDevice),
                                   (Strings.settingsClipboardBoth, .both)],
                         selection: Binding(get: { preferences.clipboardSync },
                                            set: { preferences.clipboardSync = $0
                                                   preferences.save()
                                                   home.clipboard.setDeviceMode($0) }))
                .accessibilityIdentifier("settings-clipboard-sync")
        }
        if preferences.clipboardSync == .both {
            note(Strings.settingsClipboardPasteBanner)
            // iOS grants a pasteboard read that follows a tap and refuses one
            // that follows a scene activation, so this is the control that
            // always works — and the only place in the app that asks for the
            // clipboard rather than waiting for it.
            TextTap(Strings.settingsClipboardSend, bordered: true) {
                home.clipboard.pushRequested()
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .accessibilityIdentifier("settings-clipboard-send")
        }
        // Two counters and nothing else. "Is it working" is the question this
        // page cannot answer any other way — the text itself is never shown
        // here, and showing it would be the one thing a clipboard must not do.
        if home.clipboard.effective != .off {
            ValueLine(name: Strings.settingsClipboardMoved,
                      value: Strings.settingsClipboardCounts(Format.count(home.clipboard.received),
                                                             Format.count(home.clipboard.sent)),
                      identifier: "settings-clipboard-counts")
        }
        if !home.clipboard.supported {
            note(Strings.settingsClipboardHostUnsupported)
        } else if home.clipboard.waitingOnTheOtherSwitch {
            note(Strings.settingsClipboardHostOff)
        }
        if let failure = home.clipboard.failure {
            InlineError(message: failure, identifier: "settings-clipboard-error")
        }
    }

    // MARK: - This device

    @ViewBuilder private func device(narrow: Bool) -> some View {
        GroupLabel(text: Strings.settingsDevice)
        settingRow(Strings.settingsBadge, narrow: narrow) {
            SegmentedRow(options: BarBadgeStyle.allCases.map { ($0.title, $0) },
                         selection: Binding(get: { preferences.badgeStyle },
                                            set: { preferences.badgeStyle = $0; preferences.save() }))
                .accessibilityIdentifier("settings-badge-style")
        }
        settingRow(Strings.settingsBarEdge, detail: Strings.settingsBarEdgeDetail, narrow: narrow) {
            SegmentedRow(options: [(Strings.settingsPlacementLeft, HostBarPosition.left), (Strings.settingsPlacementRight, .right)],
                         selection: Binding(get: { preferences.barEdges.portrait },
                                            set: { preferences.barEdges.choose($0); preferences.save() }))
                .accessibilityIdentifier("settings-bar-edge")
        }
    }

    // MARK: - Host approval (AUTH-1)

    /// This device's half of AUTH-1's two switches. It says what it does and
    /// what it does not: turning it on here registers a key with the host, and
    /// the host still has to have its own switch on before anything is ever
    /// asked of this device.
    @ViewBuilder private var approval: some View {
        GroupLabel(text: Strings.settingsApproval)
        if !home.approvals.biometry.isAvailable {
            note(Strings.settingsApprovalNoBiometry)
        } else if !home.approvals.supported {
            note(Strings.settingsApprovalUnsupported)
        } else {
            SquareToggleRow(title: Strings.settingsApprovalToggle,
                            identifier: "settings-approval-toggle",
                            detail: Strings.settingsApprovalDetail,
                            isOn: Binding(get: { home.approvals.deviceEnabled },
                                          set: { home.approvals.setDeviceEnabled($0) }))
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .padding(.vertical, OmodachiTheme.space("xl"))
                .disabled(home.approvals.busy)
            if home.approvals.deviceEnabled && !home.approvals.hostEnabled {
                note(Strings.settingsApprovalHostOff)
            }
            if let failure = home.approvals.failure {
                InlineError(message: failure, identifier: "settings-approval-error")
            }
            GroupLabel(text: Strings.settingsApprovalKeys)
            if home.approvals.registered == nil && home.approvals.otherKeys.isEmpty {
                note(Strings.settingsApprovalNone)
            }
            ForEach(([home.approvals.registered].compactMap { $0 }) + home.approvals.otherKeys) { key in
                ValueLine(name: key.label, value: keyDetail(key),
                          identifier: "settings-approval-key-\(key.deviceID)")
            }
        }
    }

    /// Where the private half lives, and whether the device's own switch is on.
    /// A key in a simulator's keychain is not a key in a Secure Enclave, and
    /// the row says which it is rather than letting the reader assume.
    private func keyDetail(_ key: HostApprovalKeys.Key) -> String {
        let place = key.secureEnclave ? Strings.settingsApprovalEnclave : Strings.settingsApprovalKeychain
        return key.enabled ? place : place + " · " + Strings.settingsApprovalOff
    }

    // MARK: - Diagnostics (UX-3 §2)

    /// What this device recorded about its own connections, verbatim.
    ///
    /// Two rounds were spent on failures whose only evidence lived in `log
    /// show` on a Mac the iPad was not attached to. The traces were already
    /// being written; they simply could not be read from the device that was
    /// failing. So they are printed here, and copied with one tap.
    ///
    /// It is the device's half of the pair: the host has its journal, this is
    /// the other end of the same attempt, and the two line up by timestamp.
    ///
    /// The transcripts are read when this page is drawn, not observed. A page
    /// that repainted on every trace line would be a page nobody could read a
    /// line off, and the thing a person does here is open ⑥ *after* the
    /// failure and copy what is there.
    @ViewBuilder private var diagnostics: some View {
        GroupLabel(text: Strings.settingsDiagnostics)
        note(Strings.settingsDiagnosticsDetail)
        if let identity = home.approvals.hostKnownDeviceID {
            ValueLine(name: Strings.settingsApproval, value: identity,
                      identifier: "settings-diagnostics-identity")
        }
        sshKeyPair
        StreamDiagnosticsLine(monitor: remote.streamMonitor)
        DiagnosticBlock(title: Strings.settingsDiagnosticsSsh,
                        text: SSHConnectionTrace.transcript.transcript,
                        copyTitle: Strings.settingsDiagnosticsCopy,
                        copiedTitle: Strings.settingsDiagnosticsCopied,
                        emptyTitle: Strings.settingsDiagnosticsEmpty,
                        identifier: "settings-diagnostics-ssh")
        DiagnosticBlock(title: Strings.settingsDiagnosticsApproval,
                        text: ApprovalTrace.transcript.transcript,
                        copyTitle: Strings.settingsDiagnosticsCopy,
                        copiedTitle: Strings.settingsDiagnosticsCopied,
                        emptyTitle: Strings.settingsDiagnosticsEmpty,
                        identifier: "settings-diagnostics-approval")
    }

    /// UX-4 §2. The two halves of one key, printed together.
    ///
    /// They were always readable — one with `ssh-keygen -lf` on the computer,
    /// the other nowhere at all — and never in the same place, so a device
    /// offering a key the host had never seen looked exactly like a device
    /// whose key had been refused. Two lines say which it is at a glance, and
    /// the host's line is red when it is not this device's key.
    @ViewBuilder private var sshKeyPair: some View {
        if let sshKey {
            ValueLine(name: Strings.settingsDiagnosticsKeyLocal, value: sshKey.localFingerprint,
                      identifier: "settings-diagnostics-key-local")
            ValueLine(name: Strings.settingsDiagnosticsKeyHost,
                      value: sshKey.hostFingerprints.last ?? Strings.settingsDiagnosticsKeyNone,
                      identifier: "settings-diagnostics-key-host",
                      wrong: !sshKey.matches)
            if !sshKey.matches { note(Strings.settingsDiagnosticsKeyMismatch) }
        } else if sshKeyUnread {
            note(Strings.settingsDiagnosticsKeyUnread)
        }
    }

    /// The host is asked once per appearance of this page; it is one
    /// authenticated GET that starts nothing and changes nothing.
    private func readSSHKey() async {
        let account = home.profile.companionURL
        guard !account.isEmpty, !home.profile.mock else { return }
        let keyAccount = home.profile.keyAccount
        do {
            sshKey = try await SSHKeyOffer().read(account: account, keyAccount: keyAccount)
            sshKeyUnread = false
        } catch {
            sshKey = nil
            sshKeyUnread = true
        }
    }

    // MARK: - About

    /// STORE-2 §4 and DISTRIBUTION.md: which release this is, what licence it
    /// is under and where its source is. None of it depends on a host, so it
    /// is here in the demo as well.
    @ViewBuilder private var about: some View {
        GroupLabel(text: Strings.settingsAbout)
        ValueLine(name: Strings.settingsVersion, value: BuildStamp.versionLine, identifier: "settings-version")
        ValueLine(name: Strings.settingsBuild, value: BuildStamp.summary, identifier: "setup.buildStamp")
        ValueLine(name: Strings.settingsContract, value: "omodachi.v1", identifier: "settings-contract")
        Row(title: Strings.settingsLicence, detail: Strings.settingsLicenceDetail,
            icon: licenceOpen ? Icon.chevronUp : Icon.chevronDown, selected: licenceOpen,
            identifier: "settings-licence") {
            licenceOpen.toggle()
        }
        if licenceOpen {
            LicencePage()
        }
        Row(title: Strings.settingsSourceCode, detail: LicenceNotice.sourceURL.absoluteString,
            icon: Icon.chevronRight, identifier: "settings-source-code") {
            openURL(LicenceNotice.sourceURL)
        }
        Row(title: Strings.settingsPrivacy, detail: LicenceNotice.privacyURL.absoluteString,
            icon: Icon.chevronRight, identifier: "settings-privacy") {
            openURL(LicenceNotice.privacyURL)
        }
    }

    // MARK: - Pieces

    private func binding<Value: Equatable>(_ path: WritableKeyPath<RemotePreferences, Value>) -> Binding<Value> {
        Binding(get: { remotePreferences[keyPath: path] }, set: { value in
            remotePreferences[keyPath: path] = value
            remotePreferences.save()
        })
    }

    /// A-56 rev 4b: on a narrow column the label goes above the control and the
    /// control is left-aligned under it. Nothing else changes.
    @ViewBuilder private func settingRow<Control: View>(_ title: String, detail: String? = nil,
                                                        narrow: Bool,
                                                        @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            Text(title)
                .font(OmodachiTheme.font("subtitle"))
                .foregroundStyle(OmodachiTheme.text)
            if let detail {
                Text(detail)
                    .font(OmodachiTheme.bodyFont("body-small"))
                    .foregroundStyle(OmodachiTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control()
                .frame(maxWidth: narrow ? .infinity : 420, alignment: .leading)
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.vertical, OmodachiTheme.space("xl"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont("body-small"))
            .foregroundStyle(OmodachiTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.vertical, OmodachiTheme.space("xl"))
    }
}

/// STREAM-1 §3. The running stream's last second, in one line. It observes the
/// monitor on its own so that nothing else on ⑥ redraws once a second.
private struct StreamDiagnosticsLine: View {
    @ObservedObject var monitor: RemoteStreamMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("sm")) {
            Text(Strings.settingsDiagnosticsStream)
                .font(OmodachiTheme.font("subtitle"))
                .foregroundStyle(OmodachiTheme.text)
            Text(verbatim: monitor.line ?? Strings.settingsDiagnosticsStreamIdle)
                .font(OmodachiTheme.bodyFont("body-small"))
                .foregroundStyle(OmodachiTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-diagnostics-stream")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.vertical, OmodachiTheme.space("xl"))
    }
}

/// N-29. One host, two things you can do to it. It opens inside ⑥ rather than
/// over it (A-55).
struct HostDetailView: View {
    @EnvironmentObject private var home: HomeStore
    let record: PairedHostRecord
    @ObservedObject var directory: PairedHostDirectory
    /// `true` when the host was forgotten, so ⑥ can go where review item 16
    /// says: the next paired host, or the unpaired first screen.
    var onDone: (Bool) -> Void

    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let observed = home.certificateChange?.observed, let pinned = home.certificateChange?.pinned {
                GroupLabel(text: Strings.settingsPinnedAt)
                FingerprintText(fingerprint: pinned, color: OmodachiTheme.tertiaryText)
                GroupLabel(text: Strings.settingsPresentedNow)
                FingerprintText(fingerprint: observed, color: OmodachiTheme.danger)
                InlineConfirm(title: Strings.settingsTrustCertificate, confirmTitle: Strings.settingsTrustCertificateConfirm,
                              identifier: "settings-trust-certificate") {
                    Task { await home.trustRotatedCertificate() }
                }
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                FlowRule()
            }
            GroupLabel(text: Strings.settingsRevoke)
            note(Strings.settingsRevokeOnHost(RemoteSessionController.pairedDeviceID() ?? "<device>")) // non-copy: a placeholder id
            InlineConfirm(title: Strings.settingsForget, confirmTitle: Strings.settingsForgetConfirm,
                          kind: .danger, identifier: "settings-forget-host") { forget() }
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
            if let message { note(message) }
        }
        .padding(.bottom, OmodachiTheme.space("xxl"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host-detail")
    }

    private func forget() {
        // PAIR-4 §2: one implementation, shared with the host list's inline
        // row, so the two can never delete different things — and the record
        // goes whatever the Keychain says, because a Keychain that refuses
        // must not be able to rebuild the dead end that spec is about.
        let complete = HostForget.run(account: record.account, directory: directory)
        PanelPinStore().forget(hostID: home.hostPin?.hostID ?? record.account)
        if HostAccount.canonical(home.profile.companionURL) == HostAccount.canonical(record.account) {
            var profile = home.profile
            profile.companionURL = ""
            home.profile = profile
            Task { await home.disconnectCompanion() }
        }
        guard complete else {
            message = Strings.settingsForgetPartial
            return
        }
        onDone(true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont("body-small"))
            .foregroundStyle(OmodachiTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.vertical, OmodachiTheme.space("xl"))
    }
}
