import Foundation
import MusterShellProtocol

/// Observational parser that scans a byte stream for attention escape codes.
/// Bytes are NOT modified — this only reports what it sees.
final class AttentionParser {
    enum Event {
        case bell
        case title(String)
        case cwd(String)
        case notify(title: String?, body: String)
        case promptMark(PromptMarkKind, exitCode: Int32?)
    }

    private enum State {
        case normal
        case escape
        case osc(buf: [UInt8])
        case oscEsc(buf: [UInt8])  // saw ESC inside OSC, awaiting `\` for ST
    }

    private var state: State = .normal
    private var pendingEvents: [Event] = []

    func feed(_ data: Data) {
        for byte in data {
            switch state {
            case .normal:
                if byte == 0x07 {
                    pendingEvents.append(.bell)
                } else if byte == 0x1b {
                    state = .escape
                }
            case .escape:
                if byte == 0x5d {  // ']'
                    state = .osc(buf: [])
                } else {
                    state = .normal
                }
            case .osc(var buf):
                if byte == 0x07 {
                    dispatchOSC(buf)
                    state = .normal
                } else if byte == 0x1b {
                    state = .oscEsc(buf: buf)
                } else {
                    if buf.count < 4096 {
                        buf.append(byte)
                    }
                    state = .osc(buf: buf)
                }
            case .oscEsc(let buf):
                if byte == 0x5c {  // '\' — completes ST
                    dispatchOSC(buf)
                    state = .normal
                } else {
                    // Spurious ESC; drop OSC and re-enter escape
                    state = .normal
                }
            }
        }
    }

    func drainEvents() -> [Event] {
        let out = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return out
    }

    private func dispatchOSC(_ buf: [UInt8]) {
        guard let str = String(bytes: buf, encoding: .utf8), !str.isEmpty else { return }
        guard let semi = str.firstIndex(of: ";") else {
            // Some OSCs are just a code with no args — e.g. "133;A" only has args
            return
        }
        let code = String(str[..<semi])
        let rest = String(str[str.index(after: semi)...])

        switch code {
        case "0", "1", "2":
            pendingEvents.append(.title(rest))
        case "7":
            if let url = URL(string: rest), url.scheme == "file" {
                pendingEvents.append(.cwd(url.path))
            }
        case "9":
            pendingEvents.append(.notify(title: nil, body: rest))
        case "777":
            let parts = rest.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3 && parts[0] == "notify" {
                pendingEvents.append(.notify(title: String(parts[1]), body: String(parts[2])))
            }
        case "133":
            let parts = rest.split(separator: ";", omittingEmptySubsequences: false)
            guard let kindToken = parts.first.map(String.init) else { return }
            switch kindToken {
            case "A": pendingEvents.append(.promptMark(.promptStart, exitCode: nil))
            case "B": pendingEvents.append(.promptMark(.promptEnd, exitCode: nil))
            case "C": pendingEvents.append(.promptMark(.outputStart, exitCode: nil))
            case "D":
                let exit = parts.count > 1 ? Int32(String(parts[1])) : nil
                pendingEvents.append(.promptMark(.commandEnd, exitCode: exit))
            default:
                break
            }
        default:
            break
        }
    }
}
