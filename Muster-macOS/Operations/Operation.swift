import Foundation
import Observation

@MainActor
@Observable
final class Operation: Identifiable, Hashable {
    nonisolated static func == (lhs: Operation, rhs: Operation) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    let id = UUID()
    var title: String
    var subtitle: String?
    var status: Status
    var statusMessage: String
    var lines: [String]
    var startedAt: Date
    var endedAt: Date?

    enum Status {
        case running
        case succeeded
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .running: false
            case .succeeded, .failed: true
            }
        }
    }

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.status = .running
        self.statusMessage = ""
        self.lines = []
        self.startedAt = Date()
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 2000 {
            lines.removeFirst(lines.count - 2000)
        }
    }

    func setStatus(_ message: String) {
        statusMessage = message
        append("[muster] \(message)")
    }

    func succeed() {
        status = .succeeded
        statusMessage = "Done"
        endedAt = Date()
    }

    func fail(_ message: String) {
        status = .failed(message)
        statusMessage = "Failed"
        endedAt = Date()
    }
}

@MainActor
@Observable
final class OperationStore {
    static let shared = OperationStore()
    private init() {}

    var operations: [Operation] = []

    var runningCount: Int {
        operations.filter {
            if case .running = $0.status { return true }
            return false
        }.count
    }

    func add(_ op: Operation) {
        operations.append(op)
    }

    func dismiss(_ op: Operation) {
        operations.removeAll { $0.id == op.id }
    }

    func dismissCompleted() {
        operations.removeAll { $0.status.isTerminal }
    }
}
