import Foundation
import Darwin
import MusterShellProtocol

protocol SessionClient: AnyObject {
    var id: ObjectIdentifier { get }
    var isFocused: Bool { get set }
    func send(frame: Frame)
}

final class Session {
    let sessionId: UUID
    let pty: PTY
    let queue: DispatchQueue
    let createdAt: Date

    private let ringBuffer = RingBuffer()
    private let parser = AttentionParser()
    private var clients: [ObjectIdentifier: WeakClientRef] = [:]
    private(set) var exitedCode: Int32?
    private(set) var unreadBells: Int = 0
    private(set) var currentTitle: String?

    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    private var onExit: ((Session) -> Void)?

    init(sessionId: UUID, pty: PTY, onExit: @escaping (Session) -> Void) {
        self.sessionId = sessionId
        self.pty = pty
        self.queue = DispatchQueue(label: "muster.shell.session.\(sessionId)")
        self.createdAt = Date()
        self.onExit = onExit
        startReadLoop()
        startProcessWatch()
    }

    private func startReadLoop() {
        let src = DispatchSource.makeReadSource(fileDescriptor: pty.masterFd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.drainPTY()
        }
        src.resume()
        readSource = src
    }

    private func startProcessWatch() {
        let src = DispatchSource.makeProcessSource(
            identifier: pty.pid,
            eventMask: .exit,
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleChildExit()
        }
        src.resume()
        procSource = src
    }

    private func drainPTY() {
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                return read(pty.masterFd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                let chunk = Data(bytes: buf, count: n)
                ringBuffer.append(chunk)
                parser.feed(chunk)
                broadcastOutput(chunk)
                dispatchEvents()
            } else if n == 0 {
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                return
            }
        }
    }

    private func handleChildExit() {
        var status: Int32 = 0
        _ = waitpid(pty.pid, &status, WNOHANG)
        let code: Int32
        if (status & 0x7f) == 0 {
            code = (status >> 8) & 0xff
        } else {
            code = -(status & 0x7f)
        }
        exitedCode = code

        // Drain any final bytes
        drainPTY()

        // Tell clients
        let exitEvent = ExitEvent(sessionId: sessionId, code: code)
        if let payload = try? WireCodec.encode(exitEvent) {
            broadcast(frame: Frame(type: .exit, payload: payload))
        }

        readSource?.cancel()
        procSource?.cancel()
        close(pty.masterFd)

        onExit?(self)
        onExit = nil
    }

    // Public API — must be called on `queue`

    func attach(_ client: SessionClient) {
        clients[client.id] = WeakClientRef(client)

        // Send AttachAck
        let ack = AttachAck(sessionId: sessionId, resumed: ringBuffer.count > 0, exitedCode: exitedCode)
        if let payload = try? WireCodec.encode(ack) {
            client.send(frame: Frame(type: .attachAck, payload: payload))
        }

        // Replay buffered output
        let snapshot = ringBuffer.snapshot
        if !snapshot.isEmpty {
            let bulk = BulkPayload(sessionId: sessionId, bytes: snapshot)
            client.send(frame: Frame(type: .output, payload: bulk.encode()))
        }

        // Replay current title if known
        if let title = currentTitle, let p = try? WireCodec.encode(TitleChangedEvent(sessionId: sessionId, title: title)) {
            client.send(frame: Frame(type: .titleChanged, payload: p))
        }
    }

    func detach(_ client: SessionClient) {
        clients.removeValue(forKey: client.id)
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var off = 0
            while off < data.count {
                let n = Darwin.write(pty.masterFd, base + off, data.count - off)
                if n > 0 {
                    off += n
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    continue
                } else {
                    return
                }
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        resizePTY(masterFd: pty.masterFd, cols: cols, rows: rows)
    }

    /// Politely terminates the shell. We try SIGTERM, escalate to SIGKILL after a grace period.
    func kill() {
        sendSignal(pid: pty.pid, signal: SIGTERM)
        let pid = pty.pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            // If still alive, escalate
            if Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    func markRead() {
        unreadBells = 0
    }

    var info: SessionInfo {
        SessionInfo(sessionId: sessionId, pid: pty.pid, exitedCode: exitedCode)
    }

    // Internal helpers

    private func compactClients() {
        clients = clients.filter { $0.value.target != nil }
    }

    private func broadcastOutput(_ data: Data) {
        compactClients()
        let bulk = BulkPayload(sessionId: sessionId, bytes: data)
        let frame = Frame(type: .output, payload: bulk.encode())
        for ref in clients.values {
            ref.target?.send(frame: frame)
        }
    }

    private func broadcast(frame: Frame) {
        compactClients()
        for ref in clients.values {
            ref.target?.send(frame: frame)
        }
    }

    private func dispatchEvents() {
        let events = parser.drainEvents()
        guard !events.isEmpty else { return }
        for ev in events {
            switch ev {
            case .bell:
                unreadBells += 1
                if let p = try? WireCodec.encode(BellEvent(sessionId: sessionId)) {
                    broadcast(frame: Frame(type: .bell, payload: p))
                }
            case .title(let t):
                currentTitle = t
                if let p = try? WireCodec.encode(TitleChangedEvent(sessionId: sessionId, title: t)) {
                    broadcast(frame: Frame(type: .titleChanged, payload: p))
                }
            case .cwd(let path):
                if let p = try? WireCodec.encode(CwdChangedEvent(sessionId: sessionId, path: path)) {
                    broadcast(frame: Frame(type: .cwdChanged, payload: p))
                }
            case .notify(let title, let body):
                if let p = try? WireCodec.encode(NotifyEvent(sessionId: sessionId, title: title, body: body)) {
                    broadcast(frame: Frame(type: .notify, payload: p))
                }
            case .promptMark(let kind, let exit):
                if let p = try? WireCodec.encode(PromptMarkEvent(sessionId: sessionId, kind: kind, exitCode: exit)) {
                    broadcast(frame: Frame(type: .promptMark, payload: p))
                }
            }
        }
    }
}

final class WeakClientRef {
    weak var target: SessionClient?
    init(_ t: SessionClient) { self.target = t }
}
