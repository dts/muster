import Foundation
import Darwin
import MusterShellProtocol

final class SocketServer: ServerControl {
    let socketPath: String
    private let manager: SessionManager
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "muster.shell.accept")
    private let connQueue = DispatchQueue(label: "muster.shell.connections")
    private var connections: Set<ObjectIdentifier> = []
    private var connRefs: [ObjectIdentifier: Connection] = [:]
    private var quitRequested = false
    private let quitGroup = DispatchGroup()

    init(socketPath: String, manager: SessionManager) {
        self.socketPath = socketPath
        self.manager = manager
    }

    func bind() throws {
        // Remove stale socket if present
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= sunPathCapacity else {
            Darwin.close(fd)
            throw NSError(domain: "muster.shell", code: -1, userInfo: [NSLocalizedDescriptionKey: "socket path too long"])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dst in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult < 0 {
            let e = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }

        chmod(socketPath, 0o600)

        if Darwin.listen(fd, 16) < 0 {
            let e = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }

        // Non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listenFd = fd
        quitGroup.enter()
    }

    func run() {
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: acceptQueue)
        src.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        src.resume()
        acceptSource = src

        quitGroup.wait()
    }

    private func acceptOne() {
        while true {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFd, $0, &len)
                }
            }
            if cfd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }

            let conn = Connection(socketFd: cfd, manager: manager, server: self) { [weak self] c in
                self?.connQueue.async {
                    self?.connRefs.removeValue(forKey: c.id)
                    self?.connections.remove(c.id)
                }
            }
            connQueue.async { [weak self] in
                self?.connections.insert(conn.id)
                self?.connRefs[conn.id] = conn
            }
        }
    }

    func requestQuit() {
        connQueue.async { [weak self] in
            guard let self, !quitRequested else { return }
            quitRequested = true

            acceptSource?.cancel()
            if listenFd >= 0 {
                Darwin.close(listenFd)
                listenFd = -1
            }
            unlink(socketPath)

            for conn in connRefs.values {
                conn.close()
            }
            connRefs.removeAll()
            connections.removeAll()

            quitGroup.leave()
        }
    }
}
