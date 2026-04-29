import SwiftUI
import SwiftData
import MusterCore

struct NewCheckoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: Repository

    @State private var name = ""
    @State private var branch = ""
    @State private var createNewBranch = false
    @State private var remoteBranches: Set<String> = []
    @State private var loadingBranches = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Checkout").font(.headline)
            Text("Repository: \(repository.displayName)")
                .foregroundStyle(.secondary)

            TextField("Checkout name (e.g., feature-auth)", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Branch (default: \(repository.defaultBranch))", text: $branch)
                .textFieldStyle(.roundedBorder)
                .onChange(of: branch) { _, newValue in
                    let target = newValue.isEmpty ? repository.defaultBranch : newValue
                    createNewBranch = !remoteBranches.contains(target)
                }

            HStack(spacing: 6) {
                if loadingBranches {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Checking branches…")
                        .foregroundStyle(.secondary)
                } else {
                    let target = branch.isEmpty ? repository.defaultBranch : branch
                    if remoteBranches.contains(target) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Will check out existing branch")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Will create new branch")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)

            Text("Setup runs in the background — close this and start more.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .onAppear {
            Task {
                let masterPath = URL(fileURLWithPath: repository.masterPath)
                if let branches = try? await GitService.shared.remoteBranches(at: masterPath) {
                    remoteBranches = branches
                    createNewBranch = !branches.contains(repository.defaultBranch)
                }
                loadingBranches = false
            }
        }
    }

    private func submit() {
        let captured = (name: name, branch: branch, createNewBranch: createNewBranch, repo: repository)
        let op = Operation(
            title: "Checkout \(captured.name)",
            subtitle: "\(captured.repo.displayName) · \(captured.createNewBranch ? "new branch" : (captured.branch.isEmpty ? captured.repo.defaultBranch : captured.branch))"
        )
        OperationStore.shared.add(op)
        let context = modelContext
        Task { @MainActor in
            await run(captured: captured, op: op, context: context)
        }
        dismiss()
    }

    @MainActor
    private func run(
        captured: (name: String, branch: String, createNewBranch: Bool, repo: Repository),
        op: Operation,
        context: ModelContext
    ) async {
        let fm = FileManager.default
        let sluggedName = PathService.shared.slugify(captured.name)
        let checkoutPath = PathService.shared.checkoutPath(
            repoDisplayName: captured.repo.displayName,
            checkoutName: sluggedName
        )
        let masterPath = URL(fileURLWithPath: captured.repo.masterPath)
        let target = captured.branch.isEmpty ? captured.repo.defaultBranch : captured.branch

        let nextOrder = (captured.repo.checkouts.map(\.order).max() ?? -1) + 1
        let checkout = Checkout(
            name: sluggedName,
            displayName: captured.name,
            path: checkoutPath.path,
            branch: target,
            order: nextOrder
        )
        checkout.repository = captured.repo
        checkout.setupStatus = "Starting…"
        context.insert(checkout)
        try? context.save()

        func updateStatus(_ status: String) {
            op.setStatus(status)
            checkout.setupStatus = status
        }

        do {
            if fm.fileExists(atPath: checkoutPath.path) {
                let pathString = checkoutPath.path
                let claimed = captured.repo.checkouts.contains { $0.path == pathString && $0.id != checkout.id }
                if claimed {
                    throw NSError(domain: "Muster", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "A checkout named \"\(sluggedName)\" already exists for this repo."
                    ])
                }
                op.append("[muster] removing orphaned dir at \(pathString)")
                try fm.removeItem(at: checkoutPath)
            }

            updateStatus("Cloning from master…")
            for try await line in GitService.shared.cloneLocalStreaming(from: masterPath, to: checkoutPath) {
                op.append(line)
            }

            updateStatus("Copying refs from master…")
            try await GitService.shared.copyRemoteRefs(from: masterPath, at: checkoutPath)

            updateStatus("Configuring remote…")
            try await GitService.shared.setRemoteURL(captured.repo.remoteURL, at: checkoutPath)

            if captured.createNewBranch {
                updateStatus("Creating branch \(target)…")
                try await GitService.shared.createBranch(target, at: checkoutPath)
            } else {
                do {
                    updateStatus("Checking out \(target)…")
                    try await GitService.shared.checkout(branch: target, at: checkoutPath)
                } catch {
                    updateStatus("Branch not local — fetching \(target) from origin…")
                    for try await line in GitService.shared.fetchBranchStreaming(target, at: checkoutPath) {
                        op.append(line)
                    }
                    updateStatus("Checking out \(target)…")
                    try await GitService.shared.checkout(branch: target, at: checkoutPath)
                }
            }

            op.append("[muster] checkout ready — installing deps in background")

            if let pm = captured.repo.packageManager {
                updateStatus("Installing dependencies (\(pm.rawValue), offline)…")
                checkout.depsState = .installing
                op.append("[muster] running \(pm.offlineInstallCommand.joined(separator: " "))")
                do {
                    for try await line in PackageManagerService.shared.installStreaming(
                        at: checkoutPath, packageManager: pm, offline: true
                    ) {
                        op.append(line)
                    }
                    checkout.depsState = .current
                } catch {
                    checkout.depsState = .error(error.localizedDescription)
                    checkout.setupStatus = nil
                    op.fail("Dependency install failed: \(error.localizedDescription)")
                    return
                }
            }

            checkout.setupStatus = nil
            op.succeed()
        } catch {
            context.delete(checkout)
            try? context.save()
            try? fm.removeItem(at: checkoutPath)
            op.append("[muster] cleaned up partial checkout at \(checkoutPath.path)")
            op.fail(error.localizedDescription)
        }
    }
}

#Preview {
    NewCheckoutView(
        repository: Repository(
            slug: "github-user-repo",
            displayName: "repo",
            remoteURL: "git@github.com:user/repo.git",
            masterPath: "/Users/demo/.muster/repos/github-user-repo",
            defaultBranch: "main",
            packageManager: .pnpm
        )
    )
}
