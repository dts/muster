import SwiftUI
import AppKit
import SwiftTerm

final class MusterTerminalView: LocalProcessTerminalView {
    var workingDirectory: String = ""
    private var oscBuffer: [UInt8] = []
    private var inOSC99 = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        NSLog("[muster] MusterTerminalView init")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NSLog("[muster] MusterTerminalView init from coder")
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if slice.count > 0 && slice.count < 200 {
            NSLog("[muster] dataReceived: \(slice.count) bytes")
        }
        scanForOSC99(slice)
        super.dataReceived(slice: slice)
    }

    private func scanForOSC99(_ data: ArraySlice<UInt8>) {
        // Look for ESC ] 99 ; pattern in the raw data
        let dataArray = Array(data)
        if let escIdx = dataArray.firstIndex(of: 0x1B) {
            let remaining = dataArray[escIdx...]
            if remaining.count >= 5 {
                let prefix = Array(remaining.prefix(5))
                NSLog("[muster] Found ESC at \(escIdx), next 5 bytes: \(prefix.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
        }

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
        let payloadStr = String(bytes: payload, encoding: .utf8) ?? "(binary)"
        NSLog("[muster] OSC 99 received: \(payloadStr) for \(workingDirectory)")
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

    func view(for workingDirectory: String) -> MusterTerminalView {
        if let existing = views[workingDirectory] {
            NSLog("[muster] Returning cached terminal for \(workingDirectory)")
            return existing
        }

        NSLog("[muster] Creating new MusterTerminalView for \(workingDirectory)")
        let terminalView = MusterTerminalView(frame: .zero)
        terminalView.workingDirectory = workingDirectory
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var envDict = ProcessInfo.processInfo.environment
        envDict["TERM"] = "xterm-256color"
        envDict["COLORTERM"] = "truecolor"
        envDict["LANG"] = envDict["LANG"] ?? "en_US.UTF-8"

        var env: [String] = []
        for (key, value) in envDict {
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

    func makeNSView(context: Context) -> MusterTerminalView {
        let view = TerminalCache.shared.view(for: workingDirectory)
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
        Coordinator(workingDirectory: workingDirectory)
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let workingDirectory: String

        init(workingDirectory: String) {
            self.workingDirectory = workingDirectory
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            NSLog("[muster] Terminal title changed: '\(title)' for \(workingDirectory)")
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
    TerminalView(workingDirectory: NSHomeDirectory())
        .frame(width: 600, height: 400)
}
