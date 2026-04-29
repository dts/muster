import SwiftUI
import Combine

public enum TerminalState: Equatable {
    case idle
    case busy(message: String?)
    case unknown
}

public struct TerminalInfo: Equatable {
    public var state: TerminalState = .unknown
    public var title: String?
}

@MainActor
@Observable
public final class TerminalStatusStore {
    static let shared = TerminalStatusStore()

    private(set) var info: [String: TerminalInfo] = [:]

    private init() {}

    func state(for workingDirectory: String) -> TerminalState {
        info[workingDirectory]?.state ?? .unknown
    }

    func title(for workingDirectory: String) -> String? {
        info[workingDirectory]?.title
    }

    func setState(_ state: TerminalState, for workingDirectory: String) {
        if info[workingDirectory] == nil {
            info[workingDirectory] = TerminalInfo()
        }
        info[workingDirectory]?.state = state
    }

    func setTitle(_ title: String?, for workingDirectory: String) {
        if info[workingDirectory] == nil {
            info[workingDirectory] = TerminalInfo()
        }
        info[workingDirectory]?.title = title
    }

    func parseOSC99(_ data: ArraySlice<UInt8>, for workingDirectory: String) {
        guard let str = String(bytes: data, encoding: .utf8) else {
            NSLog("[muster] OSC 99 parse failed: not valid UTF-8")
            return
        }

        // Format: muster;state=idle|busy[;msg=...]
        let parts = str.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.first == "muster" else {
            NSLog("[muster] OSC 99 ignored: not muster prefix, got '\(parts.first ?? "")'")
            return
        }

        var state: TerminalState = .unknown
        var message: String?

        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1])

            switch key {
            case "state":
                switch value {
                case "idle":
                    state = .idle
                case "busy":
                    state = .busy(message: nil)
                default:
                    NSLog("[muster] OSC 99 unknown state: \(value)")
                }
            case "msg":
                message = value
            default:
                break
            }
        }

        if case .busy = state, let msg = message {
            state = .busy(message: msg)
        }

        NSLog("[muster] Setting state to \(state) for \(workingDirectory)")
        setState(state, for: workingDirectory)
    }
}

struct TerminalStateIndicator: View {
    let state: TerminalState

    var body: some View {
        switch state {
        case .idle:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        case .busy(let message):
            Circle()
                .fill(.orange)
                .frame(width: 8, height: 8)
                .help(message ?? "Working")
        case .unknown:
            EmptyView()
        }
    }
}
