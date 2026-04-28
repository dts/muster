import SwiftUI
import SwiftData
import MusterCore

struct AddRepositoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var remoteURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Repository")
                .font(.headline)

            TextField("SSH URL (git@github.com:user/repo.git)", text: $remoteURL)
                .textFieldStyle(.roundedBorder)

            Text("Cloning runs in the background — close this and start more.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(remoteURL.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }

    private func submit() {
        let url = remoteURL
        let displayName = Repository.displayName(from: url)
        let op = Operation(title: "Clone \(displayName)", subtitle: url)
        OperationStore.shared.add(op)
        let context = modelContext
        Task { @MainActor in
            await runClone(url: url, op: op, context: context)
        }
        dismiss()
    }

    @MainActor
    private func runClone(url: String, op: Operation, context: ModelContext) async {
        do {
            let slug = Repository.slug(from: url)
            let displayName = Repository.displayName(from: url)
            let masterPath = PathService.shared.masterPath(for: slug)

            op.setStatus("Cloning repository…")
            for try await line in GitService.shared.cloneStreaming(url: url, to: masterPath) {
                op.append(line)
            }

            op.setStatus("Resolving default branch…")
            let defaultBranch = try await GitService.shared.defaultBranch(at: masterPath)

            let pm = await PackageManagerService.shared.detect(at: masterPath)

            let repository = Repository(
                slug: slug,
                displayName: displayName,
                remoteURL: url,
                masterPath: masterPath.path,
                defaultBranch: defaultBranch,
                packageManager: pm
            )
            context.insert(repository)
            try context.save()

            if let pm {
                op.setStatus("Installing dependencies (\(pm.rawValue))…")
                op.append("[muster] running \(pm.installCommand.joined(separator: " "))")
                for try await line in PackageManagerService.shared.installStreaming(
                    at: masterPath, packageManager: pm, offline: false
                ) {
                    op.append(line)
                }
            }

            op.succeed()
        } catch {
            op.fail(error.localizedDescription)
        }
    }
}

#Preview {
    AddRepositoryView()
}
