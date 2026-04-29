import SwiftUI
import SwiftData
import MusterCore

enum SidebarSelection: Hashable {
    case checkout(Checkout)
    case operation(Operation)
}

struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext

    let repositories: [Repository]
    @Binding var selection: SidebarSelection?
    let onAddRepository: () -> Void

    @State private var store = OperationStore.shared
    @State private var expandedRepos: Set<UUID> = []
    @State private var repoForNewCheckout: Repository?
    @State private var dirtyCheckoutToDelete: Checkout?
    @State private var dirtyRepoToDelete: Repository?
    @State private var checkoutToRename: Checkout?
    @State private var renameText: String = ""
    @State private var dropTargetId: UUID?
    @State private var draggingCheckoutId: UUID?

    private var selectedCheckoutBinding: Binding<Checkout?> {
        Binding(
            get: {
                if case .checkout(let c) = selection { return c }
                return nil
            },
            set: { newValue in
                selection = newValue.map { .checkout($0) }
            }
        )
    }

    var body: some View {
        List(selection: $selection) {
            if !store.operations.isEmpty {
                Section("In Progress") {
                    ForEach(store.operations) { op in
                        OperationSidebarRow(operation: op)
                            .tag(SidebarSelection.operation(op))
                            .contextMenu {
                                if op.status.isTerminal {
                                    Button(role: .destructive) {
                                        dismissAndSelectNext(op)
                                    } label: {
                                        Label("Dismiss", systemImage: "xmark.circle")
                                    }
                                }
                            }
                    }
                }
            }

            Section("Repositories") {
                ForEach(repositories) { repo in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedRepos.contains(repo.id) },
                            set: { isExpanded in
                                if isExpanded {
                                    expandedRepos.insert(repo.id)
                                } else {
                                    expandedRepos.remove(repo.id)
                                }
                            }
                        )
                    ) {
                        ForEach(sortedCheckouts(for: repo)) { checkout in
                            VStack(spacing: 0) {
                                if dropTargetId == checkout.id && draggingCheckoutId != nil && draggingCheckoutId != checkout.id {
                                    InsertionMarker()
                                }
                                CheckoutRow(checkout: checkout)
                                    .opacity(checkout.id == draggingCheckoutId ? 0.3 : 1.0)
                            }
                            .tag(SidebarSelection.checkout(checkout))
                            .draggable(checkout.id.uuidString) {
                                Text(checkout.resolvedDisplayName)
                                    .padding(8)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(4)
                                    .onAppear { draggingCheckoutId = checkout.id }
                            }
                            .dropDestination(for: String.self) { items, _ in
                                let targetId = checkout.id
                                dropTargetId = nil
                                draggingCheckoutId = nil
                                guard let draggedId = items.first,
                                      let draggedUUID = UUID(uuidString: draggedId) else { return false }
                                reorderCheckout(draggedId: draggedUUID, onto: targetId, in: repo)
                                return true
                            } isTargeted: { isTargeted in
                                dropTargetId = isTargeted ? checkout.id : nil
                            }
                            .contextMenu {
                                Button {
                                    renameText = checkout.resolvedDisplayName
                                    checkoutToRename = checkout
                                } label: {
                                    Label("Rename…", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    requestDeleteCheckout(checkout)
                                } label: {
                                    Label("Delete Checkout…", systemImage: "trash")
                                }
                            }
                        }

                        Button {
                            repoForNewCheckout = repo
                        } label: {
                            Label("New Checkout", systemImage: "plus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } label: {
                        RepositoryRow(repository: repo)
                            .contextMenu {
                                Button {
                                    repoForNewCheckout = repo
                                } label: {
                                    Label("New Checkout…", systemImage: "plus.circle")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    requestDeleteRepository(repo)
                                } label: {
                                    Label("Delete Repository…", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .sheet(item: $repoForNewCheckout) { repo in
            NewCheckoutView(repository: repo)
        }
        .alert(
            "Delete checkout \"\(dirtyCheckoutToDelete?.resolvedDisplayName ?? "")\"?",
            isPresented: Binding(
                get: { dirtyCheckoutToDelete != nil },
                set: { if !$0 { dirtyCheckoutToDelete = nil } }
            ),
            presenting: dirtyCheckoutToDelete
        ) { checkout in
            Button("Delete", role: .destructive) {
                performDeleteCheckout(checkout)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This checkout has uncommitted changes that will be lost.")
        }
        .alert(
            "Delete repository \"\(dirtyRepoToDelete?.displayName ?? "")\"?",
            isPresented: Binding(
                get: { dirtyRepoToDelete != nil },
                set: { if !$0 { dirtyRepoToDelete = nil } }
            ),
            presenting: dirtyRepoToDelete
        ) { repo in
            Button("Delete Everything", role: .destructive) {
                performDeleteRepository(repo)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("One or more checkouts have uncommitted changes that will be lost.")
        }
        .alert(
            "Rename Checkout",
            isPresented: Binding(
                get: { checkoutToRename != nil },
                set: { if !$0 { checkoutToRename = nil } }
            ),
            presenting: checkoutToRename
        ) { checkout in
            TextField("Name", text: $renameText)
            Button("Rename") {
                checkout.displayName = renameText
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Enter a new display name for this checkout.")
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button(action: onAddRepository) {
                    Label("Add Repository", systemImage: "plus")
                }
            }
        }
        .onAppear {
            expandedRepos = Set(repositories.map(\.id))
        }
    }

    private func dismissAndSelectNext(_ op: Operation) {
        if case .operation(let selOp) = selection, selOp === op {
            let operations = store.operations
            if let currentIndex = operations.firstIndex(where: { $0 === op }) {
                if currentIndex + 1 < operations.count {
                    selection = .operation(operations[currentIndex + 1])
                } else if currentIndex > 0 {
                    selection = .operation(operations[currentIndex - 1])
                } else {
                    selection = nil
                }
            }
        }
        store.dismiss(op)
    }

    private func requestDeleteCheckout(_ checkout: Checkout) {
        Task {
            let isDirty = (try? await GitService.shared.hasUncommittedChanges(
                at: URL(fileURLWithPath: checkout.path)
            )) ?? false
            if isDirty {
                dirtyCheckoutToDelete = checkout
            } else {
                performDeleteCheckout(checkout)
            }
        }
    }

    private func requestDeleteRepository(_ repo: Repository) {
        Task {
            var hasDirty = false
            for checkout in repo.checkouts {
                if (try? await GitService.shared.hasUncommittedChanges(
                    at: URL(fileURLWithPath: checkout.path)
                )) == true {
                    hasDirty = true
                    break
                }
            }
            if hasDirty {
                dirtyRepoToDelete = repo
            } else {
                performDeleteRepository(repo)
            }
        }
    }

    private func performDeleteCheckout(_ checkout: Checkout) {
        if case .checkout(let sel) = selection, sel == checkout {
            selection = nil
        }
        let path = checkout.path
        let name = checkout.resolvedDisplayName
        modelContext.delete(checkout)
        try? modelContext.save()

        let op = Operation(title: "Deleting checkout", subtitle: name)
        store.add(op)
        Task.detached {
            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                await MainActor.run { op.succeed() }
            } catch {
                await MainActor.run { op.fail(error.localizedDescription) }
            }
        }
    }

    private func performDeleteRepository(_ repo: Repository) {
        if case .checkout(let sel) = selection, sel.repository?.id == repo.id {
            selection = nil
        }
        let masterPath = repo.masterPath
        let displayName = repo.displayName
        modelContext.delete(repo)
        try? modelContext.save()

        let op = Operation(title: "Deleting repository", subtitle: displayName)
        store.add(op)
        Task.detached {
            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: masterPath))
                let checkoutsRoot = PathService.shared.checkoutsDir
                    .appendingPathComponent(displayName, isDirectory: true)
                try? FileManager.default.removeItem(at: checkoutsRoot)
                await MainActor.run { op.succeed() }
            } catch {
                await MainActor.run { op.fail(error.localizedDescription) }
            }
        }
    }

    private func sortedCheckouts(for repo: Repository) -> [Checkout] {
        repo.checkouts.sorted { a, b in
            if a.order != b.order {
                return a.order < b.order
            }
            return a.createdAt < b.createdAt
        }
    }

    private func reorderCheckout(draggedId: UUID, onto targetId: UUID, in repo: Repository) {
        guard let dragged = repo.checkouts.first(where: { $0.id == draggedId }),
              draggedId != targetId else { return }

        var sorted = sortedCheckouts(for: repo)
        sorted.removeAll { $0.id == dragged.id }

        if let targetIndex = sorted.firstIndex(where: { $0.id == targetId }) {
            sorted.insert(dragged, at: targetIndex)
        }

        for (index, checkout) in sorted.enumerated() {
            checkout.order = index
        }
        try? modelContext.save()
    }
}

struct RepositoryRow: View {
    let repository: Repository

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
            Text(repository.displayName)
                .fontWeight(.medium)

            Spacer()

            SyncStateIndicator(state: repository.syncState)
        }
    }
}

struct CheckoutRow: View {
    let checkout: Checkout

    var body: some View {
        HStack {
            Image(systemName: "arrow.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkout.resolvedDisplayName)
                Text(checkout.branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            DepsStateIndicator(state: checkout.depsState)
        }
        .padding(.leading, 8)
    }
}

struct SyncStateIndicator: View {
    let state: SyncState

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .fetching, .pulling, .installingDeps:
            ProgressView()
                .scaleEffect(0.6)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
        }
    }
}

struct DepsStateIndicator: View {
    let state: DepsState

    var body: some View {
        switch state {
        case .current, .notApplicable:
            EmptyView()
        case .installing:
            ProgressView()
                .scaleEffect(0.5)
        case .stale:
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
                .font(.caption)
        case .error:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}

struct InsertionMarker: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
    }
}
