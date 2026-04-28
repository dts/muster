import Foundation
import SwiftData

@MainActor
public final class IngestService {
    public static let shared = IngestService()
    private init() {}

    public struct IngestResult: Sendable {
        public var importedRepositories: [String] = []
        public var importedCheckouts: [String] = []
        public var refsMigrated: Int = 0
        public var skipped: [(slug: String, reason: String)] = []

        public var hasChanges: Bool {
            !importedRepositories.isEmpty || !importedCheckouts.isEmpty
        }
    }

    public func ingestOrphans(in context: ModelContext) async -> IngestResult {
        var result = IngestResult()

        let existingRepos = (try? context.fetch(FetchDescriptor<Repository>())) ?? []
        let existingRepoSlugs = Set(existingRepos.map(\.slug))

        let newRepos = await scanRepositories(skipping: existingRepoSlugs, into: &result)
        for repo in newRepos {
            context.insert(repo)
            result.importedRepositories.append(repo.displayName)
        }

        let allRepos = existingRepos + newRepos
        for repo in allRepos {
            await scanCheckouts(for: repo, into: &result, context: context)
        }

        if result.hasChanges {
            try? context.save()
        }

        result.refsMigrated = await syncCheckoutRefs(repos: allRepos)
        return result
    }

    private func syncCheckoutRefs(repos: [Repository]) async -> Int {
        let pairs: [(masterPath: URL, checkoutPath: URL)] = repos.flatMap { repo -> [(URL, URL)] in
            let master = URL(fileURLWithPath: repo.masterPath)
            return repo.checkouts.map { (master, URL(fileURLWithPath: $0.path)) }
        }
        guard !pairs.isEmpty else { return 0 }

        return await withTaskGroup(of: Bool.self) { group in
            for (master, checkout) in pairs {
                group.addTask {
                    let fm = FileManager.default
                    guard fm.fileExists(atPath: checkout.appendingPathComponent(".git").path),
                          fm.fileExists(atPath: master.appendingPathComponent(".git").path) else {
                        return false
                    }
                    do {
                        try await GitService.shared.copyRemoteRefs(from: master, at: checkout)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }
    }

    private func scanRepositories(
        skipping existing: Set<String>,
        into result: inout IngestResult
    ) async -> [Repository] {
        let fm = FileManager.default
        let reposDir = PathService.shared.reposDir
        guard let entries = try? fm.contentsOfDirectory(
            at: reposDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var imported: [Repository] = []
        for entry in entries {
            let slug = entry.lastPathComponent
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if existing.contains(slug) { continue }

            if isClonePartial(at: entry) {
                result.skipped.append((slug, "clone in progress"))
                continue
            }
            guard fm.fileExists(atPath: entry.appendingPathComponent(".git").path) else {
                result.skipped.append((slug, "not a git repo"))
                continue
            }

            do {
                let remoteURL = try await readRemote(at: entry)
                let defaultBranch = (try? await readDefaultBranch(at: entry)) ?? "main"
                let pm = await PackageManagerService.shared.detect(at: entry)
                let displayName = Repository.displayName(from: remoteURL)

                imported.append(Repository(
                    slug: slug,
                    displayName: displayName,
                    remoteURL: remoteURL,
                    masterPath: entry.path,
                    defaultBranch: defaultBranch,
                    packageManager: pm
                ))
            } catch {
                result.skipped.append((slug, "no origin remote"))
            }
        }
        return imported
    }

    private func scanCheckouts(
        for repository: Repository,
        into result: inout IngestResult,
        context: ModelContext
    ) async {
        let fm = FileManager.default
        let dir = PathService.shared.checkoutsDir.appendingPathComponent(repository.displayName, isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let knownNames = Set(repository.checkouts.map(\.name))

        for entry in entries {
            let name = entry.lastPathComponent
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if knownNames.contains(name) { continue }
            guard fm.fileExists(atPath: entry.appendingPathComponent(".git").path) else { continue }
            if isClonePartial(at: entry) {
                result.skipped.append(("\(repository.displayName)/\(name)", "checkout in progress"))
                continue
            }

            let branch = (try? await readCurrentBranch(at: entry)) ?? repository.defaultBranch
            let checkout = Checkout(name: name, path: entry.path, branch: branch)
            checkout.repository = repository
            context.insert(checkout)
            result.importedCheckouts.append("\(repository.displayName)/\(name)")
        }
    }

    private func isClonePartial(at repoPath: URL) -> Bool {
        let packDir = repoPath.appendingPathComponent(".git/objects/pack")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: packDir.path) else {
            return false
        }
        return entries.contains { $0.hasPrefix("tmp_pack_") || $0.hasPrefix("tmp_idx_") }
    }

    private func readRemote(at repoPath: URL) async throws -> String {
        let out = try await GitService.runWithOutput([
            "git", "-C", repoPath.path, "remote", "get-url", "origin"
        ])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readDefaultBranch(at repoPath: URL) async throws -> String {
        let out = try await GitService.runWithOutput([
            "git", "-C", repoPath.path, "symbolic-ref", "refs/remotes/origin/HEAD", "--short"
        ])
        return out
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "origin/", with: "")
    }

    private func readCurrentBranch(at repoPath: URL) async throws -> String {
        let out = try await GitService.runWithOutput([
            "git", "-C", repoPath.path, "rev-parse", "--abbrev-ref", "HEAD"
        ])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
