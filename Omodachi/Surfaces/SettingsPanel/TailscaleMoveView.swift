import SwiftUI

/// TAIL-3b L03 / L03b / L04, opened in place under a Wi-Fi host's road
/// sentence in ⑥. The name is prefilled from what the host told this device
/// (L03); without one, the two set-up steps come first (L03b). The switch
/// happens only after the name answers as this host.
struct TailscaleMoveView: View {
    @ObservedObject var model: TailscaleMoveModel
    let onDone: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool
    @State private var tailscaleUp = TailscaleAddress.isUp
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Strings.moveTitle(model.hostName))
                .font(OmodachiTheme.font("subtitle"))
                .foregroundStyle(OmodachiTheme.text)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .accessibilityIdentifier("move-title")
            if model.state == .done {
                StatusLine(text: Strings.moveDone(model.hostName), kind: .ok, identifier: "move-done")
            } else {
                note(Strings.moveBody(model.hostName))
                if model.knownName != nil {
                    note(Strings.moveKnown(model.hostName))
                } else {
                    note(Strings.moveUnknown(model.hostName))
                    NumberedStep(number: 1, text: Strings.tsStep1)
                    NumberedStep(number: 2, text: Strings.tsStep2(DeviceWord.current), linkTitle: Strings.tsStep2Get,
                            linkIdentifier: "move-appstore") { openURL(TailscaleAddress.appStoreURL) }
                }
                NameField(text: $model.input, focused: $focused, fieldIdentifier: "move-field", pasteIdentifier: "move-paste",
                          onSubmit: go) { value in if let value { model.input = value } }
                    .padding(.top, 4)
                StatusLine(text: tailscaleUp ? Strings.tsHereYes(DeviceWord.current) : Strings.tsHereNo(DeviceWord.current),
                           kind: tailscaleUp ? .ok : .warn, identifier: "move-here")
                outcome
                HStack(spacing: 8) {
                    FlowButton(title: Strings.moveGo, enabled: !model.running
                               && !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: go)
                        .accessibilityIdentifier("move-go")
                    FlowButton(title: Strings.actionCancel, kind: .ghost, action: onCancel)
                        .accessibilityIdentifier("move-cancel")
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("move-tailscale")
        .onAppear { tailscaleUp = TailscaleAddress.isUp }
    }

    @ViewBuilder private var outcome: some View {
        switch model.state {
        case .checking(let name):
            StatusLine(text: Strings.moveChecking(name, model.hostName), kind: .next, identifier: "move-checking")
        case .notSame(let name):
            StatusLine(text: Strings.moveNotSame(name, model.hostName), kind: .error, identifier: "move-failed")
        case .noAnswer(let name):
            StatusLine(text: Strings.moveNoAnswer(name, model.hostName), kind: .error, identifier: "move-failed")
        case .problem(let resolution):
            if let words = Self.words(resolution) {
                StatusLine(text: words, kind: .error, identifier: "move-failed")
            }
        case .idle, .done:
            EmptyView()
        }
    }

    static func words(_ resolution: TailscaleResolution) -> String? {
        switch resolution {
        case .notTailscale(let name): Strings.errNotTailscaleTitle(name)
        case .noName(let name): Strings.errNoNameTitle(name)
        case .noPtr(let address): Strings.errNoPtrTitle(address)
        case .empty, .resolving, .resolved: nil
        }
    }

    private func go() {
        focused = false
        Task {
            if await model.run() { onDone() }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont("body-small"))
            .foregroundStyle(OmodachiTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}
