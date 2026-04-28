import Foundation
import Darwin
import MusterShellProtocol

final class ClientConnection: @unchecked Sendable {
    let socketFd: Int32
    var onFrame: ((Frame) -> Void)?
    var onClose: (() -> Void)?

    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private let reader = FrameReader()
    private var closed = false
    private let lock = NSLock()

    init(socketFd: Int32) {
        self.socketFd = socketFd
        self.readQueue = DispatchQueue(label: "muster.shell.client.read.\(socketFd)")
        self.writeQueue = DispatchQueue(label: "muster.shell.client.write.\(socketFd)")

        let flags = fcntl(socketFd, F_GETFL, 0)
        _ = fcntl(socketFd, F_SETFL, flags | O_NONBLOCK)
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: socketFd, queue: readQueue)
        src.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        src.resume()
        readSource = src
    }

    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(socketFd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                reader.append(Data(bytes: buf, count: n))
                while let frame = reader.nextFrame() {
                    onFrame?(frame)
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
                        self?.close()
                        return
                    }
                }
            }
        }
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        readSource?.cancel()
        Darwin.close(socketFd)
        onClose?()
    }
}
