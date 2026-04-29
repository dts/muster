import Foundation
import Darwin
import MusterShellProtocol

public enum ShellHostError: Error {
    case helperNotFound
    case spawnFailed(Int32)
    case connectFailed(Int32)
    case handshakeFailed(String)
    case versionMismatch(expected: String, got: String)
    case attachFailed(String)
    case disconnected
}

public struct AttentionEvent: Sendable {
    public enum Kind: Sendable {
        case exited(code: Int32)
    }
    public let sessionId: UUID
    public let kind: Kind

    public init(sessionId: UUID, kind: Kind) {
        self.sessionId = sessionId
        self.kind = kind
    }
}

public struct ShellSession: Sendable {
    public let sessionId: UUID
    public let output: AsyncStream<Data>
    public let resumed: Bool
    public let exitedCode: Int32?

    private let _send: @Sendable (Data) -> Void
    private let _resize: @Sendable (UInt16, UInt16) -> Void
    private let _detach: @Sendable () -> Void
    private let _kill: @Sendable () -> Void

    init(
        sessionId: UUID,
        output: AsyncStream<Data>,
        resumed: Bool,
        exitedCode: Int32?,
        send: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (UInt16, UInt16) -> Void,
        detach: @escaping @Sendable () -> Void,
        kill: @escaping @Sendable () -> Void
    ) {
        self.sessionId = sessionId
        self.output = output
        self.resumed = resumed
        self.exitedCode = exitedCode
        self._send = send
        self._resize = resize
        self._detach = detach
        self._kill = kill
    }

    public func send(_ data: Data) { _send(data) }
    public func resize(cols: UInt16, rows: UInt16) { _resize(cols, rows) }
    public func detach() { _detach() }
    public func kill() { _kill() }
}

public actor ShellHostClient {
    public static let shared = ShellHostClient()

    public nonisolated let events: AsyncStream<AttentionEvent>
    private nonisolated let eventContinuation: AsyncStream<AttentionEvent>.Continuation

    private var connection: ClientConnection?
    private var connectTask: Task<ClientConnection, Error>?
    private var sessions: [UUID: SessionState] = [:]
    private var pendingHello: CheckedContinuation<HelloAck, Error>?
    private var pendingAttach: [UUID: CheckedContinuation<AttachAck, Error>] = [:]

    private struct SessionState {
        let outputContinuation: AsyncStream<Data>.Continuation
    }

    private init() {
        var cont: AsyncStream<AttentionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { c in cont = c }
        self.eventContinuation = cont
    }

    public func attach(
        checkoutId: UUID,
        cwd: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        cols: UInt16 = 80,
        rows: UInt16 = 24
    ) async throws -> ShellSession {
        let conn = try await ensureConnected()

        // P0.2 fix: finish prior outputContinuation before overwriting
        if let prior = sessions.removeValue(forKey: checkoutId) {
            prior.outputContinuation.finish()
        }

        var streamCont: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { c in
            streamCont = c
        }
        sessions[checkoutId] = SessionState(outputContinuation: streamCont)

        let req = Attach(
            sessionId: checkoutId,
            cols: cols,
            rows: rows,
            cwd: cwd,
            env: env,
            shell: nil
        )
        let payload = try WireCodec.encode(req)
        conn.send(frame: Frame(type: .attach, payload: payload))

        // P0.1 fix: resume any existing continuation before overwriting
        if let existing = pendingAttach.removeValue(forKey: checkoutId) {
            existing.resume(throwing: ShellHostError.attachFailed("superseded"))
        }

        let ack = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AttachAck, Error>) in
            pendingAttach[checkoutId] = cont
        }

        return ShellSession(
            sessionId: checkoutId,
            output: stream,
            resumed: ack.resumed,
            exitedCode: ack.exitedCode,
            send: { [weak self] data in
                Task { await self?.write(sessionId: checkoutId, data: data) }
            },
            resize: { [weak self] cols, rows in
                Task { await self?.resizeSession(sessionId: checkoutId, cols: cols, rows: rows) }
            },
            detach: { [weak self] in
                Task { await self?.detachSession(sessionId: checkoutId) }
            },
            kill: { [weak self] in
                Task { await self?.killSession(sessionId: checkoutId) }
            }
        )
    }

    private func write(sessionId: UUID, data: Data) {
        guard let conn = connection else { return }
        let bulk = BulkPayload(sessionId: sessionId, bytes: data)
        conn.send(frame: Frame(type: .input, payload: bulk.encode()))
    }

    private func resizeSession(sessionId: UUID, cols: UInt16, rows: UInt16) {
        guard let conn = connection else { return }
        let req = Resize(sessionId: sessionId, cols: cols, rows: rows)
        guard let p = try? WireCodec.encode(req) else { return }
        conn.send(frame: Frame(type: .resize, payload: p))
    }

    private func detachSession(sessionId: UUID) {
        guard let conn = connection else { return }
        let req = Detach(sessionId: sessionId)
        guard let p = try? WireCodec.encode(req) else { return }
        conn.send(frame: Frame(type: .detach, payload: p))
        if let s = sessions.removeValue(forKey: sessionId) {
            s.outputContinuation.finish()
        }
    }

    private func killSession(sessionId: UUID) {
        guard let conn = connection else { return }
        let req = Kill(sessionId: sessionId)
        guard let p = try? WireCodec.encode(req) else { return }
        conn.send(frame: Frame(type: .kill, payload: p))
    }

    /// Force the helper to quit. Sessions will be lost. Used for version-mismatch recovery.
    public func quitHelper() async {
        guard let conn = connection else { return }
        if let p = try? WireCodec.encode(Quit()) {
            conn.send(frame: Frame(type: .quit, payload: p))
        }
        connection = nil
        for (_, s) in sessions {
            s.outputContinuation.finish()
        }
        sessions.removeAll()
    }

    // MARK: - Connection management

    private func ensureConnected() async throws -> ClientConnection {
        if let c = connection { return c }
        if let task = connectTask {
            return try await task.value
        }
        let task = Task<ClientConnection, Error> {
            try await connect()
        }
        connectTask = task
        do {
            let c = try await task.value
            connection = c
            connectTask = nil
            return c
        } catch {
            connectTask = nil
            throw error
        }
    }

    private func connect() async throws -> ClientConnection {
        let socketPath = ShellHostPaths.socketPath()

        // Try to connect to existing socket
        if let conn = try? openConnection(path: socketPath) {
            try await handshake(connection: conn)
            return conn
        }

        // Spawn helper, wait for socket, retry
        try spawnHelper(socketPath: socketPath)

        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            if let conn = try? openConnection(path: socketPath) {
                try await handshake(connection: conn)
                return conn
            }
        }

        throw ShellHostError.connectFailed(ETIMEDOUT)
    }

    private func openConnection(path: String) throws -> ClientConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw ShellHostError.connectFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= cap else {
            Darwin.close(fd)
            throw ShellHostError.connectFailed(ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, src.count)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result < 0 {
            let e = errno
            Darwin.close(fd)
            throw ShellHostError.connectFailed(e)
        }

        let conn = ClientConnection(socketFd: fd)
        conn.onFrame = { [weak self] frame in
            Task { await self?.handleFrame(frame) }
        }
        conn.onClose = { [weak self] in
            Task { await self?.handleDisconnect() }
        }
        conn.start()
        return conn
    }

    private func handshake(connection: ClientConnection) async throws {
        let hello = Hello()
        guard let payload = try? WireCodec.encode(hello) else {
            throw ShellHostError.handshakeFailed("encode")
        }
        connection.send(frame: Frame(type: .hello, payload: payload))

        // P0.1 fix: resume any existing continuation before overwriting
        pendingHello?.resume(throwing: ShellHostError.handshakeFailed("superseded"))

        let ack = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HelloAck, Error>) in
            self.pendingHello = cont
        }
        if ack.protocolVersion != BuildStamp.protocolVersion {
            throw ShellHostError.versionMismatch(
                expected: "protocol \(BuildStamp.protocolVersion)",
                got: "protocol \(ack.protocolVersion)"
            )
        }
    }

    private func spawnHelper(socketPath: String) throws {
        guard let helperURL = locateHelper() else {
            throw ShellHostError.helperNotFound
        }
        let helperPath = helperURL.path

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let args = [helperPath, "--serve", "--socket", socketPath]
        let argvStrings = args.map { strdup($0)! }
        defer { for p in argvStrings { free(p) } }
        var argvPtrs: [UnsafeMutablePointer<CChar>?] = argvStrings.map { Optional($0) }
        argvPtrs.append(nil)

        let envStrings = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)")! }
        defer { for p in envStrings { free(p) } }
        var envPtrs: [UnsafeMutablePointer<CChar>?] = envStrings.map { Optional($0) }
        envPtrs.append(nil)

        var pid: pid_t = 0
        let result = posix_spawn(&pid, helperPath, nil, &attr, argvPtrs, envPtrs)
        if result != 0 {
            throw ShellHostError.spawnFailed(result)
        }
    }

    private func locateHelper() -> URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "MusterShellHost") {
            return url
        }
        // Fallback: alongside the main executable
        if let exe = Bundle.main.executableURL {
            let candidate = exe.deletingLastPathComponent().appendingPathComponent("MusterShellHost")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Frame dispatch

    private func handleFrame(_ frame: Frame) {
        switch frame.type {
        case .helloAck:
            if let ack = try? WireCodec.decode(HelloAck.self, from: frame.payload) {
                pendingHello?.resume(returning: ack)
                pendingHello = nil
            }

        case .attachAck:
            if let ack = try? WireCodec.decode(AttachAck.self, from: frame.payload) {
                if let cont = pendingAttach.removeValue(forKey: ack.sessionId) {
                    cont.resume(returning: ack)
                }
            }

        case .output:
            if let bulk = BulkPayload.decode(frame.payload),
               let s = sessions[bulk.sessionId] {
                s.outputContinuation.yield(bulk.bytes)
            }

        case .exit:
            if let ev = try? WireCodec.decode(ExitEvent.self, from: frame.payload) {
                eventContinuation.yield(AttentionEvent(sessionId: ev.sessionId, kind: .exited(code: ev.code)))
                if let s = sessions.removeValue(forKey: ev.sessionId) {
                    s.outputContinuation.finish()
                }
            }

        case .errorMessage:
            if let err = try? WireCodec.decode(ErrorMessage.self, from: frame.payload) {
                if let sid = err.sessionId, let cont = pendingAttach.removeValue(forKey: sid) {
                    cont.resume(throwing: ShellHostError.attachFailed(err.message))
                }
            }

        default:
            break
        }
    }

    private func handleDisconnect() {
        connection = nil
        pendingHello?.resume(throwing: ShellHostError.disconnected)
        pendingHello = nil
        for (_, cont) in pendingAttach {
            cont.resume(throwing: ShellHostError.disconnected)
        }
        pendingAttach.removeAll()
        for (_, s) in sessions {
            s.outputContinuation.finish()
        }
        sessions.removeAll()
    }
}

public enum ShellHostPaths {
    public static func appSupportDir() -> String {
        let home = NSHomeDirectory()
        let dir = "\(home)/Library/Application Support/Muster"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func socketPath() -> String {
        return "\(appSupportDir())/shell-host.sock"
    }
}
