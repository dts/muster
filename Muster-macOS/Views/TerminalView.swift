import SwiftUI
import AppKit
import SwiftTerm
import MusterCore
import MusterShellProtocol

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

/// Scans byte stream for OSC 9/777/133 sequences not exposed by SwiftTerm delegates.
final class OSCScanner: @unchecked Sendable {
    enum Event: Sendable {
        case notify(title: String?, body: String)
        case promptMark(PromptMarkKind, exitCode: Int32?)
    }

    private enum State {
        case normal
        case escape
        case osc(buf: [UInt8])
        case oscEsc(buf: [UInt8])
    }

    private var state: State = .normal
    private var pending: [Event] = []

    func feed(_ data: Data) -> [Event] {
        for byte in data {
            switch state {
            case .normal:
                if byte == 0x1b { state = .escape }
            case .escape:
                if byte == 0x5d { state = .osc(buf: []) }
                else { state = .normal }
            case .osc(var buf):
                if byte == 0x07 {
                    dispatchOSC(buf)
                    state = .normal
                } else if byte == 0x1b {
                    state = .oscEsc(buf: buf)
                } else {
                    if buf.count < 4096 { buf.append(byte) }
                    state = .osc(buf: buf)
                }
            case .oscEsc(let buf):
                if byte == 0x5c { dispatchOSC(buf) }
                state = .normal
            }
        }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }

    private func dispatchOSC(_ buf: [UInt8]) {
        guard let str = String(bytes: buf, encoding: .utf8), !str.isEmpty else { return }

        let code: String
        let rest: String
        if let semi = str.firstIndex(of: ";") {
            code = String(str[..<semi])
            rest = String(str[str.index(after: semi)...])
        } else {
            code = str
            rest = ""
        }

        switch code {
        case "9":
            // OSC 9 variants:
            // OSC 9;message - simple notification
            // OSC 9;N;message - subtype notification (0=notify, 3=urgent notify, 4=title)
            let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count >= 2, let subtype = Int(parts[0]) {
                let message = String(parts[1])
                switch subtype {
                case 0, 3: // notification (3 = urgent)
                    pending.append(.notify(title: nil, body: message))
                case 4: // window title - SwiftTerm handles this via delegate
                    break
                default:
                    pending.append(.notify(title: nil, body: message))
                }
            } else {
                // Simple OSC 9;message format
                pending.append(.notify(title: nil, body: rest))
            }
        case "99":
            // OSC 99 notification (foot terminal, others)
            // Format: OSC 99;d=0:p=body:i=id ST or simply OSC 99;body ST
            if rest.contains(":p=") {
                if let range = rest.range(of: ":p=") {
                    var body = String(rest[range.upperBound...])
                    if let endRange = body.range(of: ":") {
                        body = String(body[..<endRange.lowerBound])
                    }
                    pending.append(.notify(title: nil, body: body))
                }
            } else {
                pending.append(.notify(title: nil, body: rest))
            }
        case "777":
            let parts = rest.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3 && parts[0] == "notify" {
                pending.append(.notify(title: String(parts[1]), body: String(parts[2])))
            }
        case "133":
            let parts = rest.split(separator: ";", omittingEmptySubsequences: false)
            guard let kindToken = parts.first.map(String.init) else { return }
            switch kindToken {
            case "A": pending.append(.promptMark(.promptStart, exitCode: nil))
            case "B": pending.append(.promptMark(.promptEnd, exitCode: nil))
            case "C": pending.append(.promptMark(.outputStart, exitCode: nil))
            case "D":
                let exit = parts.count > 1 ? Int32(String(parts[1])) : nil
                pending.append(.promptMark(.commandEnd, exitCode: exit))
            default: break
            }
        default: break
        }
    }
}

@MainActor
final class RemoteTerminalView: SwiftTerm.TerminalView, TerminalViewDelegate {
    let checkoutId: UUID
    private let cwd: String
    private var session: ShellSession?
    private var pumpTask: Task<Void, Never>?
    private let oscScanner = OSCScanner()

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
            self.pumpTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await data in s.output {
                    for ev in self.oscScanner.feed(data) {
                        switch ev {
                        case .notify(let title, let body):
                            AttentionStore.shared.handleNotify(checkoutId: self.checkoutId, title: title, body: body)
                        case .promptMark(let kind, let exitCode):
                            AttentionStore.shared.handlePromptMark(checkoutId: self.checkoutId, kind: kind, exitCode: exitCode)
                        }
                    }
                    self.feed(byteArray: [UInt8](data)[...])
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
        guard newCols > 0, newRows > 0, newCols <= Int(UInt16.max), newRows <= Int(UInt16.max) else { return }
        let cols = UInt16(newCols)
        let rows = UInt16(newRows)
        Task { @MainActor [weak self] in
            self?.session?.resize(cols: cols, rows: rows)
        }
    }

    nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            AttentionStore.shared.handleTitle(checkoutId: self.checkoutId, title: title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            guard let self, let dir = directory else { return }
            AttentionStore.shared.handleCwd(checkoutId: self.checkoutId, path: dir)
        }
    }

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

    nonisolated func bell(source: SwiftTerm.TerminalView) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            AttentionStore.shared.handleBell(checkoutId: self.checkoutId)
        }
    }

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
