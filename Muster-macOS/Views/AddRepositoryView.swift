import SwiftUI
import SwiftData
import MusterCore

struct AddRepositoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var remoteURL = ""
    @State private var isCloning = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Repository")
                .font(.headline)

            TextField("SSH URL (git@github.com:user/repo.git)", text: $remoteURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)

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

                Button("Add") {
                    Task {
                        await addRepository()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(remoteURL.isEmpty || isCloning)
            }

            if isCloning {
                ProgressView("Cloning repository...")
            }
        }
        .padding(30)
        .frame(minWidth: 450)
    }

    private func addRepository() async {
        isCloning = true
        error = nil

        do {
            let slug = Repository.slug(from: remoteURL)
            let displayName = Repository.displayName(from: remoteURL)
            let masterPath = PathService.shared.masterPath(for: slug)

            try await GitService.shared.clone(url: remoteURL, to: masterPath)

            let defaultBranch = try await GitService.shared.defaultBranch(at: masterPath)
            let packageManager = await PackageManagerService.shared.detect(at: masterPath)

            if let pm = packageManager {
                _ = try await PackageManagerService.shared.install(at: masterPath, packageManager: pm, offline: false)
            }

            let repository = Repository(
                slug: slug,
                displayName: displayName,
                remoteURL: remoteURL,
                masterPath: masterPath.path,
                defaultBranch: defaultBranch,
                packageManager: packageManager
            )

            modelContext.insert(repository)
            try modelContext.save()

            await MainActor.run {
                dismiss()
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isCloning = false
            }
        }
    }
}

#Preview {
    AddRepositoryView()
}
