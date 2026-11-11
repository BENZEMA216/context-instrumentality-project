import Foundation

/// Accepts only the HTTPS request URL, allowing the case normalization performed
/// by URLSession for the scheme and host. All other serialized URL bytes stay
/// significant, including explicit ports and percent-encoded path spelling.
public enum AutomaticReceiverResponseURLPolicy {
    public static func matches(expected: URL, response: URL?) -> Bool {
        guard let response,
              let expectedValue = normalized(expected),
              let responseValue = normalized(response) else { return false }
        return expectedValue == responseValue
    }

    private static func normalized(_ url: URL) -> String? {
        let value = url.absoluteString
        guard let components = URLComponents(string: value),
              let serialized = components.string, serialized == value,
              let scheme = components.scheme, asciiLowercase(scheme) == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.percentEncodedQuery == nil, components.percentEncodedFragment == nil,
              let schemeRange = components.rangeOfScheme,
              let hostRange = components.rangeOfHost else { return nil }

        // Rewriting parsed components would also normalize other URL spelling
        // (for example a port with leading zeroes). Replace only these two ranges.
        let rawHost = String(serialized[hostRange])
        let normalizedHost: String
        if rawHost.hasPrefix("["), let zone = rawHost.firstIndex(of: "%") {
            // An IPv6 zone is an interface identifier, not a case-insensitive host.
            normalizedHost = asciiLowercase(String(rawHost[..<zone])) + rawHost[zone...]
        } else {
            normalizedHost = asciiLowercase(rawHost)
        }
        var normalized = serialized
        normalized.replaceSubrange(hostRange, with: normalizedHost)
        normalized.replaceSubrange(schemeRange, with: asciiLowercase(scheme))
        return normalized
    }

    private static func asciiLowercase(_ value: String) -> String {
        String(decoding: value.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
}
