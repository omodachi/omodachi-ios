import Combine
import Foundation
import UIKit

/// CLIP-1's device half: two switches, one pasteboard, and as few reads of it
/// as the feature can be built with.
///
/// The shape is AUTH-1's. The host's `clipboard_sync` says what this computer
/// is willing to share; `ShellPreferences.clipboardSync` says what this device
/// is willing to do; and the **narrower of the two** is what happens. Neither
/// side can turn the other on, and either side can turn everything off.
///
/// Two asymmetries are iOS's, not ours, and they shape the whole object:
///
/// * **Reading the pasteboard costs the user a tap.** Since iOS 16 reading
///   `UIPasteboard.general.string` for content the app did not put there raises
///   a system *Allow Paste* alert, and it is only readable at all while the app
///   is in front. So this device pushes when it comes to the front and at no
///   other time, and it does not even look at the pasteboard unless
///   `changeCount` says something has been copied since it last did — one
///   alert per actual copy, never one per app switch. Settings ⑥ says this in
///   words, because an alert nobody was warned about is alarming.
/// * **Writing it is silent.** So the host's direction is the cheap one: an
///   event arrives, the text is fetched, the pasteboard is set, and nothing is
///   shown.
///
/// The text is not kept. `lastSeen` is a 64-bit FNV-1a digest plus a length —
/// enough to recognise the same clipboard twice, and not enough to be a copy of
/// it — and it exists only so that what this device just pulled is not pushed
/// straight back, and what it just pushed does not arrive as news.
protocol ClipboardServing: Sendable {
    func fetchClipboard() async throws -> String
    @discardableResult func putClipboard(_ text: String) async throws -> Int
    func fetchClipboardMode() async throws -> String
}

extension CompanionHostClient: ClipboardServing {}

/// The pasteboard, behind a protocol, so the rules above can be tested without
/// a device and without a system banner.
@MainActor protocol DevicePasteboard {
    var changeCount: Int { get }
    var hasStrings: Bool { get }
    func read() -> String?
    func write(_ text: String)
}

@MainActor struct SystemPasteboard: DevicePasteboard {
    var changeCount: Int { UIPasteboard.general.changeCount }
    var hasStrings: Bool { UIPasteboard.general.hasStrings }
    func read() -> String? { UIPasteboard.general.string }
    func write(_ text: String) { UIPasteboard.general.string = text }
}

@MainActor
final class ClipboardSyncCoordinator: ObservableObject {
    /// The host's half, as last read from `GET /v1/preferences`.
    @Published private(set) var hostMode = ClipboardSyncChoice.off
    /// This device's half. ⑥ writes it; it is stored in `ShellPreferences`.
    @Published private(set) var deviceMode = ClipboardSyncChoice.off
    /// False when the host does not have CLIP-1 at all. ⑥ says "this host does
    /// not share its clipboard" rather than drawing a switch that does nothing.
    @Published private(set) var supported = false
    /// The host's own words for its last refusal, or nil.
    @Published private(set) var failure: String?
    /// What has moved since this connection came up: two counters and nothing
    /// else, so ⑥ can show that it is working without showing what moved.
    @Published private(set) var received = 0
    @Published private(set) var sent = 0

    private let pasteboard: any DevicePasteboard
    private var service: (any ClipboardServing)?
    private var work: Task<Void, Never>?
    private var lastSeen: String?
    private var lastChangeCount: Int?
    /// The app is in front and has not yet had a chance to push. Coming back
    /// from the background *reconnects*, and a reconnect resets `hostMode` to
    /// off until `GET /v1/preferences` answers — so the moment the app is in
    /// front and the moment it knows whether it may push are not the same
    /// moment. Without this the push was simply dropped, every time.
    private var pushWhenAllowed = false

    /// What actually happens: the narrower of the two switches.
    var effective: ClipboardSyncChoice {
        switch (hostMode, deviceMode) {
        case (.off, _), (_, .off): .off
        case (.both, .both): .both
        default: .hostToDevice
        }
    }

    /// True when one side is on and the other is not, which is the one state a
    /// person needs told: nothing is happening, and it is not a fault.
    var waitingOnTheOtherSwitch: Bool {
        (deviceMode != .off && hostMode == .off && supported)
            || (deviceMode == .both && hostMode == .hostToDevice)
    }

    init(pasteboard: any DevicePasteboard = SystemPasteboard()) {
        self.pasteboard = pasteboard
    }

    // MARK: - Wiring

    func attach(service: (any ClipboardServing)?, deviceMode: ClipboardSyncChoice) {
        self.service = service
        self.deviceMode = deviceMode
        guard service != nil else { return }
        Task { await refresh() }
    }

    func detach() {
        service = nil
        work?.cancel()
        work = nil
        hostMode = .off
        supported = false
        failure = nil
        lastSeen = nil
        lastChangeCount = nil
        pushWhenAllowed = false
        received = 0
        sent = 0
    }

    /// ⑥ moved this device's switch. Turning it on is also the moment to find
    /// out what the host says, so the page can answer "why is nothing
    /// happening" without the person having to reconnect.
    func setDeviceMode(_ mode: ClipboardSyncChoice) {
        deviceMode = mode
        guard mode != .off else { return }
        Task { await refresh() }
    }

    /// Read the host's half back. Cheap, and the only place `supported` moves.
    func refresh() async {
        guard let service else { return }
        do {
            let mode = try await service.fetchClipboardMode()
            supported = true
            failure = nil
            hostMode = ClipboardSyncChoice(hostValue: mode)
            // Now that both halves are known, a push the app owed since it came
            // to the front can happen.
            push()
        } catch let error as ClipboardHostError {
            failure = error.userMessage
        } catch {
            // A host from before CLIP-1 has no `clipboard_sync` in its
            // preferences, which decodes as absent and reads as off — it is not
            // an error to show anybody. Anything else is the connection, and
            // the connection has its own reporting.
            supported = false
            hostMode = .off
        }
    }

    // MARK: - The host's direction

    /// `clipboard.changed` arrived. The text is not in the event, so this is
    /// where it is asked for.
    func hostClipboardChanged() {
        guard effective.reads, let service else { return }
        work?.cancel()
        work = Task { [weak self] in
            do {
                let text = try await service.fetchClipboard()
                guard let self, !Task.isCancelled, !text.isEmpty else { return }
                let digest = Self.digest(text)
                guard digest != lastSeen else { return }
                lastSeen = digest
                pasteboard.write(text)
                // Writing moves `changeCount`, and what this device just
                // received is not something to push back to where it came from.
                lastChangeCount = pasteboard.changeCount
                received += 1
                failure = nil
                ClipboardTrace.received(bytes: text.utf8.count)
            } catch let error as ClipboardHostError {
                ClipboardTrace.failed("receive", code: error.code)
                self?.failure = error.userMessage
            } catch {
                return
            }
        }
    }

    // MARK: - This device's direction

    /// The app came to the front, which on iOS is the only moment the
    /// pasteboard can be read at all. Nothing is read unless `changeCount`
    /// says somebody copied something since the last time, so opening the app
    /// twice in a row does not produce two paste banners.
    func appBecameActive() {
        pushWhenAllowed = true
        push()
    }

    /// The person pressed Send in ⑥.
    ///
    /// This is not the same act as coming to the front, and iOS treats it
    /// differently: a read that follows a tap is one it will grant (with its
    /// own *Allow Paste* alert), where a read from a scene activation is one it
    /// silently refuses — `clipboard.push stopped reason=read_refused`, which
    /// is what a whole round of this spec's acceptance walk found. So the
    /// automatic attempt stays, because it costs nothing and works for content
    /// this app itself copied, and this is the button that always works.
    func pushRequested() {
        pushWhenAllowed = true
        lastChangeCount = nil
        push()
    }

    /// One push, if this device owes one and both switches allow it.
    private func push() {
        guard pushWhenAllowed else { return ClipboardTrace.pushStopped("nothing_owed") }
        guard effective.writes else { return ClipboardTrace.pushStopped("switch_off") }
        guard let service else { return ClipboardTrace.pushStopped("not_connected") }
        pushWhenAllowed = false
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return ClipboardTrace.pushStopped("nothing_copied") }
        lastChangeCount = count
        guard pasteboard.hasStrings else { return ClipboardTrace.pushStopped("no_text") }
        guard let text = pasteboard.read(), !text.isEmpty else {
            return ClipboardTrace.pushStopped("read_refused")
        }
        let encoded = Data(text.utf8)
        guard encoded.count <= CompanionHostClient.clipboardLimit else {
            failure = ReasonText.message("clipboard_too_large", domain: .host, status: 413)
            return ClipboardTrace.pushStopped("too_large")
        }
        let digest = Self.digest(text)
        guard digest != lastSeen else { return ClipboardTrace.pushStopped("already_there") }
        lastSeen = digest
        Task { [weak self] in
            do {
                try await service.putClipboard(text)
                guard let self, !Task.isCancelled else { return }
                sent += 1
                failure = nil
                ClipboardTrace.pushed(bytes: encoded.count)
            } catch let error as ClipboardHostError {
                ClipboardTrace.failed("push", code: error.code)
                // A refusal is not a delivery: forget the digest, so that
                // turning the other switch on does not strand this text.
                self?.failure = error.userMessage
                self?.lastSeen = nil
            } catch {
                self?.lastSeen = nil
            }
        }
    }

    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Data(text.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16) + ":" + String(text.utf8.count)
    }
}

extension ClipboardSyncChoice {
    /// core's wire value. An answer this build does not know reads as off: a
    /// mode nobody here implements must not be taken for permission.
    init(hostValue: String) {
        switch hostValue {
        case "host_to_device": self = .hostToDevice
        case "both": self = .both
        default: self = .off
        }
    }
}
