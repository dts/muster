@_exported import Foundation
@_exported import SwiftData

public enum MusterCore {
    public static func setupSchema() -> ModelContainer {
        let schema = Schema([Repository.self, Checkout.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    public static func initialize() async throws {
        try PathService.shared.ensureDirectoriesExist()
    }
}
