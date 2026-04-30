import Foundation
import SwiftData

@MainActor
public final class SyncService {
    public static let shared = SyncService()

    public static let intervalSeconds: TimeInterval = 300

    private var timers: [UUID: Timer] = [:]
    private var inflight: Set<UUID> = []
    private weak var modelContext: ModelContext?

    private init() {}

    public func start(context: ModelContext, repositories: [Repository]) {
        modelContext = context
        sync(repositories: repositories)
    }

    public func sync(repositories: [Repository]) {
        let currentIds = Set(repositories.map(\.id))
        for id in timers.keys where !currentIds.contains(id) {
            timers[id]?.invalidate()
            timers.removeValue(forKey: id)
        }
        for repo in repositories where timers[repo.id] == nil {
            schedule(repo)
            Task { await self.fetchRepo(repo) }
        }
    }

    private func schedule(_ repo: Repository) {
        let repoId = repo.id
        let timer = Timer.scheduledTimer(withTimeInterval: Self.intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let repo = self.lookupRepo(id: repoId) else { return }
                await self.fetchRepo(repo)
            }
        }
        timers[repo.id] = timer
    }

    private func lookupRepo(id: UUID) -> Repository? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<Repository>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    @discardableResult
    public func fetchRepo(_ repo: Repository) async -> Bool {
        guard !inflight.contains(repo.id) else { return false }
        inflight.insert(repo.id)
        defer { inflight.remove(repo.id) }

        let masterURL = URL(fileURLWithPath: repo.masterPath)
        guard FileManager.default.fileExists(atPath: masterURL.path) else { return false }

        repo.syncState = .fetching
        do {
            try await GitService.shared.fetch(at: masterURL)
            repo.lastSyncDate = Date()
            repo.syncState = .idle
            try? modelContext?.save()
            return true
        } catch {
            repo.syncState = .error(error.localizedDescription)
            return false
        }
    }
}
