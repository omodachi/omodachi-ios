import Foundation

/// A loopback RFB 3.8 server that behaves the way WayVNC 0.10.1 behaves on a
/// scale-2 owned output, measured against the real host in SPEC-E3 §3:
///
/// ```
/// ServerInit       : 1280x882            <- the compositor's logical size
/// update 0: 1 rect : 1280x882   raw
/// update 1: 2 rects: 2560x1764  NewFBSize <- corrected to the buffer pixels
///                    2560x1764  raw
/// update 2: 1 rect : 2560x1764  raw
/// ```
///
/// It exists so the client half of REMOTE-6 — following that mid-stream resize
/// without dropping the session, and mapping a touch correctly at *both* sizes
/// — is checked on every run rather than only when a real host is free. It
/// speaks only the part of RFB the vendored LibVNCClient uses: `None` security,
/// raw rectangles, and the `NewFBSize` pseudo-encoding.
///
/// Test peer only. Nothing here is production protocol, and it listens on
/// 127.0.0.1 with an ephemeral port that nothing outside this process learns.
final class FakeWayVNCServer: @unchecked Sendable {
    struct PointerEvent: Equatable {
        let x: Int
        let y: Int
        let buttons: Int
        /// The framebuffer size the server was serving when it arrived.
        let framebuffer: CGSize
    }

    private(set) var port: UInt16 = 0
    private let opening: CGSize
    private let native: CGSize
    private let resizeDelay: TimeInterval
    private let lock = NSLock()
    private var _pointers: [PointerEvent] = []
    private var _served: CGSize
    private var _clientClosed = false
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var thread: Thread?
    private var stopping = false

    /// `opening` is what `ServerInit` announces; `native` is what the server
    /// corrects itself to one update in. Passing the same size twice models a
    /// scale-1 output, where WayVNC never resizes at all.
    /// `resizeDelay` holds the correcting update back. The real WayVNC sends it
    /// immediately, which is its own case (the client never shows the opening
    /// size at all); a delay is how the intermediate state is made observable.
    init(opening: CGSize, native: CGSize, resizeDelay: TimeInterval = 0) {
        self.opening = opening
        self.native = native
        self.resizeDelay = resizeDelay
        self._served = opening
    }

    var pointerEvents: [PointerEvent] {
        lock.lock(); defer { lock.unlock() }
        return _pointers
    }

    var servedPixels: CGSize {
        lock.lock(); defer { lock.unlock() }
        return _served
    }

    var clientClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _clientClosed
    }

    // MARK: - lifecycle

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw Failure.socket }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: assigned.sin_port)
        listenFD = fd
        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "fake.wayvnc"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock(); stopping = true; lock.unlock()
        if clientFD >= 0 { shutdown(clientFD, SHUT_RDWR) }
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
    }

    enum Failure: Error { case socket }

    // MARK: - the session

    private func serve() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        clientFD = fd
        defer {
            close(fd)
            clientFD = -1
            lock.lock(); _clientClosed = true; lock.unlock()
        }
        guard handshake(fd) else { return }
        var requests = 0
        while !isStopping {
            guard let type = readBytes(fd, 1)?.first else { return }
            switch type {
            case 0: _ = readBytes(fd, 19)                      // SetPixelFormat
            case 2:                                            // SetEncodings
                guard let head = readBytes(fd, 3) else { return }
                let count = Int(head[1]) << 8 | Int(head[2])
                guard count <= 64, readBytes(fd, count * 4) != nil else { return }
            case 3:                                            // FramebufferUpdateRequest
                guard readBytes(fd, 9) != nil else { return }
                requests += 1
                guard sendUpdate(fd, ordinal: requests) else { return }
            case 4: _ = readBytes(fd, 7)                       // KeyEvent
            case 5:                                            // PointerEvent
                guard let body = readBytes(fd, 5) else { return }
                let event = PointerEvent(x: Int(body[1]) << 8 | Int(body[2]),
                                         y: Int(body[3]) << 8 | Int(body[4]),
                                         buttons: Int(body[0]), framebuffer: servedPixels)
                lock.lock(); _pointers.append(event); lock.unlock()
            case 6:                                            // ClientCutText
                guard let head = readBytes(fd, 7) else { return }
                let length = Int(head[3]) << 24 | Int(head[4]) << 16 | Int(head[5]) << 8 | Int(head[6])
                guard length <= 1 << 20, readBytes(fd, length) != nil else { return }
            default: return
            }
        }
    }

    private func handshake(_ fd: Int32) -> Bool {
        guard write(fd, Array("RFB 003.008\n".utf8)),
              readBytes(fd, 12) != nil,
              write(fd, [1, 1]),                               // one security type: None
              let chosen = readBytes(fd, 1), chosen[0] == 1,
              write(fd, [0, 0, 0, 0]),                         // SecurityResult: OK
              readBytes(fd, 1) != nil                          // ClientInit (shared flag)
        else { return false }
        var message = u16(Int(opening.width)) + u16(Int(opening.height))
        message += [32, 24, 0, 1]                              // bpp, depth, big-endian, true-colour
        message += u16(255) + u16(255) + u16(255)              // red/green/blue max
        message += [0, 8, 16, 0, 0, 0]                         // shifts + padding
        let name = Array("WayVNC".utf8)
        message += u32(name.count) + name
        return write(fd, message)
    }

    /// The whole point of this peer: update 1 carries a `NewFBSize` rect for
    /// the output's buffer pixels, exactly as WayVNC does, and everything after
    /// it is served at the new size.
    private func sendUpdate(_ fd: Int32, ordinal: Int) -> Bool {
        if ordinal == 1 {
            return write(fd, header(rects: 1) + rawRect(origin: .zero, size: opening))
        }
        if ordinal == 2, native != opening {
            if resizeDelay > 0 { Thread.sleep(forTimeInterval: resizeDelay) }
            lock.lock(); _served = native; lock.unlock()
            var message = header(rects: 2)
            message += rectHeader(x: 0, y: 0, width: Int(native.width), height: Int(native.height),
                                  encoding: -223)              // rfbEncodingNewFBSize
            return write(fd, message) && write(fd, rawRect(origin: .zero, size: native))
        }
        // Keep the stream alive without re-sending megabytes: a small opaque
        // patch at the origin, which the client folds into the frame it has.
        let served = servedPixels
        let patch = CGSize(width: min(32, served.width), height: min(32, served.height))
        return write(fd, header(rects: 1) + rawRect(origin: .zero, size: patch))
    }

    // MARK: - wire helpers

    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    private func header(rects: Int) -> [UInt8] { [0, 0] + u16(rects) }

    private func rectHeader(x: Int, y: Int, width: Int, height: Int, encoding: Int32) -> [UInt8] {
        let raw = UInt32(bitPattern: encoding)
        return u16(x) + u16(y) + u16(width) + u16(height)
            + [UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
    }

    private func rawRect(origin: CGPoint, size: CGSize) -> [UInt8] {
        rectHeader(x: Int(origin.x), y: Int(origin.y), width: Int(size.width), height: Int(size.height),
                   encoding: 0)
            + [UInt8](repeating: 0x40, count: Int(size.width) * Int(size.height) * 4)
    }

    private func u16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

    private func u32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return true }
            while sent < bytes.count {
                let written = send(fd, base + sent, bytes.count - sent, 0)
                if written <= 0 { return false }
                sent += written
            }
            return true
        }
    }

    private func readBytes(_ fd: Int32, _ count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var read = 0
        while read < count {
            let got = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + read, count - read, 0) }
            if got <= 0 { return nil }
            read += got
        }
        return buffer
    }
}
