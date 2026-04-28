import Foundation

public actor PackageManagerService {
    public static let shared = PackageManagerService()

    private init() {}

    public func detect(at path: URL) -> PackageManager? {
        let fm = FileManager.default
        for pm in [PackageManager.pnpm, .yarn, .bun, .npm] {
            let lockfile = path.appendingPathComponent(pm.lockfileName)
            if fm.fileExists(atPath: lockfile.path) {
                return pm
            }
        }
        let packageJson = path.appendingPathComponent("package.json")
        if fm.fileExists(atPath: packageJson.path) {
            return .npm
        }
        return nil
    }

    public struct InstallResult: Sendable {
        public let usedOffline: Bool
        public let fallbackReason: String?
    }

    public func install(at path: URL, packageManager: PackageManager, offline: Bool) async throws -> InstallResult {
        if offline {
            do {
                try await run(packageManager.offlineInstallCommand, at: path)
                return InstallResult(usedOffline: true, fallbackReason: nil)
            } catch {
                let reason = "Offline install failed: \(error.localizedDescription). Retrying with network..."
                try await run(packageManager.installCommand, at: path)
                return InstallResult(usedOffline: false, fallbackReason: reason)
            }
        } else {
            try await run(packageManager.installCommand, at: path)
            return InstallResult(usedOffline: false, fallbackReason: nil)
        }
    }

    private func run(_ arguments: [String], at workingDirectory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw PackageManagerError.installFailed(arguments.joined(separator: " "), output)
        }
    }
}

public enum PackageManagerError: Error, LocalizedError {
    case installFailed(String, String)
    case notDetected

    public var errorDescription: String? {
        switch self {
        case .installFailed(let command, let output):
            return "Package install failed: \(command)\n\(output)"
        case .notDetected:
            return "No package manager detected"
        }
    }
}
