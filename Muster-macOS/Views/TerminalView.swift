import SwiftUI
import AppKit
import SwiftTerm

/// SwiftTerm's default scrollWheel handler scrolls its own (mostly empty) buffer
/// instead of forwarding to the running process. When tmux has mouse mode on we
/// want the wheel to go through so tmux's WheelUpPane binding fires.
/// scrollWheel isn't `open` so we install our behavior via Obj-C swizzling.
enum TerminalWheelForwarding {
    private static let wheelUpFlag = 64
    private static let wheelDownFlag = 65

    static let install: Void = {
        let cls: AnyClass = SwiftTerm.LocalProcessTerminalView.self
        let originalSel = #selector(NSResponder.scrollWheel(with:))
        let replacementSel = #selector(SwiftTerm.LocalProcessTerminalView.muster_scrollWheel(with:))

        guard let original = class_getInstanceMethod(cls, originalSel),
              let replacement = class_getInstanceMethod(cls, replacementSel)
        else { return }

        method_exchangeImplementations(original, replacement)
    }()

    static func forward(_ view: SwiftTerm.LocalProcessTerminalView, event: NSEvent) -> Bool {
        guard event.deltaY != 0, view.terminal.mouseMode != .off else { return false }
        let flag = event.deltaY > 0 ? wheelUpFlag : wheelDownFlag
        let ticks = max(1, min(5, Int(abs(event.deltaY))))
        for _ in 0..<ticks {
            view.terminal.sendEvent(buttonFlags: flag, x: 1, y: 1, pixelX: 0, pixelY: 0)
        }
        return true
    }
}

extension SwiftTerm.LocalProcessTerminalView {
    @objc func muster_scrollWheel(with event: NSEvent) {
        if TerminalWheelForwarding.forward(self, event: event) {
            return
        }
        // After swizzling, this selector points to the *original* implementation.
        muster_scrollWheel(with: event)
    }
}

@MainActor
final class TerminalCache {
    static let shared = TerminalCache()
    private var views: [String: SwiftTerm.LocalProcessTerminalView] = [:]
    private init() {}

    func view(for workingDirectory: String) -> SwiftTerm.LocalProcessTerminalView {
        if let existing = views[workingDirectory] {
            return existing
        }

        _ = TerminalWheelForwarding.install
        let terminalView = SwiftTerm.LocalProcessTerminalView(frame: .zero)

        var envDict = ProcessInfo.processInfo.environment
        envDict["TERM"] = "xterm-256color"
        envDict["LANG"] = envDict["LANG"] ?? "en_US.UTF-8"
        envDict["LC_ALL"] = envDict["LC_ALL"] ?? "en_US.UTF-8"
        let env = envDict.map { "\($0.key)=\($0.value)" }

        let settings = AppSettings.shared
        if settings.tmuxEnabled, FileManager.default.isExecutableFile(atPath: settings.tmuxPath) {
            terminalView.startProcess(
                executable: settings.tmuxPath,
                args: [
                    "-L", "muster",
                    "-f", ensureTmuxConfig(),
                    "new-session", "-A",
                    "-s", tmuxSessionName(for: workingDirectory),
                    "-c", workingDirectory
                ],
                environment: env,
                execName: "tmux"
            )
        } else {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            terminalView.startProcess(
                executable: shell,
                args: ["-l"],
                environment: env,
                execName: "-" + (shell as NSString).lastPathComponent
            )
            if !workingDirectory.isEmpty {
                terminalView.send(txt: "cd \(workingDirectory.shellEscaped) && clear\n")
            }
        }

        views[workingDirectory] = terminalView
        return terminalView
    }

    private func ensureTmuxConfig() -> String {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Muster", isDirectory: true)
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let configURL = supportDir.appendingPathComponent("tmux.conf")

        let playNice = AppSettings.shared.tmuxPlayNice
        let statusLine = playNice ? "set -g status on" : "set -g status off"
        // In strict mode we just disable the prefix keys — bindings stay in
        // place so live-toggling back to play-nice is reversible.
        let prefixBlock = playNice
            ? "set -gu prefix\nset -gu prefix2"
            : "set -g prefix None\nset -g prefix2 None"

        let contents = """
        # Managed by Muster — generated tmux config for embedded terminals.
        source-file -q ~/.tmux.conf
        set -g history-limit 100000
        set -g mouse on
        set -g default-terminal "xterm-256color"
        \(statusLine)
        \(prefixBlock)

        # Scroll wheel: enter copy-mode at the shell prompt and scroll naturally.
        # Inside alt-screen apps (vim/less/etc), forward the wheel event instead.
        bind-key -T root WheelUpPane \
            if-shell -F -t = "#{?pane_in_mode,1,#{alternate_on}}" \
                "send-keys -M" \
                "copy-mode -e; send-keys -M"
        bind-key -T root WheelDownPane \
            if-shell -F -t = "#{?pane_in_mode,1,#{alternate_on}}" \
                "send-keys -M" \
                ""

        # Faster, line-by-line scrolling inside copy-mode.
        bind-key -T copy-mode WheelUpPane   send-keys -X -N 3 scroll-up
        bind-key -T copy-mode WheelDownPane send-keys -X -N 3 scroll-down
        bind-key -T copy-mode-vi WheelUpPane   send-keys -X -N 3 scroll-up
        bind-key -T copy-mode-vi WheelDownPane send-keys -X -N 3 scroll-down
        """

        if (try? String(contentsOf: configURL)) != contents {
            try? contents.write(to: configURL, atomically: true, encoding: .utf8)
        }
        return configURL.path
    }

    func discard(workingDirectory: String) {
        views.removeValue(forKey: workingDirectory)
    }

    /// Rewrite the Muster tmux config and source it into the running -L muster
    /// server (if any). Call this when settings that affect the config change.
    func applySettingsToRunningServer() {
        let configPath = ensureTmuxConfig()

        let tmuxPath = AppSettings.shared.tmuxPath
        guard FileManager.default.isExecutableFile(atPath: tmuxPath) else { return }

        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: tmuxPath)
        probe.arguments = ["-L", "muster", "list-sessions"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }

        let source = Process()
        source.executableURL = URL(fileURLWithPath: tmuxPath)
        source.arguments = ["-L", "muster", "source-file", configPath]
        source.standardOutput = FileHandle.nullDevice
        source.standardError = FileHandle.nullDevice
        try? source.run()
        source.waitUntilExit()
    }

    private func tmuxSessionName(for path: String) -> String {
        let sanitized = path
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "muster_\(sanitized)"
    }
}

/// Shared NSView that hosts every cached LocalProcessTerminalView as a permanent
/// subview. Switching between checkouts toggles `isHidden` instead of re-parenting,
/// avoiding the layout/SIGWINCH/full-redraw cycle that tmux fires on every reattach.
@MainActor
final class TerminalSwitcherNSView: NSView {
    private var hosted: [String: SwiftTerm.LocalProcessTerminalView] = [:]
    private weak var activeTerminal: SwiftTerm.LocalProcessTerminalView?

    func show(workingDirectory: String, delegate: LocalProcessTerminalViewDelegate) {
        let terminal = TerminalCache.shared.view(for: workingDirectory)
        terminal.processDelegate = delegate

        if hosted[workingDirectory] == nil {
            terminal.translatesAutoresizingMaskIntoConstraints = false
            addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                terminal.topAnchor.constraint(equalTo: topAnchor),
                terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hosted[workingDirectory] = terminal
        }

        for (key, view) in hosted {
            view.isHidden = (key != workingDirectory)
        }
        activeTerminal = terminal

        DispatchQueue.main.async { [weak terminal] in
            guard let terminal, let window = terminal.window else { return }
            window.makeFirstResponder(terminal)
        }
    }
}

struct TerminalView: NSViewRepresentable {
    let workingDirectory: String

    func makeNSView(context: Context) -> TerminalSwitcherNSView {
        let switcher = TerminalSwitcherNSView()
        switcher.show(workingDirectory: workingDirectory, delegate: context.coordinator)
        return switcher
    }

    func updateNSView(_ nsView: TerminalSwitcherNSView, context: Context) {
        nsView.show(workingDirectory: workingDirectory, delegate: context.coordinator)
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
