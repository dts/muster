import Foundation

public struct Hello: Codable, Sendable {
    public let protocolVersion: UInt32
    public init(protocolVersion: UInt32 = BuildStamp.protocolVersion) {
        self.protocolVersion = protocolVersion
    }
}

public struct HelloAck: Codable, Sendable {
    public let protocolVersion: UInt32
    public let pid: Int32
    public let startedAt: Date

    public init(protocolVersion: UInt32, pid: Int32, startedAt: Date) {
        self.protocolVersion = protocolVersion
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

public struct Quit: Codable, Sendable {
    public init() {}
}

public struct ExitEvent: Codable, Sendable {
    public let sessionId: UUID
    public let code: Int32

    public init(sessionId: UUID, code: Int32) {
        self.sessionId = sessionId
        self.code = code
    }
}

public enum PromptMarkKind: String, Codable, Sendable {
    case promptStart    // OSC 133;A
    case promptEnd      // OSC 133;B
    case outputStart    // OSC 133;C
    case commandEnd     // OSC 133;D
}

public struct ErrorMessage: Codable, Sendable {
    public let sessionId: UUID?
    public let message: String

    public init(sessionId: UUID? = nil, message: String) {
        self.sessionId = sessionId
        self.message = message
    }
}
