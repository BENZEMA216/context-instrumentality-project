import Foundation

/// Events and phone receipt requests share one small userInfo queue.
/// Neither kind may take every slot, so the other kind can still be sent.
public enum WatchUserInfoScheduling {
    public static let sharedCapacity = 3
    public static let maximumPerKind = 2

    public static func admitsEvent(events: Int, receiptRequests: Int, others: Int) -> Bool {
        admits(kindCount: events, events: events, receiptRequests: receiptRequests, others: others)
    }

    public static func admitsReceiptRequest(events: Int, receiptRequests: Int, others: Int) -> Bool {
        admits(kindCount: receiptRequests, events: events, receiptRequests: receiptRequests, others: others)
    }

    private static func admits(kindCount: Int, events: Int, receiptRequests: Int, others: Int) -> Bool {
        kindCount >= 0 && receiptRequests >= 0 && events >= 0 && others >= 0
            && kindCount < maximumPerKind
            && events + receiptRequests + others < sharedCapacity
    }
}
