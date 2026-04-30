import Foundation
import SwiftData

public enum DepsState: Codable, Sendable {
    case current
    case installing
    case stale
    case error(String)
    case notApplicable
}

@Model
public final class Checkout {
    public var id: UUID
    public var name: String
    public var displayName: String?
    public var path: String
    public var branch: String
    public var createdAt: Int = 0
    public var order: Int = 0
    @Transient public var depsState: DepsState = .current
    @Transient public var setupStatus: String?

    public var repository: Repository?

    public var resolvedDisplayName: String {
        displayName ?? name
    }

    public init(
        id: UUID = UUID(),
        name: String,
        displayName: String? = nil,
        path: String,
        branch: String,
        createdAt: Int = Int(Date().timeIntervalSince1970 * 1000),
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.path = path
        self.branch = branch
        self.createdAt = createdAt
        self.order = order
    }
}
