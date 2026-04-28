import SwiftUI
import AppKit
import SwiftTerm

@MainActor
final class TerminalCache {
    static let shared = TerminalCache()
    private var views: [String: SwiftTerm.LocalProcessTerminalView] = [:]
    private init() {}

    func view(for workingDirectory: String) -> SwiftTerm.LocalProcessTerminalView {
        if let existing = views[workingDirectory] {
            return existing
        }

        let terminalView = SwiftTerm.LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var env: [String] = []
        for (key, value) in ProcessInfo.processInfo.environment {
            env.append("\(key)=\(value)")
        }

        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: "-" + (shell as NSString).lastPathComponent
        )

        if !workingDirectory.isEmpty {
            terminalView.send(txt: "cd \(workingDirectory.shellEscaped) && clear\n")
        }

        views[workingDirectory] = terminalView
        return terminalView
    }

    func discard(workingDirectory: String) {
        views.removeValue(forKey: workingDirectory)
    }
}

struct TerminalView: NSViewRepresentable {
    let workingDirectory: String

    func makeNSView(context: Context) -> SwiftTerm.LocalProcessTerminalView {
        let view = TerminalCache.shared.view(for: workingDirectory)
        view.processDelegate = context.coordinator
        focus(view)
        return view
    }

    func updateNSView(_ nsView: SwiftTerm.LocalProcessTerminalView, context: Context) {}

    private func focus(_ view: SwiftTerm.LocalProcessTerminalView) {
        DispatchQueue.main.async {
            if let window = view.window {
                window.makeFirstResponder(view)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: SwiftTerm.LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: SwiftTerm.LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {}
    }
}

extension String {
    var shellEscaped: String {
        "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

#Preview {
    TerminalView(workingDirectory: NSHomeDirectory())
        .frame(width: 600, height: 400)
}
