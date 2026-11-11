import Foundation

private func canonicalDate(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
}

public enum CaptureState: String, Codable, Sendable {
    case idle, starting, recording, paused, interrupted, ended, failed
}

public struct RecordingSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var state: CaptureState
    public var lastAudioAt: Date?
    public var lastSealedAt: Date?
    public var currentSegmentStartedAt: Date?
    public var recordingGroup: RecordingGroup?
    public var recordingGroupClosed: Bool?
    public var updatedAt: Date

    public init(id: UUID = UUID(), startedAt: Date = Date(), state: CaptureState = .starting) {
        self.id = id
        self.startedAt = canonicalDate(startedAt)
        self.state = state
        self.updatedAt = canonicalDate(startedAt)
    }
}

public struct SegmentManifest: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let sessionID: UUID
    public let sequence: Int
    public let startedAt: Date
    public let endedAt: Date
    public let sampleRate: Double
    public let frameCount: Int64
    public let fileName: String
    public let byteCount: Int64
    public let sha256: String
    /// Capture context is absent on historical recordings; never infer it at export time.
    public let timeZoneIdentifier: String?
    public let location: SegmentLocation?
    public let recordingGroup: RecordingGroup?

    public var duration: TimeInterval { Double(frameCount) / sampleRate }

    public init(id: UUID, sessionID: UUID, sequence: Int, startedAt: Date, endedAt: Date,
                sampleRate: Double, frameCount: Int64, fileName: String, byteCount: Int64,
                sha256: String, schemaVersion: Int = 1,
                timeZoneIdentifier: String? = nil, location: SegmentLocation? = nil,
                recordingGroup: RecordingGroup? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.startedAt = canonicalDate(startedAt)
        self.endedAt = canonicalDate(endedAt)
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.recordingGroup = recordingGroup
    }
}

/// Stable identity and capture clock shared by every segment between start and pause.
public struct RecordingGroup: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let utcOffsetMinutes: Int
    public let firstSequence: Int

    public init(id: UUID = UUID(), startedAt: Date, timeZone: TimeZone, firstSequence: Int) {
        self.id = id
        self.startedAt = canonicalDate(startedAt)
        self.utcOffsetMinutes = timeZone.secondsFromGMT(for: self.startedAt) / 60
        self.firstSequence = firstSequence
    }

    public var timeZone: TimeZone {
        guard (-1_080...1_080).contains(utcOffsetMinutes) else { return .gmt }
        return TimeZone(secondsFromGMT: utcOffsetMinutes * 60) ?? .gmt
    }

    public var cloudName: String { "\(timestamp(for: startedAt))_\(id.uuidString.lowercased())" }

    func timestamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = abs(utcOffsetMinutes)
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d%@%02d%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
                      utcOffsetMinutes < 0 ? "-" : "+", offset / 60, offset % 60)
    }

    func validate(segmentSequence: Int) throws {
        try AgentRecordingMetadata.validateTimestamp(startedAt)
        guard firstSequence >= 0, firstSequence <= segmentSequence, segmentSequence <= Int32.max,
              (-1_080...1_080).contains(utcOffsetMinutes) else {
            throw RecordingMetadataError.invalidTimestamp
        }
    }
}

extension SegmentManifest {
    public var recordingGroupID: UUID { recordingGroup?.id ?? sessionID }
    public var recordingPartIndex: Int { sequence - (recordingGroup?.firstSequence ?? 0) }
    public var groupedAudioFileName: String? {
        guard let group = recordingGroup else { return nil }
        let part = String(format: "%03lld", Int64(recordingPartIndex) + 1)
        return "\(group.timestamp(for: startedAt))_part\(part)_\(id.uuidString.lowercased()).caf"
    }
}

public struct SegmentReceipt: Codable, Equatable, Sendable {
    public let segmentID: UUID
    public let sha256: String
    public let byteCount: Int64
    public let receivedAt: Date

    public init(segmentID: UUID, sha256: String, byteCount: Int64, receivedAt: Date = Date()) {
        self.segmentID = segmentID
        self.sha256 = sha256
        self.byteCount = byteCount
        self.receivedAt = canonicalDate(receivedAt)
    }
}

public struct RecordingEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let sessionID: UUID?
    public let kind: String
    public let detail: String
    public let intervalStart: Date?
    public let intervalEnd: Date?

    public init(kind: String, detail: String, sessionID: UUID? = nil,
                timestamp: Date = Date(), intervalStart: Date? = nil, intervalEnd: Date? = nil) {
        self.id = UUID()
        self.timestamp = canonicalDate(timestamp)
        self.sessionID = sessionID
        self.kind = kind
        self.detail = detail
        self.intervalStart = intervalStart.map(canonicalDate)
        self.intervalEnd = intervalEnd.map(canonicalDate)
    }
}

public struct RecorderSnapshot: Codable, Equatable, Sendable {
    public var state: CaptureState
    public var sessionID: UUID?
    public var recordingGroupID: UUID?
    public var observedAt: Date
    public var lastAudioAt: Date?
    public var lastSealedAt: Date?
    public var pendingCount: Int
    /// False means pendingCount is only a cached value, never proof of an empty queue.
    public var pendingCountIsKnown: Bool
    public var detail: String?

    public init(state: CaptureState, sessionID: UUID? = nil, observedAt: Date = Date(),
                lastAudioAt: Date? = nil, lastSealedAt: Date? = nil,
                pendingCount: Int = 0, pendingCountIsKnown: Bool = false, detail: String? = nil,
                recordingGroupID: UUID? = nil) {
        self.state = state
        self.sessionID = sessionID
        self.recordingGroupID = recordingGroupID
        self.observedAt = canonicalDate(observedAt)
        self.lastAudioAt = lastAudioAt.map(canonicalDate)
        self.lastSealedAt = lastSealedAt.map(canonicalDate)
        self.pendingCount = pendingCount
        self.pendingCountIsKnown = pendingCountIsKnown
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case state, sessionID, observedAt, lastAudioAt, lastSealedAt
        case pendingCount, pendingCountIsKnown, detail
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(CaptureState.self, forKey: .state)
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID)
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        lastAudioAt = try values.decodeIfPresent(Date.self, forKey: .lastAudioAt)
        lastSealedAt = try values.decodeIfPresent(Date.self, forKey: .lastSealedAt)
        pendingCount = try values.decode(Int.self, forKey: .pendingCount)
        // Legacy wire data did not preserve the writer's count verification state.
        pendingCountIsKnown = try values.decodeIfPresent(Bool.self, forKey: .pendingCountIsKnown) ?? false
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
    }

    public func isStale(at now: Date = Date(), after: TimeInterval = 60) -> Bool {
        now.timeIntervalSince(observedAt) > after || now.timeIntervalSince(observedAt) < -5
    }
}

public enum TransportCodec {
    public static let watchRuntimeKey = "watchRuntimeObservation"
    public static let manifestKey = "segmentManifest"
    public static let receiptKey = "segmentReceipt"
    public static let snapshotKey = "recorderSnapshot"
    public static let eventsKey = "recordingEvents"
    public static let requestSyncKey = "requestSync"
    public static let targetedReceiptRequestKey = "targetedReceiptRequest"
    public static let statusRequestKey = "recorderStatusRequest"
    public static let statusResponseKey = "recorderStatusResponse"

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// A request-bound, presentation-only channel. Never an audio/receipt command.
public struct RecorderStatusRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public init(requestID: UUID) { schemaVersion = 1; self.requestID = requestID }
}

public struct RecorderStatusResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    /// The writer's observation is returned unchanged, including its timestamp.
    /// Nil means this process has not observed the writer; it is not idle proof.
    public let snapshot: RecorderSnapshot?
    public init(requestID: UUID, snapshot: RecorderSnapshot?) {
        schemaVersion = 1; self.requestID = requestID; self.snapshot = snapshot
    }
}
