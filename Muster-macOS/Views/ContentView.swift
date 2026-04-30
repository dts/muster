import SwiftUI
import SwiftData
import MusterCore

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Repository.displayName) private var repositories: [Repository]

    @State private var selection: SidebarSelection?
    @State private var showingAddRepo = false
    @State private var ingestBanner: String?

    private var allCheckouts: [Checkout] {
        repositories.flatMap(\.checkouts)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                repositories: repositories,
                selection: $selection,
                onAddRepository: { showingAddRepo = true }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            switch selection {
            case .checkout(let checkout):
                TerminalContainerView(checkout: checkout)
            case .operation(let op):
                OperationDetailView(operation: op, selection: $selection)
                    .id(op.id)
            case .none:
                VStack(spacing: 20) {
                    Image("Sheep")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 32))
                        .overlay(
                            RoundedRectangle(cornerRadius: 32)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                        )

                    if repositories.isEmpty {
                        Text("Welcome to Muster")
                            .font(.title2)
                            .fontWeight(.medium)
                        Text("Add a repository to get started")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 12) {
                            Label("Press **\u{2318}N** or click **+** to add a repository", systemImage: "1.circle.fill")
                            Label("Paste an SSH URL like `git@github.com:user/repo.git`", systemImage: "2.circle.fill")
                            Label("Create checkouts for each branch or feature you're working on", systemImage: "3.circle.fill")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    } else if allCheckouts.isEmpty {
                        Text("No Checkouts Yet")
                            .font(.title2)
                            .fontWeight(.medium)
                        Text("Create a checkout to start working")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 12) {
                            Label("Right-click a repository and choose **New Checkout**", systemImage: "1.circle.fill")
                            Label("Give it a name and pick a branch", systemImage: "2.circle.fill")
                            Label("Each checkout gets its own terminal and isolated workspace", systemImage: "3.circle.fill")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    } else {
                        Text("Select a Checkout")
                            .font(.title2)
                            .fontWeight(.medium)
                        Text("Click a checkout in the sidebar to open its terminal")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            if let banner = ingestBanner {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                        Text(banner).font(.caption)
                        Button {
                            withAnimation { ingestBanner = nil }
                        } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .sheet(isPresented: $showingAddRepo) {
            AddRepositoryView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addRepository)) { _ in
            showingAddRepo = true
        }
        .task {
            let result = await IngestService.shared.ingestOrphans(in: modelContext)
            var parts: [String] = []
            if !result.importedRepositories.isEmpty {
                parts.append("\(result.importedRepositories.count) repo\(result.importedRepositories.count == 1 ? "" : "s")")
            }
            if !result.importedCheckouts.isEmpty {
                parts.append("\(result.importedCheckouts.count) checkout\(result.importedCheckouts.count == 1 ? "" : "s")")
            }
            if result.refsMigrated > 0 {
                parts.append("refreshed refs on \(result.refsMigrated) checkout\(result.refsMigrated == 1 ? "" : "s")")
            }
            if !parts.isEmpty {
                withAnimation { ingestBanner = parts.joined(separator: ", ").capitalizedFirst }
            }
        }
        .onAppear {
            setupBranchMonitoring()
            SyncService.shared.start(context: modelContext, repositories: repositories)
        }
        .onChange(of: allCheckouts.map(\.path)) { _, newPaths in
            updateBranchMonitoring(for: newPaths)
        }
        .onChange(of: repositories.map(\.id)) { _, _ in
            SyncService.shared.sync(repositories: repositories)
        }
    }
}

extension ContentView {
    private func setupBranchMonitoring() {
        GitHeadMonitor.shared.onBranchChange = { change in
            handleBranchChange(change)
        }
        for checkout in allCheckouts {
            GitHeadMonitor.shared.startMonitoring(checkoutPath: checkout.path)
        }
    }

    private func updateBranchMonitoring(for paths: [String]) {
        GitHeadMonitor.shared.stopAll()
        for path in paths {
            GitHeadMonitor.shared.startMonitoring(checkoutPath: path)
        }
    }

    private func handleBranchChange(_ change: BranchChange) {
        guard let checkout = allCheckouts.first(where: { $0.path == change.checkoutPath }) else { return }
        if checkout.branch != change.newBranch {
            checkout.branch = change.newBranch
            try? modelContext.save()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(MusterCore.setupSchema())
}

private extension String {
    var capitalizedFirst: String {
        guard let first = self.first else { return self }
        return first.uppercased() + self.dropFirst()
    }
}
