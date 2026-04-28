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
    public var path: String
    public var branch: String
    @Transient public var depsState: DepsState = .current

    public var repository: Repository?

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        branch: String
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.branch = branch
    }
}
