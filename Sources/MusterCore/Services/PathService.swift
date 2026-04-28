import Foundation

public struct PathService: Sendable {
    public static let shared = PathService()

    public var musterHiddenDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".muster", isDirectory: true)
    }

    public var reposDir: URL {
        musterHiddenDir.appendingPathComponent("repos", isDirectory: true)
    }

    public var configFile: URL {
        musterHiddenDir.appendingPathComponent("config.json")
    }

    public var checkoutsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("muster", isDirectory: true)
    }

    public init() {}

    public func masterPath(for slug: String) -> URL {
        reposDir.appendingPathComponent(slug, isDirectory: true)
    }

    public func checkoutPath(repoDisplayName: String, checkoutName: String) -> URL {
        checkoutsDir
            .appendingPathComponent(repoDisplayName, isDirectory: true)
            .appendingPathComponent(checkoutName, isDirectory: true)
    }

    public func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: reposDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: checkoutsDir, withIntermediateDirectories: true)
    }

    public func slugify(_ input: String) -> String {
        input
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
