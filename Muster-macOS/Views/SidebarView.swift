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
    @State private var checkoutToDelete: Checkout?
    @State private var repoToDelete: Repository?

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
                                        if case .operation(let selOp) = selection, selOp === op {
                                            selection = nil
                                        }
                                        store.dismiss(op)
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
                        ForEach(repo.checkouts) { checkout in
                            CheckoutRow(checkout: checkout)
                                .tag(SidebarSelection.checkout(checkout))
                                .contextMenu {
                                    Button(role: .destructive) {
                                        checkoutToDelete = checkout
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
                                    repoToDelete = repo
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
            "Delete checkout \"\(checkoutToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { checkoutToDelete != nil },
                set: { if !$0 { checkoutToDelete = nil } }
            ),
            presenting: checkoutToDelete
        ) { checkout in
            Button("Delete", role: .destructive) {
                delete(checkout: checkout)
            }
            Button("Cancel", role: .cancel) {}
        } message: { checkout in
            Text("This removes the directory at \(checkout.path). Any uncommitted changes will be lost.")
        }
        .alert(
            "Delete repository \"\(repoToDelete?.displayName ?? "")\"?",
            isPresented: Binding(
                get: { repoToDelete != nil },
                set: { if !$0 { repoToDelete = nil } }
            ),
            presenting: repoToDelete
        ) { repo in
            Button("Delete Everything", role: .destructive) {
                delete(repository: repo)
            }
            Button("Cancel", role: .cancel) {}
        } message: { repo in
            let n = repo.checkouts.count
            let checkoutBit = n == 0
                ? "(no checkouts)"
                : "and \(n) checkout\(n == 1 ? "" : "s") under ~/muster/\(repo.displayName)"
            Text("This removes the master copy at \(repo.masterPath) \(checkoutBit). This cannot be undone.")
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

    private func delete(checkout: Checkout) {
        if case .checkout(let sel) = selection, sel == checkout {
            selection = nil
        }
        TerminalCache.shared.discard(checkoutId: checkout.id)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: checkout.path))
        modelContext.delete(checkout)
        try? modelContext.save()
    }

    private func delete(repository: Repository) {
        if case .checkout(let sel) = selection, sel.repository?.id == repository.id {
            selection = nil
        }
        for checkout in repository.checkouts {
            TerminalCache.shared.discard(checkoutId: checkout.id)
        }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: repository.masterPath))
        let checkoutsRoot = PathService.shared.checkoutsDir
            .appendingPathComponent(repository.displayName, isDirectory: true)
        try? FileManager.default.removeItem(at: checkoutsRoot)
        modelContext.delete(repository)
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
    @State private var attention = AttentionStore.shared

    var body: some View {
        HStack {
            Image(systemName: "arrow.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkout.name)
                Text(checkout.branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if attention.hasUnread(for: checkout.id) {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
            }

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
