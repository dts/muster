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
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("New Checkout")
                .font(.headline)

            Text("Repository: \(repository.displayName)")
                .foregroundStyle(.secondary)

            TextField("Checkout name (e.g., feature-auth)", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 350)

            Toggle("Create new branch", isOn: $createNewBranch)

            if createNewBranch {
                TextField("Branch name", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)
            } else {
                TextField("Branch to checkout (default: \(repository.defaultBranch))", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    Task {
                        await createCheckout()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || isCreating)
            }

            if isCreating {
                ProgressView("Creating checkout...")
            }
        }
        .padding(30)
        .frame(minWidth: 400)
        .onAppear {
            branch = repository.defaultBranch
        }
    }

    private func createCheckout() async {
        isCreating = true
        error = nil

        do {
            let sluggedName = PathService.shared.slugify(name)
            let checkoutPath = PathService.shared.checkoutPath(
                repoDisplayName: repository.displayName,
                checkoutName: sluggedName
            )
            let masterPath = URL(fileURLWithPath: repository.masterPath)

            try await GitService.shared.cloneLocal(from: masterPath, to: checkoutPath)
            try await GitService.shared.setRemoteURL(repository.remoteURL, at: checkoutPath)

            let targetBranch = branch.isEmpty ? repository.defaultBranch : branch

            if createNewBranch {
                try await GitService.shared.createBranch(targetBranch, at: checkoutPath)
            } else {
                try await GitService.shared.checkout(branch: targetBranch, at: checkoutPath)
            }

            if let pm = repository.packageManager {
                let result = try await PackageManagerService.shared.install(at: checkoutPath, packageManager: pm, offline: true)
                if let reason = result.fallbackReason {
                    print("[Muster] \(reason)")
                }
            }

            let checkout = Checkout(
                name: sluggedName,
                path: checkoutPath.path,
                branch: targetBranch
            )
            checkout.repository = repository

            modelContext.insert(checkout)
            try modelContext.save()

            await MainActor.run {
                dismiss()
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isCreating = false
            }
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
