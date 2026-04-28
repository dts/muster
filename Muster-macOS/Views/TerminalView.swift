import SwiftUI
import AppKit
import SwiftTerm
import MusterCore

@MainActor
final class TerminalCache {
    static let shared = TerminalCache()
    private var views: [UUID: RemoteTerminalView] = [:]
    private init() {}

    func view(for checkoutId: UUID, cwd: String) -> RemoteTerminalView {
        if let existing = views[checkoutId] {
            return existing
        }
        let v = RemoteTerminalView(checkoutId: checkoutId, cwd: cwd)
        views[checkoutId] = v
        return v
    }

    func discard(checkoutId: UUID) {
        if let v = views.removeValue(forKey: checkoutId) {
            v.disconnectAndKill()
        }
        AttentionStore.shared.discard(checkoutId: checkoutId)
    }
}

@MainActor
final class RemoteTerminalView: SwiftTerm.TerminalView, TerminalViewDelegate {
    let checkoutId: UUID
    private let cwd: String
    private var session: ShellSession?
    private var pumpTask: Task<Void, Never>?

    init(checkoutId: UUID, cwd: String) {
        self.checkoutId = checkoutId
        self.cwd = cwd
        super.init(frame: .zero)
        self.terminalDelegate = self
        Task { [weak self] in
            await self?.connect()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func connect() async {
        let term = getTerminal()
        let cols = UInt16(max(term.cols, 80))
        let rows = UInt16(max(term.rows, 24))
        do {
            let s = try await ShellHostClient.shared.attach(
                checkoutId: checkoutId,
                cwd: cwd,
                env: ProcessInfo.processInfo.environment,
                cols: cols,
                rows: rows
            )
            self.session = s
            self.pumpTask = Task { [weak self] in
                for await data in s.output {
                    let bytes = [UInt8](data)
                    await MainActor.run {
                        self?.feed(byteArray: bytes[...])
                    }
                }
            }
        } catch {
            let msg = "Muster: shell host unavailable — \(error)\r\n"
            feed(text: msg)
        }
    }

    func disconnectAndKill() {
        pumpTask?.cancel()
        pumpTask = nil
        session?.kill()
        session = nil
    }

    deinit {
        pumpTask?.cancel()
    }

    // MARK: - TerminalViewDelegate

    nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        Task { @MainActor [weak self] in
            self?.session?.send(bytes)
        }
    }

    nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        let cols = UInt16(newCols)
        let rows = UInt16(newRows)
        Task { @MainActor [weak self] in
            self?.session?.resize(cols: cols, rows: rows)
        }
    }

    nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        Task { @MainActor in
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
    }
    nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    nonisolated func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func bell(source: SwiftTerm.TerminalView) {}
    nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {
        if let url = URL(string: link) {
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
    }
}

struct TerminalView: NSViewRepresentable {
    let checkoutId: UUID
    let workingDirectory: String

    func makeNSView(context: Context) -> RemoteTerminalView {
        let view = TerminalCache.shared.view(for: checkoutId, cwd: workingDirectory)
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: RemoteTerminalView, context: Context) {}
}

extension String {
    var shellEscaped: String {
        "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
