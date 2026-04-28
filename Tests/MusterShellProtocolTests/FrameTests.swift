import XCTest
@testable import MusterShellProtocol

final class FrameTests: XCTestCase {
    func testRoundTripControlMessage() throws {
        let hello = Hello(protocolVersion: 1, buildId: "test-1.0")
        let payload = try WireCodec.encode(hello)
        let frame = Frame(type: .hello, payload: payload)
        let bytes = frame.encode()

        let reader = FrameReader()
        reader.append(bytes)
        let decoded = reader.nextFrame()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .hello)
        let parsed = try WireCodec.decode(Hello.self, from: decoded!.payload)
        XCTAssertEqual(parsed.protocolVersion, 1)
        XCTAssertEqual(parsed.buildId, "test-1.0")
    }

    func testBulkOutputFrame() throws {
        let id = UUID()
        let bulk = BulkPayload(sessionId: id, bytes: Data("hello\n".utf8))
        let frame = Frame(type: .output, payload: bulk.encode())
        let bytes = frame.encode()

        let reader = FrameReader()
        reader.append(bytes)
        let f = reader.nextFrame()!
        XCTAssertEqual(f.type, .output)
        let decoded = BulkPayload.decode(f.payload)!
        XCTAssertEqual(decoded.sessionId, id)
        XCTAssertEqual(decoded.bytes, Data("hello\n".utf8))
    }

    func testPartialFrameThenComplete() {
        let id = UUID()
        let bulk = BulkPayload(sessionId: id, bytes: Data(repeating: 0xAB, count: 100))
        let frame = Frame(type: .output, payload: bulk.encode())
        let bytes = frame.encode()

        let reader = FrameReader()
        reader.append(bytes.prefix(10))
        XCTAssertNil(reader.nextFrame())
        reader.append(bytes.suffix(from: 10))
        let f = reader.nextFrame()!
        XCTAssertEqual(f.type, .output)
        XCTAssertEqual(BulkPayload.decode(f.payload)?.bytes.count, 100)
    }

    func testTwoFramesBackToBack() throws {
        let f1 = Frame(type: .hello, payload: try WireCodec.encode(Hello(protocolVersion: 1, buildId: "a")))
        let f2 = Frame(type: .quit, payload: try WireCodec.encode(Quit()))
        var stream = Data()
        stream.append(f1.encode())
        stream.append(f2.encode())

        let reader = FrameReader()
        reader.append(stream)
        XCTAssertEqual(reader.nextFrame()?.type, .hello)
        XCTAssertEqual(reader.nextFrame()?.type, .quit)
        XCTAssertNil(reader.nextFrame())
    }
}
