// lint:host-words — the demo PTY writes what a shell would write; it is
// terminal output, not app copy.
import Foundation

/// MainActor owns transport lifetime; byte streams preserve partial UTF-8/ANSI.
@MainActor protocol PTYTransport: AnyObject {
    var output: AsyncThrowingStream<Data, Error> { get }
    func connect(cols: Int, rows: Int) async throws
    func send(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func disconnect() async
}
extension SSHTransport: PTYTransport {}

@MainActor final class MockPTYTransport: PTYTransport {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let kind: TerminalKind
    private var connected = false
    private var cols = 80
    private var rows = 24
    private var tab = 1
    private var panes = 1
    private var zoom = false
    private var prefixed = false
    private var input = Data()

    init(kind: TerminalKind = .shell) {
        self.kind = kind
        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        output = stream.stream
        continuation = stream.continuation
    }
    func connect(cols: Int, rows: Int) async throws {
        connected = true
        self.cols = cols; self.rows = rows
        draw()
    }
    func send(_ data: Data) async throws {
        guard connected else { throw SSHTransportError.notConnected }
        // Synthetic keyboard echo only: no shell, process, or host actions.
        for byte in data {
            if prefixed {
                prefixed = false
                switch byte {
                case 118, 45: panes = min(4, panes + 1); draw()
                case 99: tab += 1; draw()
                case 110: tab += 1; draw()
                case 112: tab = max(1, tab - 1); draw()
                case 122: zoom.toggle(); draw()
                case 113: await disconnect()
                default: break
                }
            } else if byte == 2 { prefixed = true }
            else if byte == 13 {
                emit("\r\nDemo received \(input.count) UTF-8 bytes.\r\n❯ ")
                input.removeAll(keepingCapacity: true)
            } else if byte == 127 {
                if !input.isEmpty { input.removeLast(); emit("\u{8} \u{8}") }
            } else if byte == 3 { input.removeAll(); emit("^C\r\n❯ ") }
            else { input.append(byte); continuation.yield(Data([byte])) }
        }
    }
    func resize(cols: Int, rows: Int) async throws {
        guard connected else { throw SSHTransportError.notConnected }
        self.cols = cols; self.rows = rows
        draw()
    }
    func disconnect() async { connected = false; continuation.finish() }
    private func draw() {
        emit("\u{1b}[2J\u{1b}[H\u{1b}[38;5;214mOMODACHI · DEMO\u{1b}[0m\r\n")
        switch kind {
        case .agent:
            emit("Agent: default · simulated terminal\r\nNo host or agent task is running.\r\n\r\n")
        case .herdr:
            emit("Herdr · workspace demo · tab \(tab)\r\nPanes \(panes)\(zoom ? " · zoomed" : "") · \(cols)×\(rows)\r\n")
            for n in 1...panes { emit("┌─ demo-pane-\(n) ───────────────────┐\r\n│ Interactive shell               │\r\n└─────────────────────────────────┘\r\n") }
            emit("\r\n")
        case .command: emit("Menu terminal · simulated command\r\nNothing was installed or changed.\r\n\r\n")
        case .shell: emit("Shell · simulated PTY · \(cols)×\(rows)\r\n\r\n")
        }
        emit("中文输入 / Unicode ✓\r\nType to test input. Return home keeps this session.\r\n❯ ")
        if !input.isEmpty { continuation.yield(input) }
    }
    private func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
}
