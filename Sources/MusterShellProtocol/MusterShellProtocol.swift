import Foundation

public enum BuildStamp {
    public static let protocolVersion: UInt32 = 1
    public static let helperBuildId: String = "muster-shell-host-v0.1.0"
}

public enum MessageType: UInt8, Sendable {
    case hello          = 0x01
    case helloAck       = 0x02
    case attach         = 0x03
    case attachAck      = 0x04
    case resize         = 0x05
    case kill           = 0x06
    case detach         = 0x07
    case drain          = 0x08
    case quit           = 0x09
    case markRead       = 0x0A
    case setFocused     = 0x0B
    case list           = 0x0C
    case sessionsList   = 0x0D
    case exit           = 0x0E
    case bell           = 0x0F
    case notify         = 0x10
    case titleChanged   = 0x11
    case cwdChanged     = 0x12
    case promptMark     = 0x13
    case errorMessage   = 0x14

    case input          = 0x80
    case output         = 0x81
}
