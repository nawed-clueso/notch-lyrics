import Foundation

/// Tiny SPSC float ring buffer used to bridge AVAudioEngine's sink callback
/// (producer) and a manually-built HAL output AU's render callback (consumer).
/// Uses an unfair lock — not strictly realtime-safe, but glitches would only
/// appear under contention which is rare for this short critical section.
final class FloatRingBuffer {
    let capacity: Int            // capacity in interleaved samples (power of 2)
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIdx = 0
    private var readIdx = 0
    private let lock = NSLock()

    init(frames: Int, channels: Int) {
        let target = max(frames, 1) * max(channels, 1)
        var n = 1
        while n < target { n <<= 1 }
        capacity = n
        mask = n - 1
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: n)
        buffer.initialize(repeating: 0, count: n)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Produce. Drops samples if the buffer is full (overrun).
    func write(_ src: UnsafePointer<Float>, count: Int) {
        lock.lock()
        let free = capacity - (writeIdx - readIdx)
        let n = min(count, free)
        for i in 0..<n { buffer[(writeIdx &+ i) & mask] = src[i] }
        writeIdx &+= n
        lock.unlock()
    }

    /// Consume. Returns count actually read; caller zero-fills any remainder.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        lock.lock()
        let avail = writeIdx - readIdx
        let n = min(count, avail)
        for i in 0..<n { dst[i] = buffer[(readIdx &+ i) & mask] }
        readIdx &+= n
        lock.unlock()
        return n
    }

    func reset() {
        lock.lock()
        writeIdx = 0
        readIdx = 0
        lock.unlock()
    }
}
