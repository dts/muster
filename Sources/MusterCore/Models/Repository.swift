import Foundation
import SwiftData

public enum SyncState: Codable, Sendable {
    case idle
    case fetching
    case pulling
    case installingDeps
    case error(String)
}

public enum PackageManager: String, Codable, Sendable, CaseIterable {
    case pnpm
    case npm
    case yarn
    case bun

    public var installCommand: [String] {
        switch self {
        case .pnpm: ["pnpm", "i", "--frozen-lockfile"]
        case .npm: ["npm", "ci"]
        case .yarn: ["yarn", "install", "--frozen-lockfile"]
        case .bun: ["bun", "install", "--frozen-lockfile"]
        }
    }

    public var offlineInstallCommand: [String] {
        switch self {
        case .pnpm: ["pnpm", "i", "--frozen-lockfile", "--offline"]
        case .npm: ["npm", "ci", "--offline"]
        case .yarn: ["yarn", "install", "--frozen-lockfile", "--offline"]
        case .bun: ["bun", "install", "--frozen-lockfile"]
        }
    }

    public var lockfileName: String {
        switch self {
        case .pnpm: "pnpm-lock.yaml"
        case .npm: "package-lock.json"
        case .yarn: "yarn.lock"
        case .bun: "bun.lockb"
        }
    }
}

@Model
public final class Repository {
    public var id: UUID
    public var slug: String
    public var displayName: String
    public var remoteURL: String
    public var masterPath: String
    public var defaultBranch: String
    public var packageManager: PackageManager?
    public var lastSyncDate: Date?
    @Transient public var syncState: SyncState = .idle

    @Relationship(deleteRule: .cascade, inverse: \Checkout.repository)
    public var checkouts: [Checkout] = []

    public init(
        id: UUID = UUID(),
        slug: String,
        displayName: String,
        remoteURL: String,
        masterPath: String,
        defaultBranch: String = "main",
        packageManager: PackageManager? = nil
    ) {
        self.id = id
        self.slug = slug
        self.displayName = displayName
        self.remoteURL = remoteURL
        self.masterPath = masterPath
        self.defaultBranch = defaultBranch
        self.packageManager = packageManager
    }
}

extension Repository {
    public static func slug(from remoteURL: String) -> String {
        var url = remoteURL
        if url.hasSuffix(".git") {
            url = String(url.dropLast(4))
        }
        if url.hasPrefix("git@") {
            url = url.replacingOccurrences(of: ":", with: "/")
            url = String(url.dropFirst(4))
        } else if url.hasPrefix("https://") {
            url = String(url.dropFirst(8))
        }
        return url
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    public static func displayName(from remoteURL: String) -> String {
        var url = remoteURL
        if url.hasSuffix(".git") {
            url = String(url.dropLast(4))
        }
        return url.components(separatedBy: "/").last ?? url
    }
}
