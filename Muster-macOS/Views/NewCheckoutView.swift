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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Checkout").font(.headline)
            Text("Repository: \(repository.displayName)")
                .foregroundStyle(.secondary)

            TextField("Checkout name (e.g., feature-auth)", text: $name)
                .textFieldStyle(.roundedBorder)
            Toggle("Create new branch", isOn: $createNewBranch)

            if createNewBranch {
                TextField("Branch name", text: $branch)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("Branch (default: \(repository.defaultBranch))", text: $branch)
                    .textFieldStyle(.roundedBorder)
            }

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
        .onAppear { branch = repository.defaultBranch }
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
        var weCreatedDir = false
        var insertedCheckout: Checkout?

        do {
            if fm.fileExists(atPath: checkoutPath.path) {
                let pathString = checkoutPath.path
                let claimed = captured.repo.checkouts.contains { $0.path == pathString }
                if claimed {
                    throw NSError(domain: "Muster", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "A checkout named \"\(sluggedName)\" already exists for this repo."
                    ])
                }
                op.append("[muster] removing orphaned dir at \(pathString)")
                try fm.removeItem(at: checkoutPath)
            }

            op.setStatus("Cloning from master…")
            for try await line in GitService.shared.cloneLocalStreaming(from: masterPath, to: checkoutPath) {
                op.append(line)
            }
            weCreatedDir = true

            op.setStatus("Copying refs from master…")
            try await GitService.shared.copyRemoteRefs(from: masterPath, at: checkoutPath)

            op.setStatus("Configuring remote…")
            try await GitService.shared.setRemoteURL(captured.repo.remoteURL, at: checkoutPath)

            let target = captured.branch.isEmpty ? captured.repo.defaultBranch : captured.branch

            if captured.createNewBranch {
                op.setStatus("Creating branch \(target)…")
                try await GitService.shared.createBranch(target, at: checkoutPath)
            } else {
                do {
                    op.setStatus("Checking out \(target)…")
                    try await GitService.shared.checkout(branch: target, at: checkoutPath)
                } catch {
                    op.setStatus("Branch not local — fetching \(target) from origin…")
                    for try await line in GitService.shared.fetchBranchStreaming(target, at: checkoutPath) {
                        op.append(line)
                    }
                    op.setStatus("Checking out \(target)…")
                    try await GitService.shared.checkout(branch: target, at: checkoutPath)
                }
            }

            let checkout = Checkout(name: sluggedName, path: checkoutPath.path, branch: target)
            checkout.repository = captured.repo
            context.insert(checkout)
            try context.save()
            insertedCheckout = checkout
            op.append("[muster] checkout ready — installing deps in background")

            if let pm = captured.repo.packageManager {
                op.setStatus("Installing dependencies (\(pm.rawValue), offline)…")
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
                    op.fail("Dependency install failed: \(error.localizedDescription)")
                    return
                }
            }

            op.succeed()
        } catch {
            if weCreatedDir, insertedCheckout == nil {
                try? fm.removeItem(at: checkoutPath)
                op.append("[muster] cleaned up partial checkout at \(checkoutPath.path)")
            }
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
