import Foundation
import Darwin
import MusterShellProtocol

func defaultSocketPath() -> String {
    let home = NSHomeDirectory()
    let dir = "\(home)/Library/Application Support/Muster"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return "\(dir)/shell-host.sock"
}

func defaultLogPath() -> String {
    let home = NSHomeDirectory()
    return "\(home)/Library/Application Support/Muster/shell-host.log"
}

func parseArg(_ argv: [String], _ name: String) -> String? {
    if let idx = argv.firstIndex(of: name), idx + 1 < argv.count {
        return argv[idx + 1]
    }
    return nil
}

let argv = CommandLine.arguments
let mode = argv.dropFirst().first(where: { !$0.hasPrefix("--") || $0 == "--serve" || $0 == "--version" || $0 == "--test-pty" }) ?? "--serve"

switch mode {
case "--version":
    print("MusterShellHost \(BuildStamp.helperBuildId), protocol \(BuildStamp.protocolVersion)")
    exit(0)

case "--test-pty":
    let pty = try spawnShellInPTY(
        executable: "/bin/echo",
        args: ["hello", "from", "pty"],
        env: ProcessInfo.processInfo.environment,
        cwd: FileManager.default.currentDirectoryPath,
        cols: 80,
        rows: 24
    )
    var buf = [UInt8](repeating: 0, count: 4096)
    var collected = ""
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        let n = read(pty.masterFd, &buf, buf.count)
        if n > 0 {
            collected += String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        } else if n == 0 {
            break
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            break
        } else {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if collected.contains("hello from pty") { break }
    }
    var status: Int32 = 0
    waitpid(pty.pid, &status, 0)
    print("output: \(collected.trimmingCharacters(in: .whitespacesAndNewlines))")
    print("status: \(status)")
    exit(collected.contains("hello from pty") ? 0 : 1)

case "--serve":
    let socketPath = parseArg(argv, "--socket") ?? defaultSocketPath()
    let logPath = parseArg(argv, "--log") ?? defaultLogPath()
    let foreground = argv.contains("--foreground")

    if !foreground {
        // Redirect stdout/stderr to log file (append mode)
        let logFd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if logFd >= 0 {
            dup2(logFd, 1)
            dup2(logFd, 2)
            if logFd > 2 { close(logFd) }
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
    }

    let now = ISO8601DateFormatter().string(from: Date())
    fputs("[\(now)] MusterShellHost starting (build=\(BuildStamp.helperBuildId), protocol=\(BuildStamp.protocolVersion), pid=\(getpid()))\n", stderr)
    fputs("[\(now)] socket=\(socketPath)\n", stderr)

    let manager = SessionManager()
    let server = SocketServer(socketPath: socketPath, manager: manager)

    do {
        try server.bind()
    } catch {
        fputs("[\(now)] bind failed: \(error)\n", stderr)
        exit(1)
    }

    // Signal handlers
    let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    termSrc.setEventHandler { server.requestQuit() }
    termSrc.resume()
    signal(SIGTERM, SIG_IGN)

    let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    intSrc.setEventHandler { server.requestQuit() }
    intSrc.resume()
    signal(SIGINT, SIG_IGN)

    let usrSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
    usrSrc.setEventHandler { server.requestQuit() }
    usrSrc.resume()
    signal(SIGUSR1, SIG_IGN)

    // Ignore SIGHUP — we want to survive controlling-terminal hangups
    signal(SIGHUP, SIG_IGN)
    // Ignore SIGPIPE — we handle write failures explicitly
    signal(SIGPIPE, SIG_IGN)

    server.run()

    let stopTime = ISO8601DateFormatter().string(from: Date())
    fputs("[\(stopTime)] MusterShellHost exiting\n", stderr)
    exit(0)

default:
    fputs("usage: MusterShellHost [--serve|--test-pty|--version] [--socket <path>] [--log <path>] [--foreground]\n", stderr)
    exit(2)
}
