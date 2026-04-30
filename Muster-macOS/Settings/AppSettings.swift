import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("tmuxEnabled") var tmuxEnabled: Bool = true
    @AppStorage("tmuxPath") var tmuxPath: String = AppSettings.defaultTmuxPath()
    @AppStorage("tmuxPlayNice") var tmuxPlayNice: Bool = false

    private init() {}

    static func defaultTmuxPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/opt/homebrew/bin/tmux"
    }
}
