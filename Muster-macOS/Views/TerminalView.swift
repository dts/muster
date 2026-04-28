import SwiftUI
import AppKit
import SwiftTerm

struct TerminalView: NSViewRepresentable {
    let workingDirectory: String

    func makeNSView(context: Context) -> SwiftTerm.LocalProcessTerminalView {
        let terminalView = SwiftTerm.LocalProcessTerminalView(frame: .zero)
        terminalView.processDelegate = context.coordinator

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Pass full environment so CLI tools (claude, etc.) work properly
        var env: [String] = []
        for (key, value) in ProcessInfo.processInfo.environment {
            env.append("\(key)=\(value)")
        }

        // Start as login shell with working directory
        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: "-" + (shell as NSString).lastPathComponent
        )

        if !workingDirectory.isEmpty {
            terminalView.send(txt: "cd \(workingDirectory.shellEscaped) && clear\n")
        }

        return terminalView
    }

    func updateNSView(_ nsView: SwiftTerm.LocalProcessTerminalView, context: Context) {}

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
