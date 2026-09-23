import GameController
import SwiftTerm
import SwiftUI
import UIKit

/// The SSH surface (Study 01 §06, A-14).
///
/// N-07: SSH and Herdr share the transport idea and nothing else. Herdr has
/// pane, split, zoom and tab semantics and gets a control bar for them; SSH has
/// none of those, and a bar of invented controls here would be a lie. What SSH
/// does have is one real problem — a software keyboard cannot send Esc or hold
/// Ctrl — and the assist row solves exactly that.
struct TerminalSurface: View {
    let runtimeID: UUID
    var onHome: () -> Void = {}
    var onTogglePanel: () -> Void = {}
    var panelCollapsed = false
    var onSelectSession: (UUID) -> Void = { _ in }
    @EnvironmentObject private var sessions: SessionStore
    var body: some View {
        if let runtime = sessions.runtime(id: runtimeID) {
            TerminalContent(runtime: runtime, onHome: onHome, onTogglePanel: onTogglePanel,
                            panelCollapsed: panelCollapsed, onSelectSession: onSelectSession)
        } else {
            EmptyState(title: Strings.sshUnavailable, identifier: "ssh-session-gone")
        }
    }
}

private struct TerminalContent: View {
    @ObservedObject var runtime: TerminalRuntime
    var onHome: () -> Void
    var onTogglePanel: () -> Void
    var panelCollapsed: Bool
    var onSelectSession: (UUID) -> Void
    @EnvironmentObject private var sessions: SessionStore
    @State private var closing = false

    private var siblings: [TerminalRuntime] {
        sessions.runtimes.filter { $0.descriptor.host == runtime.descriptor.host }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The study's §06 board draws one session; this strip is how a
            // second one is reached, and it is the only thing on this surface
            // that is not the terminal or the assist row.
            sessionStrip
            titleRow
            if runtime.descriptor.host.mock {
                Text(Strings.sshDemo).font(OmodachiTheme.font("caption"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .frame(maxWidth: .infinity).padding(4)
            }
            NativeTerminalRepresentable(runtime: runtime,
                                        appearanceRevision: OmodachiTheme.appearanceRevision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if let error = runtime.errorMessage {
                HStack {
                    Glyph(symbol: "exclamationmark.triangle")
                    Text(error).font(OmodachiTheme.font("caption"))
                    Spacer()
                    Tap(action: { runtime.dismissError() }) { Glyph(symbol: "xmark") }.accessibilityLabel(Strings.sshDismissError)
                }.padding(10).background(OmodachiTheme.warning.opacity(0.12))
            }
            // §2: a reconnect opens a new shell, and input is never replayed
            // into it. The button says which of the two this would be.
            if runtime.state != .connected && runtime.state != .connecting {
                HStack {
                    Text(runtime.descriptor.reattachable ? Strings.sshHostSessionMayRun : Strings.sshReconnectOpensNew)
                        .font(OmodachiTheme.font("caption")).foregroundStyle(OmodachiTheme.secondaryText)
                    Spacer()
                    // UX-1 item 9: this was `` —
                    // a stock blue capsule with a corner radius, in an app whose
                    // every other control is a zero-radius bordered rectangle.
                    FlowButton(title: runtime.descriptor.reattachable ? Strings.sshReattach : Strings.sshReconnect,
                               enabled: !(runtime.descriptor.kind == .command && runtime.connectionCount > 0)) {
                        // UX-3 §2: a tap is a person, so it clears the ladder.
                        runtime.connect(explicit: true, asked: true)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("terminal-reattach")
                }.padding(10)
            }
            if runtime.showTouchKeys { SSHModifierRow(runtime: runtime) }
        }
        .background(OmodachiTheme.background)
        .onAppear {
            runtime.onHome = onHome
            runtime.showTouchKeys = GCKeyboard.coalesced == nil
            runtime.activate()
        }
        // §2: leaving the surface keeps the connection. Only the keyboard is
        // given back — the session belongs to SessionStore, not to this view.
        .onDisappear { runtime.terminal.resignFirstResponder() }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in runtime.showTouchKeys = false }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in runtime.showTouchKeys = true }
        .confirmationDialog(Strings.sshCloseConfirm, isPresented: $closing, titleVisibility: .visible) {
            TextTap(Strings.sshClose, destructive: true) { Task { await sessions.remove(runtime); onHome() } }
        } message: { Text(Strings.sshCloseDetail) }
    }

    /// §3: `user@host` is this surface's name, and the size and state are the
    /// two facts a terminal has that nothing else can tell you.
    private var titleRow: some View {
        HStack {
            Text(runtime.descriptor.host.mock ? Strings.sshDemoLabel : runtime.descriptor.endpointLabel)
                .font(OmodachiTheme.font("body-small", weight: .semibold))
                .foregroundStyle(OmodachiTheme.accent).lineLimit(1)
                .accessibilityIdentifier("terminal-endpoint")
            Text(runtime.descriptor.targetLabel).font(OmodachiTheme.font("caption"))
                .accessibilityIdentifier("terminal-target")
                .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                .foregroundStyle(OmodachiTheme.secondaryText)
            Spacer(minLength: 0)
            Text(Strings.sshSize(Format.count(runtime.columns), Format.count(runtime.rows))).font(OmodachiTheme.font("caption"))
                .accessibilityIdentifier("terminal-size")
            Rectangle().fill(runtime.state == .connected ? OmodachiTheme.success : OmodachiTheme.warning)
                .frame(width: 6, height: 6)
            Text(runtime.state.label).font(OmodachiTheme.font("caption"))
                .accessibilityIdentifier("terminal-state")
            // A-55 deleted the navigation bar this pair used to live in, and a
            // `.toolbar` outside a navigation container draws nothing — which
            // is how the modifier row became unreachable on a simulator with a
            // hardware keyboard. They are part of the panel now.
            Tap(action: {
                if runtime.terminal.isFirstResponder { runtime.terminal.resignFirstResponder() }
                else { runtime.terminal.becomeFirstResponder() }
            }) { Glyph(Icon.keyboard) }
                .accessibilityLabel(Strings.sshToggleKeyboard)
                .accessibilityIdentifier("terminal-keyboard")
            Menu {
                TextTap(Strings.sshPaste, systemImage: "doc.on.clipboard") { runtime.terminal.paste(nil) }
                TextTap(Strings.sshCopy, systemImage: "doc.on.doc") { runtime.terminal.copy(nil) }
                TextTap(Strings.sshSelectAll, systemImage: "selection.pin.in.out") { runtime.terminal.selectAll(nil) }
                TextTap(Strings.sshTextLarger, systemImage: "textformat.size.larger") { runtime.fontSize = min(26, runtime.fontSize + 1) }
                TextTap(Strings.sshTextSmaller, systemImage: "textformat.size.smaller") { runtime.fontSize = max(10, runtime.fontSize - 1) }
                TextTap(runtime.showTouchKeys ? Strings.sshModifierRowHide : Strings.sshModifierRowShow) {
                    runtime.showTouchKeys.toggle()
                }
                .accessibilityIdentifier("terminal-modifier-row")
                TextTap(Strings.sshDisconnect, systemImage: "network.slash") { Task { await runtime.disconnect() } }
                TextTap(Strings.sshClose, destructive: true) { closing = true }
            } label: {
                Glyph(symbol: "ellipsis.circle")
                    .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("terminal-options")
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .frame(height: NativeBarMetrics.hit)
        .background(OmodachiTheme.background)
    }

    private var sessionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                ForEach(siblings) { item in
                    Tap(action: { onSelectSession(item.id) }) {
                        HStack(spacing: 5) {
                            Glyph(symbol: "terminal")
                            Text(item.descriptor.displayTitle)
                        }
                        .font(OmodachiTheme.font("caption"))
                        .padding(.horizontal, OmodachiTheme.space("lg"))
                        .frame(height: OmodachiTheme.controlHeight)
                    }
                    .control(selected: item.id == runtime.id, bordered: true)
                    .frame(height: NativeBarMetrics.hit)
                    .accessibilityIdentifier("session-\(item.id)")
                }
            }.padding(.horizontal, OmodachiTheme.space("sm"))
        }
        .frame(height: NativeBarMetrics.hit)
        .background(OmodachiTheme.background)
    }
}

struct NativeTerminalRepresentable: UIViewRepresentable {
    let runtime: TerminalRuntime
    /// §3: see `HerdrTerminalRepresentable` — the revision is what makes a
    /// host theme or font change reach a UIKit view inside SwiftUI.
    var appearanceRevision: Int = 0
    func makeUIView(context: Context) -> NativeTerminalView { runtime.terminal }
    func updateUIView(_ view: NativeTerminalView, context: Context) {
        runtime.applyAppearance()
    }
    static func dismantleUIView(_ view: NativeTerminalView, coordinator: ()) { view.resignFirstResponder() }
}

/// A-14. Esc, Ctrl, Alt, Tab and the four arrows — the keys a software keyboard
/// cannot produce — and nothing else. 44 high with 28-high controls inside it
/// (A-01), and Ctrl/Alt **latch**: one tap locks, a second releases, because a
/// finger cannot hold two keys at once.
struct SSHModifierRow: View {
    @ObservedObject var runtime: TerminalRuntime

    /// The keys, in the study's order, with the bytes each sends.
    static let keys: [(String, [UInt8])] = [
        ("esc", [27]), ("⇥", [9]), // non-copy: key caps
        ("←", [27, 91, 68]), ("↓", [27, 91, 66]), ("↑", [27, 91, 65]), ("→", [27, 91, 67])
    ]

    var body: some View {
        // Eight 44-wide hit areas are wider than an iPhone's usable width once
        // the bar has taken its edge, so the row scrolls rather than pushing
        // the terminal off screen.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OmodachiTheme.space("xs")) {
                key("esc", [27]) // non-copy: key caps
                latch("ctrl", on: runtime.ctrl) { runtime.ctrl.toggle(); runtime.terminal.becomeFirstResponder() } // non-copy: key caps
                latch("alt", on: runtime.alt) { runtime.alt.toggle(); runtime.terminal.becomeFirstResponder() } // non-copy: key caps
                key("⇥", [9])
                key("←", [27, 91, 68]); key("↓", [27, 91, 66]); key("↑", [27, 91, 65]); key("→", [27, 91, 67])
            }
            .padding(.horizontal, OmodachiTheme.space("xs"))
        }
        .frame(height: NativeBarMetrics.hit)
        .frame(maxWidth: .infinity)
        .background(OmodachiTheme.barBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(OmodachiTheme.border)
                .frame(height: NativeBarMetrics.edgeRule).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ssh-modifier-row")
    }

    private func key(_ label: String, _ bytes: [UInt8]) -> some View {
        Tap(bordered: true, fill: OmodachiTheme.normalFill, action: { runtime.key(bytes) }) {
            Text(label).font(OmodachiTheme.font("body-small"))
                .padding(.horizontal, OmodachiTheme.space("md"))
        }
            .frame(minWidth: NativeBarMetrics.hit, minHeight: NativeBarMetrics.hit)
            .accessibilityLabel(label)
            .accessibilityIdentifier("ssh-key-\(label)")
    }

    private func latch(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Tap(selected: on, bordered: true, fill: OmodachiTheme.normalFill, action: action) {
            Text(label).font(OmodachiTheme.font("body-small"))
                .padding(.horizontal, OmodachiTheme.space("md"))
        }
            .frame(minWidth: NativeBarMetrics.hit, minHeight: NativeBarMetrics.hit)
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? [.isSelected] : [])
            .accessibilityIdentifier("ssh-key-\(label)")
    }
}
