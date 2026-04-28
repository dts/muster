import Foundation

/// Fixed-capacity byte ring buffer.
final class RingBuffer {
    let capacity: Int
    private var storage: [UInt8]
    private var head: Int = 0
    private(set) var count: Int = 0

    init(capacity: Int = 1 << 20) {
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    func append(_ data: Data) {
        let n = data.count
        if n == 0 { return }

        if n >= capacity {
            // overwrite entire buffer with the tail of `data`
            data.suffix(capacity).withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                storage.withUnsafeMutableBufferPointer { dst in
                    if let dstBase = dst.baseAddress, let srcBase = src.baseAddress {
                        memcpy(dstBase, srcBase, capacity)
                    }
                }
            }
            head = 0
            count = capacity
            return
        }

        let tail = (head + count) % capacity
        let firstChunk = min(n, capacity - tail)
        let secondChunk = n - firstChunk

        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            storage.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                memcpy(dstBase + tail, srcBase, firstChunk)
                if secondChunk > 0 {
                    memcpy(dstBase, srcBase + firstChunk, secondChunk)
                }
            }
        }

        if count + n <= capacity {
            count += n
        } else {
            let overflow = (count + n) - capacity
            head = (head + overflow) % capacity
            count = capacity
        }
    }

    /// Returns the buffered bytes in chronological (oldest-first) order.
    var snapshot: Data {
        if count == 0 { return Data() }
        var out = Data(capacity: count)
        let firstChunk = min(count, capacity - head)
        let secondChunk = count - firstChunk
        storage.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            out.append(base + head, count: firstChunk)
            if secondChunk > 0 {
                out.append(base, count: secondChunk)
            }
        }
        return out
    }
}
