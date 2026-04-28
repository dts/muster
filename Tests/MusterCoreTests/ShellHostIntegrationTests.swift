import XCTest
import Darwin
@testable import MusterCore
import MusterShellProtocol

final class ShellHostIntegrationTests: XCTestCase {
    var helperProcess: Process?
    var socketPath: String!
    var helperLogPath: String!

    override func setUp() async throws {
        let id = UUID().uuidString
        socketPath = "/tmp/muster-test-\(id).sock"
        helperLogPath = "/tmp/muster-test-\(id).log"
        unlink(socketPath)

        let helperURL = URL(fileURLWithPath: ".build/debug/MusterShellHost")
        let proc = Process()
        proc.executableURL = helperURL
        proc.arguments = ["--serve", "--socket", socketPath, "--foreground"]
        proc.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: helperLogPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: helperLogPath)
        proc.standardError = logHandle ?? FileHandle.nullDevice
        try proc.run()
        helperProcess = proc

        // Wait for socket
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: socketPath) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "helper did not bind socket")
    }

    override func tearDown() async throws {
        helperProcess?.terminate()
        helperProcess?.waitUntilExit()
        unlink(socketPath)
        unlink(helperLogPath)
    }

    /// Drive a Hello + Attach + Input + Output roundtrip using raw protocol bytes.
    func testRoundtrip() async throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = socketPath.utf8CString
        XCTAssertLessThanOrEqual(pathBytes.count, cap)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, src.count)
                }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connectResult, 0, "connect failed with errno=\(errno)")

        // Hello
        let helloPayload = try WireCodec.encode(Hello())
        let helloFrame = Frame(type: .hello, payload: helloPayload).encode()
        try writeAll(fd: fd, data: helloFrame)

        let reader = FrameReader()
        let helloAck = try await readFrame(fd: fd, reader: reader, expecting: .helloAck)
        let ack = try WireCodec.decode(HelloAck.self, from: helloAck.payload)
        XCTAssertEqual(ack.protocolVersion, BuildStamp.protocolVersion)

        // Attach
        let sid = UUID()
        let attach = Attach(
            sessionId: sid,
            cols: 80,
            rows: 24,
            cwd: NSTemporaryDirectory(),
            env: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            shell: "/bin/sh"
        )
        try writeAll(fd: fd, data: Frame(type: .attach, payload: try WireCodec.encode(attach)).encode())
        let attachAck = try await readFrame(fd: fd, reader: reader, expecting: .attachAck)
        let aack = try WireCodec.decode(AttachAck.self, from: attachAck.payload)
        XCTAssertEqual(aack.sessionId, sid)

        // Send "echo hello\n"
        let input = BulkPayload(sessionId: sid, bytes: Data("echo hello\n".utf8))
        try writeAll(fd: fd, data: Frame(type: .input, payload: input.encode()).encode())

        // Read output until we see "hello"
        let deadline = Date().addingTimeInterval(3.0)
        var collected = ""
        while Date() < deadline {
            let frame = try? await readFrame(fd: fd, reader: reader, expecting: .output, timeoutSec: 1.0)
            if let frame, let bulk = BulkPayload.decode(frame.payload) {
                collected += String(data: bulk.bytes, encoding: .utf8) ?? ""
                if collected.contains("hello") {
                    break
                }
            }
        }
        XCTAssertTrue(collected.contains("hello"), "did not see 'hello' in output: \(collected)")

        // Send Kill
        try writeAll(fd: fd, data: Frame(type: .kill, payload: try WireCodec.encode(Kill(sessionId: sid))).encode())

        // Drain frames until Exit arrives.
        let exitDeadline = Date().addingTimeInterval(3.0)
        var sawExit = false
        var buf = [UInt8](repeating: 0, count: 4096)
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while Date() < exitDeadline && !sawExit {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                reader.append(Data(bytes: buf, count: n))
                while let f = reader.nextFrame() {
                    if f.type == .exit {
                        let ev = try WireCodec.decode(ExitEvent.self, from: f.payload)
                        XCTAssertEqual(ev.sessionId, sid)
                        sawExit = true
                        break
                    }
                }
            } else if n == 0 {
                break
            }
        }
        XCTAssertTrue(sawExit, "did not see Exit event")
    }

    /// Verifies that a session survives client disconnect and replays buffered output on reattach.
    func testReattachPreservesSession() async throws {
        let sid = UUID()

        // Connection #1: attach, send a marker, disconnect.
        let fd1 = try connectSocket()
        try doHello(fd: fd1)
        let reader1 = FrameReader()
        try writeAll(fd: fd1, data: Frame(type: .attach, payload: try WireCodec.encode(Attach(
            sessionId: sid, cols: 80, rows: 24,
            cwd: NSTemporaryDirectory(),
            env: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            shell: "/bin/sh"
        ))).encode())
        _ = try await readFrame(fd: fd1, reader: reader1, expecting: .attachAck)

        let marker = "MUSTER_REATTACH_MARKER"
        let bulk = BulkPayload(sessionId: sid, bytes: Data("echo \(marker)\n".utf8))
        try writeAll(fd: fd1, data: Frame(type: .input, payload: bulk.encode()).encode())

        // Drain output until we see the marker (so we know the shell processed it)
        let deadline1 = Date().addingTimeInterval(3.0)
        var seen1 = ""
        while Date() < deadline1 && !seen1.contains(marker) {
            if let f = try? await readFrame(fd: fd1, reader: reader1, expecting: .output, timeoutSec: 0.5),
               let b = BulkPayload.decode(f.payload) {
                seen1 += String(data: b.bytes, encoding: .utf8) ?? ""
            }
        }
        XCTAssertTrue(seen1.contains(marker), "client #1 did not receive marker")

        Darwin.close(fd1)

        // Brief wait so the helper notices the disconnect
        try await Task.sleep(nanoseconds: 200_000_000)

        // Connection #2: attach with the SAME sessionId, expect replay containing the marker.
        let fd2 = try connectSocket()
        defer { Darwin.close(fd2) }
        try doHello(fd: fd2)
        let reader2 = FrameReader()
        try writeAll(fd: fd2, data: Frame(type: .attach, payload: try WireCodec.encode(Attach(
            sessionId: sid, cols: 80, rows: 24,
            cwd: NSTemporaryDirectory(),
            env: [:],
            shell: nil
        ))).encode())
        let ackFrame = try await readFrame(fd: fd2, reader: reader2, expecting: .attachAck)
        let ack = try WireCodec.decode(AttachAck.self, from: ackFrame.payload)
        XCTAssertTrue(ack.resumed, "second attach should report resumed=true")

        // Replay arrives as Output frames immediately after AttachAck
        let deadline2 = Date().addingTimeInterval(2.0)
        var replay = ""
        while Date() < deadline2 && !replay.contains(marker) {
            if let f = try? await readFrame(fd: fd2, reader: reader2, expecting: .output, timeoutSec: 0.5),
               let b = BulkPayload.decode(f.payload) {
                replay += String(data: b.bytes, encoding: .utf8) ?? ""
            }
        }
        XCTAssertTrue(replay.contains(marker), "replay did not contain marker; got: \(replay)")
    }

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, src.count)
                }
            }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if r != 0 {
            let e = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
        return fd
    }

    private func doHello(fd: Int32) throws {
        try writeAll(fd: fd, data: Frame(type: .hello, payload: try WireCodec.encode(Hello())).encode())
        let r = FrameReader()
        // Keep draining until HelloAck arrives or 1s passes
        let deadline = Date().addingTimeInterval(1.0)
        var buf = [UInt8](repeating: 0, count: 1024)
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while Date() < deadline {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                r.append(Data(bytes: buf, count: n))
                while let f = r.nextFrame() {
                    if f.type == .helloAck { return }
                }
            } else if n == 0 {
                throw NSError(domain: "test", code: -1)
            }
        }
        throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "no helloAck"])
    }

    // MARK: - Helpers

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var off = 0
            while off < data.count {
                let n = Darwin.write(fd, base + off, data.count - off)
                if n > 0 { off += n }
                else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
                else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        }
    }

    private func readFrame(fd: Int32, reader: FrameReader, expecting: MessageType, timeoutSec: Double = 3.0) async throws -> Frame {
        // Try existing buffer first
        while let f = reader.nextFrame() {
            if f.type == expecting { return f }
            // unrelated frame — skip silently for the integration test
        }

        let deadline = Date().addingTimeInterval(timeoutSec)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            // poll with select-style timeout via O_NONBLOCK + sleep — simpler: blocking read with SO_RCVTIMEO
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                reader.append(Data(bytes: buf, count: n))
                while let f = reader.nextFrame() {
                    if f.type == expecting { return f }
                }
            } else if n == 0 {
                throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "EOF"])
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "timeout waiting for \(expecting)"])
    }
}
