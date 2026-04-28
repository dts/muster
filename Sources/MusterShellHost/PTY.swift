import Darwin
import Foundation

public struct PTY {
    public let masterFd: Int32
    public let pid: pid_t
}

public enum PTYError: Error {
    case openptyFailed(errno: Int32)
    case spawnFailed(errno: Int32)
}

/// Spawns a child process with a pseudo-terminal via posix_spawn.
/// Returns master fd + child pid in the parent.
public func spawnShellInPTY(
    executable: String,
    args: [String],
    env: [String: String],
    cwd: String,
    cols: UInt16,
    rows: UInt16
) throws -> PTY {
    var masterFd: Int32 = -1
    var slaveFd: Int32 = -1

    // openpty creates a PTY pair
    if openpty(&masterFd, &slaveFd, nil, nil, nil) < 0 {
        throw PTYError.openptyFailed(errno: errno)
    }

    // Set initial window size on slave
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(slaveFd, TIOCSWINSZ, &ws)

    // Build C strings for posix_spawn
    let argvStrings = ([executable] + args).map { strdup($0)! }
    let argvArray = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argvStrings.count + 1)
    for (i, p) in argvStrings.enumerated() { argvArray[i] = p }
    argvArray[argvStrings.count] = nil

    let envStrings = env.map { strdup("\($0.key)=\($0.value)")! }
    let envArray = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envStrings.count + 1)
    for (i, p) in envStrings.enumerated() { envArray[i] = p }
    envArray[envStrings.count] = nil

    defer {
        for p in argvStrings { free(p) }
        for p in envStrings { free(p) }
        argvArray.deallocate()
        envArray.deallocate()
    }

    // File actions: dup slave fd to stdin/stdout/stderr, close others
    var fileActions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    posix_spawn_file_actions_adddup2(&fileActions, slaveFd, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, slaveFd, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, slaveFd, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, slaveFd)
    posix_spawn_file_actions_addclose(&fileActions, masterFd)

    // Spawn attributes: new session, start in cwd
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

    // Change to working directory before spawn
    let originalCwd = FileManager.default.currentDirectoryPath
    _ = chdir(cwd)
    defer { _ = chdir(originalCwd) }

    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable, &fileActions, &attr, argvArray, envArray)

    // Close slave fd in parent (child has its own copy)
    close(slaveFd)

    if result != 0 {
        close(masterFd)
        throw PTYError.spawnFailed(errno: result)
    }

    // Set master fd to non-blocking
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
