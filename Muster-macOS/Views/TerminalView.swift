import SwiftUI
import AppKit
import SwiftTerm
import MusterCore

final class MusterTerminalView: LocalProcessTerminalView {
    var workingDirectory: String = ""
    private var oscBuffer: [UInt8] = []
    private var inOSC99 = false

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configureScrollback() {
        let terminal = getTerminal()
        terminal.options = TerminalOptions(
            cols: terminal.cols,
            rows: terminal.rows,
            scrollback: 10000
        )
        terminal.setup(isReset: false)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        scanForOSC99(slice)
        super.dataReceived(slice: slice)
    }

    private func scanForOSC99(_ data: ArraySlice<UInt8>) {
        for byte in data {
            if inOSC99 {
                if byte == 0x07 || byte == 0x9C { // BEL or ST
                    processOSC99()
                    inOSC99 = false
                    oscBuffer.removeAll()
                } else if byte == 0x5C && oscBuffer.last == 0x1B { // ESC \ (ST)
                    oscBuffer.removeLast()
                    processOSC99()
                    inOSC99 = false
                    oscBuffer.removeAll()
                } else {
                    oscBuffer.append(byte)
                }
            } else {
                // Build up potential prefix
                if byte == 0x1B { // ESC
                    oscBuffer = [byte]
                } else if oscBuffer.count > 0 {
                    oscBuffer.append(byte)
                    // Check if we just completed the prefix ESC ] 9 9 ;
                    if oscBuffer == [0x1B, 0x5D, 0x39, 0x39, 0x3B] {
                        inOSC99 = true
                        oscBuffer.removeAll()
                    } else if oscBuffer.count > 5 {
                        oscBuffer.removeAll()
                    }
                }
            }
        }
    }

    private func processOSC99() {
        let payload = ArraySlice(oscBuffer)
        Task { @MainActor in
            TerminalStatusStore.shared.parseOSC99(payload, for: workingDirectory)
        }
    }

    func sendRedraw() {
        guard process.running else { return }
        kill(process.shellPid, SIGWINCH)
    }
}

@MainActor
final class TerminalCache {
    static let shared = TerminalCache()
    private var views: [String: MusterTerminalView] = [:]
    private var redrawTimer: Timer?

    private init() {
        startRedrawTimer()
    }

    private func startRedrawTimer() {
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.redrawAllTerminals()
            }
        }
    }

    private func redrawAllTerminals() {
        for (_, view) in views {
            view.sendRedraw()
        }
    }

    func view(for checkout: Checkout) -> MusterTerminalView {
        if let existing = views[checkout.path] {
            return existing
        }

        let terminalView = MusterTerminalView(frame: .zero)
        terminalView.workingDirectory = checkout.path
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var envDict = ProcessInfo.processInfo.environment
        envDict["TERM"] = "xterm-256color"
        envDict["COLORTERM"] = "truecolor"
        envDict["LANG"] = envDict["LANG"] ?? "en_US.UTF-8"

        var env: [String] = []
        for (key, value) in envDict {
            env.append("\(key)=\(value)")
        }

        env.append("MUSTER=1")
        env.append("MUSTER_CHECKOUT=\(checkout.path)")
        env.append("MUSTER_CHECKOUT_NAME=\(checkout.name)")
        env.append("MUSTER_BRANCH=\(checkout.branch)")
        if let repoName = checkout.repository?.displayName {
            env.append("MUSTER_REPO=\(repoName)")
        }

        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: "-" + (shell as NSString).lastPathComponent
        )
        terminalView.configureScrollback()

        if !checkout.path.isEmpty {
            terminalView.send(txt: "cd \(checkout.path.shellEscaped) && clear\n")
        }

        views[checkout.path] = terminalView
        return terminalView
    }

    func discard(path: String) {
        views.removeValue(forKey: path)
    }
}

struct TerminalView: NSViewRepresentable {
    let checkout: Checkout

    func makeNSView(context: Context) -> MusterTerminalView {
        let view = TerminalCache.shared.view(for: checkout)
        view.processDelegate = context.coordinator
        focus(view)
        return view
    }

    func updateNSView(_ nsView: MusterTerminalView, context: Context) {}

    private func focus(_ view: MusterTerminalView) {
        DispatchQueue.main.async {
            if let window = view.window {
                window.makeFirstResponder(view)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(workingDirectory: checkout.path)
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let workingDirectory: String

        init(workingDirectory: String) {
            self.workingDirectory = workingDirectory
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor in
                TerminalStatusStore.shared.setTitle(title.isEmpty ? nil : title, for: workingDirectory)
            }
        }

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
    TerminalView(checkout: Checkout(name: "preview", path: NSHomeDirectory(), branch: "main"))
        .frame(width: 600, height: 400)
}
