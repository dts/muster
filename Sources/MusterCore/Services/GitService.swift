import Foundation

public actor GitService {
    public static let shared = GitService()

    private init() {}

    public func clone(url: String, to destination: URL) async throws {
        try await Self.run(["git", "clone", url, destination.path])
    }

    public nonisolated func cloneStreaming(url: String, to destination: URL) -> AsyncThrowingStream<String, Error> {
        Self.runStreaming(["git", "clone", "--progress", url, destination.path])
    }

    public func cloneLocal(from source: URL, to destination: URL) async throws {
        try await Self.run(["git", "clone", source.path, destination.path])
    }

    public nonisolated func cloneLocalStreaming(from source: URL, to destination: URL) -> AsyncThrowingStream<String, Error> {
        Self.runStreaming(["git", "clone", "--progress", source.path, destination.path])
    }

    public func setRemoteURL(_ url: String, at repoPath: URL) async throws {
        try await Self.run(["git", "-C", repoPath.path, "remote", "set-url", "origin", url])
    }

    public func fetch(at repoPath: URL) async throws {
        try await Self.run(["git", "-C", repoPath.path, "fetch", "origin"])
    }

    public nonisolated func fetchStreaming(at repoPath: URL) -> AsyncThrowingStream<String, Error> {
        Self.runStreaming(["git", "-C", repoPath.path, "fetch", "--progress", "origin"])
    }

    public nonisolated func fetchBranchStreaming(_ branch: String, at repoPath: URL) -> AsyncThrowingStream<String, Error> {
        Self.runStreaming([
            "git", "-C", repoPath.path,
            "fetch", "--progress", "origin",
            "+\(branch):refs/remotes/origin/\(branch)"
        ])
    }

    public func copyRemoteRefs(from masterPath: URL, at repoPath: URL) async throws {
        try await Self.run([
            "git", "-C", repoPath.path,
            "fetch", "--no-tags", "--quiet",
            masterPath.path,
            "+refs/remotes/origin/*:refs/remotes/origin/*"
        ])
    }

    public func pull(at repoPath: URL, branch: String) async throws {
        try await Self.run(["git", "-C", repoPath.path, "pull", "--ff-only", "origin", branch])
    }

    public func checkout(branch: String, at repoPath: URL) async throws {
        try await Self.run(["git", "-C", repoPath.path, "checkout", branch])
    }

    public func createBranch(_ branch: String, at repoPath: URL) async throws {
        try await Self.run(["git", "-C", repoPath.path, "checkout", "-b", branch])
    }

    public func currentBranch(at repoPath: URL) async throws -> String {
        let output = try await Self.runWithOutput(["git", "-C", repoPath.path, "rev-parse", "--abbrev-ref", "HEAD"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func defaultBranch(at repoPath: URL) async throws -> String {
        let output = try await Self.runWithOutput([
            "git", "-C", repoPath.path, "symbolic-ref", "refs/remotes/origin/HEAD", "--short"
        ])
        let fullRef = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return fullRef.replacingOccurrences(of: "origin/", with: "")
    }

    public func hasUncommittedChanges(at repoPath: URL) async throws -> Bool {
        let output = try await Self.runWithOutput(["git", "-C", repoPath.path, "status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func remoteBranches(at repoPath: URL) async throws -> Set<String> {
        let output = try await Self.runWithOutput([
            "git", "-C", repoPath.path, "branch", "-r", "--format=%(refname:short)"
        ])
        let branches = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { branch -> String in
                if branch.hasPrefix("origin/") {
                    return String(branch.dropFirst(7))
                }
                return branch
            }
        return Set(branches)
    }

    @discardableResult
    nonisolated static func run(_ arguments: [String], at workingDirectory: URL? = nil) async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw GitError.commandFailed(arguments.joined(separator: " "), output)
        }

        return process
    }

    nonisolated static func runWithOutput(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw GitError.commandFailed(arguments.joined(separator: " "), output)
        }

        return output
    }

    nonisolated static func runStreaming(_ arguments: [String], at workingDirectory: URL? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let buffer = LineBuffer()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                for line in buffer.append(data) {
                    continuation.yield(line)
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let line = buffer.flush() {
                    continuation.yield(line)
                }
                if proc.terminationStatus != 0 {
                    continuation.finish(throwing: GitError.commandFailed(
                        arguments.joined(separator: " "),
                        "exited with status \(proc.terminationStatus)"
                    ))
                } else {
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let idx = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = data[..<idx]
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                lines.append(s)
            }
            data.removeSubrange(...idx)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        let s = String(data: data, encoding: .utf8)
        data = Data()
        return (s?.isEmpty == false) ? s : nil
    }
}

public enum GitError: Error, LocalizedError {
    case commandFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let output):
            return "Git command failed: \(command)\n\(output)"
        }
    }
}
