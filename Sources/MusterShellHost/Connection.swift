import Foundation
import Darwin
import MusterShellProtocol

protocol ServerControl: AnyObject {
    func requestQuit()
}

final class Connection: SessionClient {
    let socketFd: Int32
    private weak var server: ServerControl?
    private let manager: SessionManager
    private let reader = FrameReader()
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var attachedSessions = Set<UUID>()
    private var closed = false
    private var onClose: ((Connection) -> Void)?

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var isFocused: Bool = false

    init(socketFd: Int32, manager: SessionManager, server: ServerControl, onClose: @escaping (Connection) -> Void) {
        self.socketFd = socketFd
        self.manager = manager
        self.server = server
        self.onClose = onClose
        self.readQueue = DispatchQueue(label: "muster.shell.conn.read.\(socketFd)")
        self.writeQueue = DispatchQueue(label: "muster.shell.conn.write.\(socketFd)")

        // Set non-blocking
        let flags = fcntl(socketFd, F_GETFL, 0)
        _ = fcntl(socketFd, F_SETFL, flags | O_NONBLOCK)

        startRead()
    }

    private func startRead() {
        let src = DispatchSource.makeReadSource(fileDescriptor: socketFd, queue: readQueue)
        src.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        src.resume()
        readSource = src
    }

    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(socketFd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                reader.append(Data(bytes: buf, count: n))
                while let frame = reader.nextFrame() {
                    handleFrame(frame)
                }
            } else if n == 0 {
                close()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                close()
                return
            }
        }
    }

    private func handleFrame(_ frame: Frame) {
        switch frame.type {
        case .hello:
            let ack = HelloAck(
                protocolVersion: BuildStamp.protocolVersion,
                buildId: BuildStamp.helperBuildId,
                pid: getpid(),
                startedAt: Date()
            )
            if let payload = try? WireCodec.encode(ack) {
                send(frame: Frame(type: .helloAck, payload: payload))
            }

        case .attach:
            guard let req = try? WireCodec.decode(Attach.self, from: frame.payload) else { return }
            switch manager.attachOrCreate(req) {
            case .success(let session):
                attachedSessions.insert(req.sessionId)
                let client: SessionClient = self
                session.queue.async { [weak session, client] in
                    session?.attach(client)
                    session?.resize(cols: req.cols, rows: req.rows)
                }
            case .failure(let err):
                if let p = try? WireCodec.encode(ErrorMessage(sessionId: req.sessionId, message: "\(err)")) {
                    send(frame: Frame(type: .errorMessage, payload: p))
                }
            }

        case .input:
            guard let bulk = BulkPayload.decode(frame.payload) else { return }
            if let session = manager.get(bulk.sessionId) {
                session.queue.async { [bytes = bulk.bytes] in
                    session.write(bytes)
                }
            }

        case .resize:
            guard let req = try? WireCodec.decode(Resize.self, from: frame.payload) else { return }
            if let session = manager.get(req.sessionId) {
                session.queue.async {
                    session.resize(cols: req.cols, rows: req.rows)
                }
            }

        case .detach:
            guard let req = try? WireCodec.decode(Detach.self, from: frame.payload) else { return }
            attachedSessions.remove(req.sessionId)
            if let session = manager.get(req.sessionId) {
                let client: SessionClient = self
                session.queue.async { [weak session, client] in
                    session?.detach(client)
                }
            }

        case .kill:
            guard let req = try? WireCodec.decode(Kill.self, from: frame.payload) else { return }
            manager.kill(req.sessionId)

        case .markRead:
            guard let req = try? WireCodec.decode(MarkRead.self, from: frame.payload) else { return }
            if let session = manager.get(req.sessionId) {
                session.queue.async {
                    session.markRead()
                }
            }

        case .setFocused:
            guard let req = try? WireCodec.decode(SetFocused.self, from: frame.payload) else { return }
            isFocused = req.focused

        case .list:
            let info = manager.list()
            if let p = try? WireCodec.encode(SessionsList(sessions: info)) {
                send(frame: Frame(type: .sessionsList, payload: p))
            }

        case .quit:
            server?.requestQuit()

        case .drain:
            // For v1 — same as quit (proper drain semantics deferred)
            server?.requestQuit()

        default:
            // Server-bound frames only; ignore client-side push types
            break
        }
    }

    func send(frame: Frame) {
        let data = frame.encode()
        writeQueue.async { [socketFd, weak self] in
            data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { return }
                var off = 0
                while off < data.count {
                    let n = Darwin.write(socketFd, base + off, data.count - off)
                    if n > 0 {
                        off += n
                    } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                        continue
                    } else {
                        // write failed — drop the connection
                        self?.close()
                        return
                    }
                }
            }
        }
    }

    func close() {
        readQueue.async { [weak self] in
            guard let self else { return }
            if closed { return }
            closed = true
            for sid in attachedSessions {
                if let session = manager.get(sid) {
                    let client: SessionClient = self
                    session.queue.async { [weak session, client] in
                        session?.detach(client)
                    }
                }
            }
            attachedSessions.removeAll()
            readSource?.cancel()
            Darwin.close(socketFd)
            onClose?(self)
            onClose = nil
        }
    }
}
