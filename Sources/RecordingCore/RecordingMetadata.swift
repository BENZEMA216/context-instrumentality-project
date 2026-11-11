import Foundation

public enum RecordingMetadataError: Error {
    case invalidTimeZone, invalidLocation, invalidTimestamp
}

/// A location fix captured with this recording, never the device's location at export.
public struct SegmentLocation: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let capturedAt: Date

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, capturedAt: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.capturedAt = Date(timeIntervalSince1970: (capturedAt.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    public func validate() throws {
        guard latitude.isFinite, (-90...90).contains(latitude),
              longitude.isFinite, (-180...180).contains(longitude),
              horizontalAccuracy.isFinite, (0...100_000).contains(horizontalAccuracy) else {
            throw RecordingMetadataError.invalidLocation
        }
        try AgentRecordingMetadata.validateTimestamp(capturedAt)
    }
}

extension SegmentManifest {
    public func validateCaptureMetadata() throws {
        if let identifier = timeZoneIdentifier {
            guard identifier.utf8.count <= 128,
                  identifier.range(of: "^[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*$", options: .regularExpression) != nil,
                  identifier == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(identifier) || identifier.contains("/"),
                  TimeZone(identifier: identifier) != nil else { throw RecordingMetadataError.invalidTimeZone }
        }
        try location?.validate()
        if let recordingGroup {
            try AgentRecordingMetadata.validateTimestamp(startedAt)
            try recordingGroup.validate(segmentSequence: sequence)
        }
    }
}

/// Derived presentation fields travel outside the immutable source manifest.
/// Unix milliseconds remain authoritative, and an unknown original zone is explicit.
public struct AgentRecordingMetadata: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let startedAtISO8601: String
    public let endedAtISO8601: String
    public let timeZoneIdentifier: String
    public let timeZoneSource: String
    public let location: Location?

    public struct Location: Codable, Equatable, Sendable {
        public let latitude: Double
        public let longitude: Double
        public let horizontalAccuracy: Double
        public let capturedAt: Date
        public let capturedAtISO8601: String
    }

    public init(manifest: SegmentManifest) throws {
        try manifest.validateCaptureMetadata()
        startedAt = manifest.startedAt
        endedAt = manifest.endedAt
        guard endedAt >= startedAt else { throw RecordingMetadataError.invalidTimestamp }
        timeZoneIdentifier = manifest.timeZoneIdentifier ?? "UTC"
        timeZoneSource = manifest.timeZoneIdentifier == nil ? "utc_fallback" : "recorded"
        let zone = TimeZone(identifier: timeZoneIdentifier)!
        startedAtISO8601 = try Self.iso8601(startedAt, zone: zone)
        endedAtISO8601 = try Self.iso8601(endedAt, zone: zone)
        location = try manifest.location.map {
            Location(latitude: $0.latitude, longitude: $0.longitude, horizontalAccuracy: $0.horizontalAccuracy,
                     capturedAt: $0.capturedAt, capturedAtISO8601: try Self.iso8601($0.capturedAt, zone: zone))
        }
    }

    static func validateTimestamp(_ date: Date) throws {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= 253_402_300_799_999 else {
            throw RecordingMetadataError.invalidTimestamp
        }
    }

    private static func iso8601(_ date: Date, zone: TimeZone) throws -> String {
        try validateTimestamp(date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard (1...9999).contains(calendar.component(.year, from: date)) else {
            throw RecordingMetadataError.invalidTimestamp
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
