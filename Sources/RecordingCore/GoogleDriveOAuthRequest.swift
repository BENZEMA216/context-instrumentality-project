import Foundation

/// Configuration is supplied by the app owner's registered Google iOS OAuth
/// client. Shape checks cannot prove Cloud Console ownership or grant validity.
public struct GoogleDriveOAuthConfiguration: Equatable, Sendable {
    public static let scope = "https://www.googleapis.com/auth/drive.file"
    public let clientID: String
    public let reversedClientID: String
    public let redirectURI: String
    public init(clientID: String, reversedClientID: String, registeredBundleID: String,
                actualBundleID: String, registeredSchemes: [String]) throws {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix), !clientID.contains("REPLACE"), !clientID.contains("$("),
              clientID.utf8.count <= 256, !registeredBundleID.isEmpty, registeredBundleID == actualBundleID,
              !clientID.dropLast(suffix.count).isEmpty,
              clientID.dropLast(suffix.count).utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }),
              reversedClientID == "com.googleusercontent.apps." + clientID.dropLast(suffix.count),
              registeredSchemes.contains(reversedClientID) else { throw GoogleDriveLibraryError.notConfigured }
        self.clientID = clientID; self.reversedClientID = reversedClientID
        redirectURI = reversedClientID + ":/oauthredirect"
    }
    public func authorizationURL(state: String, challenge: String) throws -> URL {
        guard Self.validNonce(state), challenge.utf8.count == 43, Self.validNonce(challenge) else { throw GoogleDriveLibraryError.invalidState }
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = ["client_id": clientID, "redirect_uri": redirectURI, "response_type": "code",
            "scope": Self.scope, "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
            "access_type": "offline", "prompt": "consent select_account", "include_granted_scopes": "false"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    public func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard Self.validNonce(expectedState), let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == reversedClientID, parts.host == nil, parts.path == "/oauthredirect",
              parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil else { throw GoogleDriveLibraryError.invalidState }
        let values = parts.queryItems ?? []
        guard values.filter({ $0.name == "state" }).count == 1,
              values.first(where: { $0.name == "state" })?.value == expectedState,
              !values.contains(where: { $0.name == "error" }),
              values.filter({ $0.name == "code" }).count == 1,
              let code = values.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 4_096 else { throw GoogleDriveLibraryError.invalidState }
        return code
    }
    private static func validNonce(_ value: String) -> Bool {
        (43...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
