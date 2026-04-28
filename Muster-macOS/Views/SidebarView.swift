import SwiftUI
import SwiftData
import MusterCore

struct SidebarView: View {
    let repositories: [Repository]
    @Binding var selectedCheckout: Checkout?
    let onAddRepository: () -> Void

    @State private var expandedRepos: Set<UUID> = []
    @State private var repoForNewCheckout: Repository?

    var body: some View {
        List(selection: $selectedCheckout) {
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
                            .tag(checkout)
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
                }
            }
        }
        .sheet(item: $repoForNewCheckout) { repo in
            NewCheckoutView(repository: repo)
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
                Text(checkout.name)
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
