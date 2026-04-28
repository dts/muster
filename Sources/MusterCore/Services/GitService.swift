import Foundation

public actor GitService {
    public static let shared = GitService()

    private init() {}

    public func clone(url: String, to destination: URL) async throws {
        try await run(["git", "clone", url, destination.path])
    }

    public func cloneLocal(from source: URL, to destination: URL) async throws {
        try await run(["git", "clone", source.path, destination.path])
    }

    public func setRemoteURL(_ url: String, at repoPath: URL) async throws {
        try await run(["git", "-C", repoPath.path, "remote", "set-url", "origin", url])
    }

    public func fetch(at repoPath: URL) async throws {
        try await run(["git", "-C", repoPath.path, "fetch", "origin"])
    }

    public func pull(at repoPath: URL, branch: String) async throws {
        try await run(["git", "-C", repoPath.path, "pull", "--ff-only", "origin", branch])
    }

    public func checkout(branch: String, at repoPath: URL) async throws {
        try await run(["git", "-C", repoPath.path, "checkout", branch])
    }

    public func createBranch(_ branch: String, at repoPath: URL) async throws {
        try await run(["git", "-C", repoPath.path, "checkout", "-b", branch])
    }

    public func currentBranch(at repoPath: URL) async throws -> String {
        let output = try await runWithOutput(["git", "-C", repoPath.path, "rev-parse", "--abbrev-ref", "HEAD"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func defaultBranch(at repoPath: URL) async throws -> String {
        let output = try await runWithOutput([
            "git", "-C", repoPath.path, "symbolic-ref", "refs/remotes/origin/HEAD", "--short"
        ])
        let fullRef = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return fullRef.replacingOccurrences(of: "origin/", with: "")
    }

    public func hasUncommittedChanges(at repoPath: URL) async throws -> Bool {
        let output = try await runWithOutput(["git", "-C", repoPath.path, "status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    private func run(_ arguments: [String]) async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

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

    private func runWithOutput(_ arguments: [String]) async throws -> String {
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
