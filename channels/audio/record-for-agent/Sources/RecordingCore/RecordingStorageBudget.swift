import Foundation

/// Recording and optional diagnostics use the same two-minute PCM reserve.
/// Diagnostics keep an additional conservative floor before the format is known.
public enum RecordingStorageBudget {
    private static let lock = NSLock()
    private static var activeReserve: Int64 = 8 * 1_024 * 1_024

    public static func minimumFreeBytes(sampleRate: Double, bytesPerFrame: UInt32, bufferCount: Int) -> Int64 {
        let bytes = sampleRate * 120 * Double(bytesPerFrame) * Double(bufferCount)
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return Int64.max }
        return max(8 * 1_024 * 1_024, Int64(bytes))
    }

    public static func registerRecordingReserve(_ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        activeReserve = max(8 * 1_024 * 1_024, bytes)
    }

    public static var observationReserveBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return max(64 * 1_024 * 1_024, activeReserve)
    }
}
