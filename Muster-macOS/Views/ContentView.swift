import SwiftUI
import SwiftData
import MusterCore

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Repository.displayName) private var repositories: [Repository]

    @State private var selectedCheckout: Checkout?
    @State private var showingAddRepo = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                repositories: repositories,
                selectedCheckout: $selectedCheckout,
                onAddRepository: { showingAddRepo = true }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } detail: {
            if let checkout = selectedCheckout {
                TerminalContainerView(checkout: checkout)
            } else {
                ContentUnavailableView {
                    Label("No Checkout Selected", systemImage: "terminal")
                } description: {
                    Text("Select a checkout from the sidebar to open a terminal.")
                }
            }
        }
        .sheet(isPresented: $showingAddRepo) {
            AddRepositoryView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addRepository)) { _ in
            showingAddRepo = true
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(MusterCore.setupSchema())
}
