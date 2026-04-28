import Foundation

public enum BuildStamp {
    public static let protocolVersion: UInt32 = 2
}

public enum MessageType: UInt8, Sendable {
    case hello          = 0x01
    case helloAck       = 0x02
    case attach         = 0x03
    case attachAck      = 0x04
    case resize         = 0x05
    case kill           = 0x06
    case detach         = 0x07
    case quit           = 0x09
    case exit           = 0x0E
    case errorMessage   = 0x14

    case input          = 0x80
    case output         = 0x81
}
