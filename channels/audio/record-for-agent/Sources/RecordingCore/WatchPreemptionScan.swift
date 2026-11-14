import Foundation

/// Yield decisions look at every outstanding transfer. A fixed prefix must not
/// leave a later task blocking admission only because of its queue position.
/// Diagnostic samples may still be shorter; this scan is the control path.
public enum WatchPreemptionScan {
    public static func candidates<T>(_ outstanding: [T]) -> [T] { outstanding }
}
