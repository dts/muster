import Foundation
import Darwin
import MusterShellProtocol

final class SessionManager {
    private let queue = DispatchQueue(label: "muster.shell.session-manager")
    private var sessions: [UUID: Session] = [:]

    /// Returns existing session or creates a new one with the given attach params.
    /// `created` callback fires only on creation.
    func attachOrCreate(
        _ req: Attach,
        defaultShell: String = "/bin/zsh",
        defaultArgs: [String] = ["-l"]
    ) -> Result<Session, Error> {
        return queue.sync {
            if let s = sessions[req.sessionId] {
                return .success(s)
            }
            do {
                let shell = req.shell ?? defaultShell
                let pty = try spawnShellInPTY(
                    executable: shell,
                    args: defaultArgs,
                    env: req.env,
                    cwd: req.cwd,
                    cols: req.cols,
                    rows: req.rows
                )
                let session = Session(sessionId: req.sessionId, pty: pty) { [weak self] s in
                    self?.queue.async {
                        self?.sessions.removeValue(forKey: s.sessionId)
                    }
                }
                sessions[req.sessionId] = session
                return .success(session)
            } catch {
                return .failure(error)
            }
        }
    }

    func get(_ id: UUID) -> Session? {
        queue.sync { sessions[id] }
    }

    func kill(_ id: UUID) {
        queue.sync {
            if let session = sessions[id] {
                session.queue.async {
                    session.kill()
                }
            }
        }
    }

    func list() -> [SessionInfo] {
        queue.sync {
            sessions.values.map { $0.info }
        }
    }
}
