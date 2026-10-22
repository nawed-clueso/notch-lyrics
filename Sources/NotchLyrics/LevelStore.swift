import Foundation

/// Circular buffer of recent peak-amplitude readings, written from the
/// audio I/O thread and read from the main thread by the waveform view.
/// Sendable via NSLock — not realtime-perfect but plenty for visualization.
final class LevelStore: @unchecked Sendable {
    static let capacity = 120        // ~4 s of history at one sample every ~33 ms
    private var buffer = [Float](repeating: 0, count: LevelStore.capacity)
    private var head = 0
    private let lock = NSLock()

    /// Called from the CoreAudio sink callback. `peak` is in 0...1 (clipped).
    ///
    /// Uses `try` rather than `lock()`: this runs on a realtime audio thread,
    /// and NSLock does no priority donation, so blocking here to wait on a
    /// reader risks missing an audio deadline. Several views now read the
    /// history at 30 Hz each, so contention is real. Dropping a sample costs a
    /// visualizer nothing.
    func push(_ peak: Float) {
        guard lock.try() else { return }
        buffer[head] = peak
        head = (head + 1) % buffer.count
        lock.unlock()
    }

    /// Returns the last `count` samples ordered oldest → newest.
    func snapshot() -> [Float] {
        lock.lock()
        let n = buffer.count
        let h = head
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = buffer[(h + i) % n] }
        lock.unlock()
        return out
    }

    func reset() {
        lock.lock()
        for i in 0..<buffer.count { buffer[i] = 0 }
        head = 0
        lock.unlock()
    }
}
