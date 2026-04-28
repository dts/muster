import Foundation

public struct Hello: Codable, Sendable {
    public let protocolVersion: UInt32
    public let buildId: String
    public init(protocolVersion: UInt32 = BuildStamp.protocolVersion, buildId: String = BuildStamp.helperBuildId) {
        self.protocolVersion = protocolVersion
        self.buildId = buildId
    }
}

public struct HelloAck: Codable, Sendable {
    public let protocolVersion: UInt32
    public let buildId: String
    public let pid: Int32
    public let startedAt: Date

    public init(protocolVersion: UInt32, buildId: String, pid: Int32, startedAt: Date) {
        self.protocolVersion = protocolVersion
        self.buildId = buildId
        self.pid = pid
        self.startedAt = startedAt
    }
}

public struct Attach: Codable, Sendable {
    public let sessionId: UUID
    public let cols: UInt16
    public let rows: UInt16
    public let cwd: String
    public let env: [String: String]
    public let shell: String?

    public init(sessionId: UUID, cols: UInt16, rows: UInt16, cwd: String, env: [String: String], shell: String? = nil) {
        self.sessionId = sessionId
        self.cols = cols
        self.rows = rows
        self.cwd = cwd
        self.env = env
        self.shell = shell
    }
}

public struct AttachAck: Codable, Sendable {
    public let sessionId: UUID
    public let resumed: Bool
    public let exitedCode: Int32?

    public init(sessionId: UUID, resumed: Bool, exitedCode: Int32? = nil) {
        self.sessionId = sessionId
        self.resumed = resumed
        self.exitedCode = exitedCode
    }
}

public struct Resize: Codable, Sendable {
    public let sessionId: UUID
    public let cols: UInt16
    public let rows: UInt16

    public init(sessionId: UUID, cols: UInt16, rows: UInt16) {
        self.sessionId = sessionId
        self.cols = cols
        self.rows = rows
    }
}

public struct Kill: Codable, Sendable {
    public let sessionId: UUID
    public init(sessionId: UUID) { self.sessionId = sessionId }
}

public struct Detach: Codable, Sendable {
    public let sessionId: UUID
    public init(sessionId: UUID) { self.sessionId = sessionId }
}

public struct Drain: Codable, Sendable {
    public init() {}
}

public struct Quit: Codable, Sendable {
    public init() {}
}

public struct MarkRead: Codable, Sendable {
    public let sessionId: UUID
    public init(sessionId: UUID) { self.sessionId = sessionId }
}

public struct SetFocused: Codable, Sendable {
    public let sessionId: UUID
    public let focused: Bool
    public init(sessionId: UUID, focused: Bool) {
        self.sessionId = sessionId
        self.focused = focused
    }
}

public struct ListRequest: Codable, Sendable {
    public init() {}
}

public struct SessionInfo: Codable, Sendable {
    public let sessionId: UUID
    public let pid: Int32
    public let exitedCode: Int32?

    public init(sessionId: UUID, pid: Int32, exitedCode: Int32? = nil) {
        self.sessionId = sessionId
        self.pid = pid
        self.exitedCode = exitedCode
    }
}

public struct SessionsList: Codable, Sendable {
    public let sessions: [SessionInfo]
    public init(sessions: [SessionInfo]) { self.sessions = sessions }
}

public struct ExitEvent: Codable, Sendable {
    public let sessionId: UUID
    public let code: Int32

    public init(sessionId: UUID, code: Int32) {
        self.sessionId = sessionId
        self.code = code
    }
}

public struct BellEvent: Codable, Sendable {
    public let sessionId: UUID
    public let timestamp: Date

    public init(sessionId: UUID, timestamp: Date = Date()) {
        self.sessionId = sessionId
        self.timestamp = timestamp
    }
}

public struct NotifyEvent: Codable, Sendable {
    public let sessionId: UUID
    public let title: String?
    public let body: String
    public let timestamp: Date

    public init(sessionId: UUID, title: String? = nil, body: String, timestamp: Date = Date()) {
        self.sessionId = sessionId
        self.title = title
        self.body = body
        self.timestamp = timestamp
    }
}

public struct TitleChangedEvent: Codable, Sendable {
    public let sessionId: UUID
    public let title: String

    public init(sessionId: UUID, title: String) {
        self.sessionId = sessionId
        self.title = title
    }
}

public struct CwdChangedEvent: Codable, Sendable {
    public let sessionId: UUID
    public let path: String

    public init(sessionId: UUID, path: String) {
        self.sessionId = sessionId
        self.path = path
    }
}

public enum PromptMarkKind: String, Codable, Sendable {
    case promptStart    // OSC 133;A
    case promptEnd      // OSC 133;B
    case outputStart    // OSC 133;C
    case commandEnd     // OSC 133;D
}

public struct PromptMarkEvent: Codable, Sendable {
    public let sessionId: UUID
    public let kind: PromptMarkKind
    public let exitCode: Int32?

    public init(sessionId: UUID, kind: PromptMarkKind, exitCode: Int32? = nil) {
        self.sessionId = sessionId
        self.kind = kind
        self.exitCode = exitCode
    }
}

public struct ErrorMessage: Codable, Sendable {
    public let sessionId: UUID?
    public let message: String

    public init(sessionId: UUID? = nil, message: String) {
        self.sessionId = sessionId
        self.message = message
    }
}
