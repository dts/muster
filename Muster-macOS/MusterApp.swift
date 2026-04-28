import SwiftUI
import SwiftData
import MusterCore

@main
struct MusterApp: App {
    let container: ModelContainer

    init() {
        container = MusterCore.setupSchema()
        Task {
            try? await MusterCore.initialize()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Repository...") {
                    NotificationCenter.default.post(name: .addRepository, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("New Checkout...") {
                    NotificationCenter.default.post(name: .newCheckout, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let addRepository = Notification.Name("addRepository")
    static let newCheckout = Notification.Name("newCheckout")
}
