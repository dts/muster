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
                VStack(spacing: 16) {
                    Image("Sheep")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                    Text("No Checkout Selected")
                        .font(.title2)
                        .fontWeight(.medium)
                    Text("Select a checkout from the sidebar to open a terminal.")
                        .foregroundStyle(.secondary)
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
        }
        .onChange(of: allCheckouts.map(\.path)) { _, newPaths in
            updateBranchMonitoring(for: newPaths)
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
