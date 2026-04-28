import Foundation

public struct Frame: Sendable {
    public let type: MessageType
    public let payload: Data

    public init(type: MessageType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: 5 + payload.count)
        let length = UInt32(1 + payload.count)
        var be = length.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(payload)
        return out
    }
}

public final class FrameReader {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) {
        buffer.append(data)
    }

    public func nextFrame() -> Frame? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> UInt32 in
            (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
        }
        guard length >= 1 else {
            buffer.removeFirst(4)
            return nil
        }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let typeByte = buffer[buffer.startIndex + 4]
        let payloadRange = (buffer.startIndex + 5)..<(buffer.startIndex + 4 + Int(length))
        let payload = buffer.subdata(in: payloadRange)
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + Int(length)))

        guard let type = MessageType(rawValue: typeByte) else {
            return nil
        }
        return Frame(type: type, payload: payload)
    }
}

public struct BulkPayload: Sendable {
    public let sessionId: UUID
    public let bytes: Data

    public init(sessionId: UUID, bytes: Data) {
        self.sessionId = sessionId
        self.bytes = bytes
    }

    public func encode() -> Data {
        var out = Data(capacity: 16 + bytes.count)
        var u = sessionId.uuid
        withUnsafeBytes(of: &u) { out.append(contentsOf: $0) }
        out.append(bytes)
        return out
    }

    public static func decode(_ data: Data) -> BulkPayload? {
        guard data.count >= 16 else { return nil }
        let head = data.prefix(16)
        var bytes16 = [UInt8](repeating: 0, count: 16)
        head.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for i in 0..<16 { bytes16[i] = src[i] }
        }
        let uuid = UUID(uuid: (
            bytes16[0], bytes16[1], bytes16[2], bytes16[3],
            bytes16[4], bytes16[5], bytes16[6], bytes16[7],
            bytes16[8], bytes16[9], bytes16[10], bytes16[11],
            bytes16[12], bytes16[13], bytes16[14], bytes16[15]
        ))
        let body = data.subdata(in: (data.startIndex + 16)..<data.endIndex)
        return BulkPayload(sessionId: uuid, bytes: body)
    }
}

public enum WireCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
