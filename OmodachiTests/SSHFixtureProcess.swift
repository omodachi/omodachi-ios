import Darwin
import Foundation
import XCTest

/// Starts and stops `Tools/SSHFixture/server.py` from inside the test process so
/// `xcodebuild test` is green without a separately launched fixture.
///
/// `Foundation.Process` is unavailable on iOS, but a Simulator test bundle is an
/// ordinary macOS process, so `posix_spawn` works and the host filesystem is
/// reachable. Readiness is a real TCP connect to the fixture port, never a log
/// scrape. If another process already holds the port the fixture is assumed to
/// be running (the way `Tools/SSHFixture/run-tests.sh` starts it) and is left
/// alone: this never kills a process it did not start.
/// The fixture is started once for the suite and stopped once, because
/// restarting it between every test races the listening socket.
enum SSHFixtureProcess {
    static let port: Int32 = 22222
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: Handle?

    /// `<repo>/OmodachiTests/SSHFixtureProcess.swift` -> `<repo>`.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var serverScript: URL { repositoryRoot.appendingPathComponent("Tools/SSHFixture/server.py") }
    private static var requirements: URL { repositoryRoot.appendingPathComponent("Tools/SSHFixture/requirements.txt") }
    private static var bootstrapVenv: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMODACHI_FIXTURE_VENV"] ?? "/tmp/omodachi-ssh-fixture-venv", isDirectory: true)
    }

    struct Handle {
        fileprivate let pid: pid_t?
        /// Stops only a fixture this process spawned.
        fileprivate func stop() {
            guard let pid else { return }
            kill(pid, SIGTERM)
            var status: Int32 = 0
            for _ in 0..<400 {
                if waitpid(pid, &status, WNOHANG) > 0 { break }
                usleep(25_000)
            }
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, WNOHANG)
            // The listening socket is only certainly gone once the port refuses.
            for _ in 0..<200 where accepts(port: SSHFixtureProcess.port) { usleep(25_000) }
        }
    }

    /// Idempotent. Throws `XCTSkip` only when no usable python3 can be found or
    /// bootstrapped; call it from every test's setUp.
    static func startShared() throws {
        lock.lock()
        defer { lock.unlock() }
        guard running == nil else { return }
        running = try start()
    }

    static func stopShared() {
        lock.lock()
        defer { lock.unlock() }
        running?.stop()
        running = nil
    }

    private static func start() throws -> Handle {
        if accepts(port: port) { return Handle(pid: nil) }
        guard FileManager.default.fileExists(atPath: serverScript.path) else {
            throw XCTSkip("SSH fixture script missing at \(serverScript.path); loopback integration was not validated")
        }
        guard let interpreter = try usableInterpreter() else {
            throw XCTSkip("No python3 with asyncssh was found and one could not be created at \(bootstrapVenv.path); loopback SSH integration was not validated. Install python3 or run Tools/SSHFixture/run-tests.sh.")
        }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("omodachi-ssh-fixture-\(UUID().uuidString).log")
        guard let pid = spawn(interpreter, [serverScript.path], stdoutPath: log.path) else {
            throw XCTSkip("Could not spawn \(interpreter); loopback SSH integration was not validated")
        }
        let handle = Handle(pid: pid)
        for _ in 0..<300 {
            if accepts(port: port) { return handle }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) > 0 {
                let output = (try? String(contentsOf: log, encoding: .utf8)) ?? "(no output at \(log.path))"
                XCTFail("SSH fixture exited before accepting connections on \(port). Output:\n\(output)")
                return Handle(pid: nil)
            }
            usleep(50_000)
        }
        handle.stop()
        XCTFail("SSH fixture never accepted a connection on 127.0.0.1:\(port)")
        return Handle(pid: nil)
    }

    // MARK: - Interpreter discovery

    private static func usableInterpreter() throws -> String? {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["OMODACHI_FIXTURE_PYTHON"] { candidates.append(explicit) }
        candidates.append(bootstrapVenv.appendingPathComponent("bin/python3").path)
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        if let ready = candidates.first(where: { hasAsyncSSH($0) }) { return ready }
        guard let base = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return bootstrap(using: base)
    }

    private static func hasAsyncSSH(_ interpreter: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: interpreter) else { return false }
        return run(interpreter, ["-c", "import asyncssh"]) == 0
    }

    /// Creates the pinned virtualenv. Needs network the first time only.
    private static func bootstrap(using interpreter: String) -> String? {
        let venvPython = bootstrapVenv.appendingPathComponent("bin/python3").path
        if !FileManager.default.isExecutableFile(atPath: venvPython) {
            guard run(interpreter, ["-m", "venv", bootstrapVenv.path]) == 0 else { return nil }
        }
        guard run(venvPython, ["-m", "pip", "--quiet", "--disable-pip-version-check", "install", "-r", requirements.path]) == 0 else { return nil }
        return hasAsyncSSH(venvPython) ? venvPython : nil
    }

    // MARK: - posix_spawn helpers

    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        guard let pid = spawn(executable, arguments, stdoutPath: "/dev/null") else { return -1 }
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) != -1 else { return -1 }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    }

    private static func spawn(_ executable: String, _ arguments: [String], stdoutPath: String) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 1, stdoutPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, nil, &argv, environ)
        return result == 0 ? pid : nil
    }

    // MARK: - Readiness

    private static func accepts(port: Int32) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
