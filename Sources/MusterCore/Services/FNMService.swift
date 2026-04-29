import Foundation

public actor FNMService {
    public static let shared = FNMService()

    private init() {}

    public func detectNodeVersion(at path: URL) -> String? {
        let fm = FileManager.default
        for filename in [".nvmrc", ".node-version"] {
            let file = path.appendingPathComponent(filename)
            if fm.fileExists(atPath: file.path),
               let contents = try? String(contentsOf: file, encoding: .utf8) {
                let version = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !version.isEmpty {
                    return version
                }
            }
        }
        return nil
    }

    public func nodeEnvironment(for version: String) async throws -> [String: String] {
        let fnmPath = try await resolveFNMPath()
        let nodePath = try await resolveNodePath(fnm: fnmPath, version: version)

        var env = ProcessInfo.processInfo.environment
        if let currentPath = env["PATH"] {
            env["PATH"] = "\(nodePath):\(currentPath)"
        } else {
            env["PATH"] = nodePath
        }
        return env
    }

    public func environmentForPath(_ path: URL) async throws -> [String: String]? {
        guard let version = detectNodeVersion(at: path) else {
            return nil
        }
        return try await nodeEnvironment(for: version)
    }

    private func resolveFNMPath() async throws -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let possiblePaths = [
            homeDir.appendingPathComponent(".local/share/fnm/fnm").path,
            homeDir.appendingPathComponent(".fnm/fnm").path,
            "/usr/local/bin/fnm",
            "/opt/homebrew/bin/fnm"
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let output = try await runWithOutput(["/usr/bin/which", "fnm"])
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        throw FNMError.fnmNotFound
    }

    private func resolveNodePath(fnm: String, version: String) async throws -> String {
        try await ensureVersionInstalled(fnm: fnm, version: version)

        let output = try await runWithOutput([fnm, "exec", "--using", version, "node", "-e", "console.log(process.execPath)"])
        let nodeBinary = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !nodeBinary.isEmpty else {
            throw FNMError.nodeVersionNotAvailable(version)
        }

        let nodeDir = URL(fileURLWithPath: nodeBinary).deletingLastPathComponent().path
        return nodeDir
    }

    private func ensureVersionInstalled(fnm: String, version: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fnm)
        process.arguments = ["list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        let normalizedVersion = version.hasPrefix("v") ? String(version.dropFirst()) : version
        if output.contains(normalizedVersion) || output.contains("v\(normalizedVersion)") {
            return
        }

        _ = try await runWithOutput([fnm, "install", version])
    }

    private func runWithOutput(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw FNMError.commandFailed(arguments.joined(separator: " "), output)
        }

        return output
    }
}

public enum FNMError: Error, LocalizedError {
    case fnmNotFound
    case nodeVersionNotAvailable(String)
    case commandFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .fnmNotFound:
            return "FNM not found. Install it from https://github.com/Schniz/fnm"
        case .nodeVersionNotAvailable(let version):
            return "Node version \(version) is not available via FNM"
        case .commandFailed(let command, let output):
            return "FNM command failed: \(command)\n\(output)"
        }
    }
}
