import Darwin
import Foundation

public struct PTY {
    public let masterFd: Int32
    public let pid: pid_t
}

public enum PTYError: Error {
    case forkFailed(errno: Int32)
    case execFailed(errno: Int32)
}

/// Forks a child process with a pseudo-terminal, execs the given shell.
/// Returns master fd + child pid in the parent. Child does not return.
public func spawnShellInPTY(
    executable: String,
    args: [String],
    env: [String: String],
    cwd: String,
    cols: UInt16,
    rows: UInt16
) throws -> PTY {
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    var masterFd: Int32 = -1

    // Build C strings BEFORE fork so they're in shared memory before the COW split.
    let argvStrings = ([executable] + args).map { strdup($0)! }
    var argvPtrs: [UnsafeMutablePointer<CChar>?] = argvStrings.map { Optional($0) }
    argvPtrs.append(nil)

    let envStrings = env.map { strdup("\($0.key)=\($0.value)")! }
    var envPtrs: [UnsafeMutablePointer<CChar>?] = envStrings.map { Optional($0) }
    envPtrs.append(nil)

    let cwdC = strdup(cwd)!
    let execC = strdup(executable)!

    defer {
        for p in argvStrings { free(p) }
        for p in envStrings { free(p) }
        free(cwdC)
        free(execC)
    }

    let pid = forkpty(&masterFd, nil, nil, &ws)

    if pid < 0 {
        throw PTYError.forkFailed(errno: errno)
    }

    if pid == 0 {
        // Child. Only async-signal-safe calls from here.
        _ = chdir(cwdC)

        // Close inherited fds > 2
        let maxFd = Int32(getdtablesize())
        var fd: Int32 = 3
        while fd < maxFd {
            _ = close(fd)
            fd += 1
        }

        argvPtrs.withUnsafeBufferPointer { argvBuf in
            envPtrs.withUnsafeBufferPointer { envBuf in
                _ = execve(execC, argvBuf.baseAddress, envBuf.baseAddress)
            }
        }
        // exec only returns on failure
        _exit(127)
    }

    // Parent
    // Set master fd to non-blocking — readers use kqueue/dispatch sources
    let flags = fcntl(masterFd, F_GETFL, 0)
    _ = fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)

    return PTY(masterFd: masterFd, pid: pid)
}

public func resizePTY(masterFd: Int32, cols: UInt16, rows: UInt16) {
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(masterFd, TIOCSWINSZ, &ws)
}

public func sendSignal(pid: pid_t, signal: Int32) {
    _ = kill(pid, signal)
}
