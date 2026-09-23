import AVFoundation
import Foundation

/// The microphone, as 48 kHz s16le mono in 960-sample frames.
///
/// That is the host's contract, not a choice made here: core's virtual
/// microphone is `module-null-sink` + `module-remap-source` and it refuses a
/// begin frame whose format is anything else (`omodachi-core/docs/voice.md`,
/// `audio_input_format_unsupported`). SPEC-G2 §2 says 16 kHz; the host says 48,
/// and the host is the one holding the source.
///
/// The conversion path is the Remote uplink's: an `AVAudioEngine` tap in the
/// route's own format, an `AVAudioConverter` into the target format, and a
/// carry buffer so only whole 1920-byte frames ever leave. What differs is that
/// nothing here is duplex — there is no stream being played back — so there is
/// no echo-cancellation requirement and no headphones gate.
///
/// Route changes and interruptions stop the capture and say so. They never
/// resume it: a microphone that comes back on its own after a phone call is a
/// microphone the user did not turn on.
final class VoiceCapture: NSObject, @unchecked Sendable {
    enum Stop: String, Sendable {
        case user
        case routeChanged = "route_changed"
        case interrupted
        case sessionError = "audio_session_error"
        case conversionFailed = "conversion_failed"
        case inputUnavailable = "input_unavailable"
        case transportClosed = "transport_closed"
    }

    static let frameBytes = 1920
    static let frameSamples: AVAudioFrameCount = 960
    static let sampleRate: Double = 48_000

    private let lock = NSLock()
    private let onFrame: @Sendable (Data, UInt64) -> Bool
    private let onStop: @Sendable (Stop) -> Void
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var carry = Data()
    private var sequence: UInt64 = 0
    private var capturing = false
    private var routeSignature: String?
    private var observers: [NSObjectProtocol] = []

    /// `onFrame` returns channel viability, exactly as the transport does: false
    /// means stop capturing. It never means the frame was delivered.
    init(onFrame: @escaping @Sendable (Data, UInt64) -> Bool,
         onStop: @escaping @Sendable (Stop) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
        super.init()
    }

    /// Asks for permission without opening a device. A denial is an answer, not
    /// an error to retry behind the user's back.
    static func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    func start() -> Stop? {
        lock.lock()
        defer { lock.unlock() }
        guard !capturing else { return nil }
        let session = AVAudioSession.sharedInstance()
        do {
            // `.mixWithOthers` keeps whatever else the app is playing alive;
            // dictation is not a reason to silence a Remote stream.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch { return .sessionError }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { return .inputUnavailable }
        self.engine = engine
        self.converter = converter
        carry = Data()
        sequence = 0
        capturing = true
        routeSignature = Self.route()

        input.installTap(onBus: 0, bufferSize: Self.frameSamples, format: source) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            capturing = false
            self.engine = nil
            return .sessionError
        }
        observe()
        return nil
    }

    func stop(_ reason: Stop) {
        let engine: AVAudioEngine?
        lock.lock()
        engine = self.engine
        let wasCapturing = capturing
        capturing = false
        self.engine = nil
        converter = nil
        carry = Data()
        let watching = observers
        observers = []
        lock.unlock()

        for observer in watching { NotificationCenter.default.removeObserver(observer) }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // The session is handed back so other audio is not left in a recording
        // category after one sentence.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if wasCapturing, reason != .user { onStop(reason) }
    }

    var isCapturing: Bool { lock.withLock { capturing } }

    // MARK: - Internals

    private func observe() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
                guard let self else { return }
                // A new microphone mid-sentence is a different microphone. The
                // recording stops and says so rather than continuing quietly
                // from somewhere else.
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                switch reason {
                case .newDeviceAvailable, .oldDeviceUnavailable, .override, .categoryChange:
                    if self.routeSignature != Self.route() { self.stop(.routeChanged) }
                default: break
                }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                // No `.shouldResume` handling on purpose: this never comes back
                // on its own.
                self.stop(.interrupted)
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
                self?.stop(.sessionError)
            },
        ]
    }

    private static func route() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        return (route.inputs.map(\.uid) + ["→"] + route.outputs.map(\.uid)).joined(separator: ",")
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard capturing, let converter else { lock.unlock(); return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard capacity <= 16_384,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            lock.unlock(); return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let channel = output.int16ChannelData else {
            lock.unlock()
            stop(.conversionFailed)
            return
        }
        channel[0].withMemoryRebound(to: UInt8.self, capacity: Int(output.frameLength) * 2) { bytes in
            carry.append(bytes, count: Int(output.frameLength) * 2)
        }
        var frames: [(Data, UInt64)] = []
        while carry.count >= Self.frameBytes {
            let frame = carry.prefix(Self.frameBytes)
            carry.removeFirst(Self.frameBytes)
            frames.append((Data(frame), sequence))
            sequence += 1
        }
        lock.unlock()
        for (frame, ordinal) in frames where !onFrame(frame, ordinal) {
            stop(.transportClosed)
            return
        }
    }
}
