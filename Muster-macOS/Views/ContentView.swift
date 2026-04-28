import SwiftUI
import SwiftData
import MusterCore

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Repository.displayName) private var repositories: [Repository]

    @State private var selection: SidebarSelection?
    @State private var showingAddRepo = false
    @State private var ingestBanner: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                repositories: repositories,
                selection: $selection,
                onAddRepository: { showingAddRepo = true }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if let banner = ingestBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                        Text(banner).font(.caption)
                        Spacer()
                        Button {
                            withAnimation { ingestBanner = nil }
                        } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12))
                }

                switch selection {
                case .checkout(let checkout):
                    TerminalContainerView(checkout: checkout)
                case .operation(let op):
                    OperationDetailView(operation: op)
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
                try? await Task.sleep(for: .seconds(6))
                withAnimation { ingestBanner = nil }
            }
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
