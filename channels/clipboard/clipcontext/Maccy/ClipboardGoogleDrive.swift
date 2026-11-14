import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

@MainActor
final class ClipboardGoogleDrive: ObservableObject {
  @Published private(set) var isConnected: Bool
  @Published private(set) var isBusy = false
  @Published private(set) var latestFileID: String?

  private static let driveScope = "https://www.googleapis.com/auth/drive.file"
  private static let deviceProperty = "clipContextDeviceID"
  private static let schemaProperty = "clipContextSchema"
  private static let fileFields = "id,appProperties,ownedByMe,shared,trashed,size,md5Checksum"
  private static let smallUploadLimit = 5_000_000
  private static let uploadChunkSize = 1_048_576
  private let session: URLSession
  private let keychain: any DriveCredentialStorage
  private var credentials: DriveCredentials?

  convenience init(session: URLSession? = nil) {
    self.init(session: session, keychain: DriveKeychain())
  }

  private init(session: URLSession?, keychain: any DriveCredentialStorage) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 90
    self.session = session ?? URLSession(configuration: configuration, delegate: DriveNoRedirect(), delegateQueue: nil)
    self.keychain = keychain
    let savedCredentials = try? keychain.load()
    credentials = savedCredentials
    isConnected = savedCredentials != nil
  }

  func authorize(clientID: String, clientSecret: String) async throws {
    guard !isBusy else { throw DriveError.busy }
    let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    let clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clientID.hasSuffix(".apps.googleusercontent.com"),
          clientID.count <= 256,
          !clientSecret.isEmpty, clientSecret.count <= 512 else {
      throw DriveError.configuration
    }

    isBusy = true
    defer { isBusy = false }
    let verifier = try Self.randomNonce()
    let state = try Self.randomNonce()
    let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    let callback = try await DriveOAuthCallback(state: state).authorize { redirect in
      Self.makeURL(host: "accounts.google.com", path: "/o/oauth2/v2/auth", fields: [
        "client_id": clientID,
        "redirect_uri": redirect,
        "response_type": "code",
        "scope": Self.driveScope,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "access_type": "offline",
        "prompt": "consent select_account"
      ])
    }
    let token = try await exchange([
      "client_id": clientID, "client_secret": clientSecret, "code": callback.code,
      "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": callback.redirect
    ])
    guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
      throw DriveError.noRefreshToken
    }
    let replacement = DriveCredentials(clientID: clientID, clientSecret: clientSecret, refreshToken: refreshToken)
    try keychain.store(replacement)
    credentials = replacement
    isConnected = true
    latestFileID = nil
  }

  func disconnect() throws {
    guard !isBusy else { throw DriveError.busy }
    try keychain.remove()
    credentials = nil
    isConnected = false
    latestFileID = nil
  }

  func publish(snapshot: Data, deviceID: String) async throws {
    guard !isBusy else { throw DriveError.busy }
    guard var credentials else { throw DriveError.disconnected }
    guard !deviceID.isEmpty, deviceID.utf8.count <= 64,
          deviceID.utf8.allSatisfy(Self.isIdentifierByte) else {
      throw DriveError.invalidDevice
    }

    isBusy = true
    defer { isBusy = false }
    let token = try await exchange([
      "client_id": credentials.clientID,
      "client_secret": credentials.clientSecret,
      "refresh_token": credentials.refreshToken,
      "grant_type": "refresh_token"
    ])
    if let refreshToken = token.refreshToken, !refreshToken.isEmpty, refreshToken != credentials.refreshToken {
      credentials.refreshToken = refreshToken
      try keychain.store(credentials)
      self.credentials = credentials
    }

    let accessToken = token.accessToken
    if let id = credentials.targets[deviceID], let existing = try await readFile(id: id, token: accessToken) {
      try validate(existing, deviceID: deviceID, expectedID: id)
      try await update(snapshot, existing: existing, deviceID: deviceID, token: accessToken)
      latestFileID = id
      return
    }
    if let existing = try await findSnapshot(deviceID: deviceID, token: accessToken) {
      try validate(existing, deviceID: deviceID)
      try await update(snapshot, existing: existing, deviceID: deviceID, token: accessToken)
      if existing.id != credentials.targets[deviceID] {
        credentials.targets[deviceID] = existing.id
        try keychain.store(credentials)
        self.credentials = credentials
      }
      latestFileID = existing.id
      return
    }

    let id: String
    if let pendingID = credentials.targets[deviceID] {
      id = pendingID
    } else {
      id = try await reserveFileID(token: accessToken)
      credentials.targets[deviceID] = id
      try keychain.store(credentials)
      self.credentials = credentials
    }
    if let uploaded = try await create(snapshot, id: id, deviceID: deviceID, token: accessToken) {
      try validate(uploaded, deviceID: deviceID, expectedID: id, snapshot: snapshot)
      latestFileID = id
      return
    }

    // Drive returns 409 when an earlier create with the reserved ID succeeded.
    // Read that exact ID before deciding whether this upload needs an update.
    if let existing = try await readFile(id: id, token: accessToken) {
      try validate(existing, deviceID: deviceID, expectedID: id)
      try await update(snapshot, existing: existing, deviceID: deviceID, token: accessToken)
      latestFileID = id
      return
    }

    // The reserved ID can be permanently unavailable after deletion in Drive.
    // Reserve and save a fresh one before a subsequent upload attempt.
    credentials.targets.removeValue(forKey: deviceID)
    try keychain.store(credentials)
    self.credentials = credentials
    latestFileID = nil
    throw DriveError.targetUnavailable
  }

  private func findSnapshot(deviceID: String, token: String) async throws -> DriveFile? {
    let query = "trashed = false and 'me' in owners and "
      + "appProperties has { key='\(Self.deviceProperty)' and value='\(deviceID)' } and "
      + "appProperties has { key='\(Self.schemaProperty)' and value='1' }"
    let (data, _) = try await drive("/drive/v3/files", fields: [
      "q": query, "spaces": "drive", "pageSize": "2", "fields": "nextPageToken,files(\(Self.fileFields))"
    ], token: token)
    let matches = try decode(DriveFileList.self, from: data)
    guard matches.files.count <= 1, matches.nextPageToken == nil else { throw DriveError.duplicateTarget }
    return matches.files.first
  }

  private func reserveFileID(token: String) async throws -> String {
    let (data, _) = try await drive("/drive/v3/files/generateIds", fields: ["count": "1", "space": "drive"], token: token)
    let result = try decode(DriveIDs.self, from: data)
    guard result.ids.count == 1, let id = result.ids.first, Self.isFileID(id) else {
      throw DriveError.invalidResponse
    }
    return id
  }

  private func readFile(id: String, token: String) async throws -> DriveFile? {
    guard Self.isFileID(id) else { throw DriveError.invalidResponse }
    let (data, response) = try await drive("/drive/v3/files/\(id)", fields: ["fields": Self.fileFields], token: token,
                                       accepted: [200, 404])
    return response.statusCode == 404 ? nil : try decode(DriveFile.self, from: data)
  }

  private func create(_ snapshot: Data, id: String, deviceID: String, token: String) async throws -> DriveFile? {
    let metadata = try JSONSerialization.data(withJSONObject: [
      "id": id,
      "name": "ClipContext-\(deviceID).json",
      "mimeType": "application/json",
      "appProperties": [Self.deviceProperty: deviceID, Self.schemaProperty: "1"]
    ])
    if snapshot.count > Self.smallUploadLimit {
      return try await uploadResumable(snapshot, id: id, creationMetadata: metadata, token: token)
    }
    let boundary = "clipcontext-\(UUID().uuidString)"
    var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
    body.append(metadata)
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8))
    body.append(snapshot)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    let (data, response) = try await drive("/upload/drive/v3/files", method: "POST", fields: [
      "uploadType": "multipart", "fields": Self.fileFields
    ], token: token, body: body, contentType: "multipart/related; boundary=\(boundary)", accepted: [200, 201, 409])
    return response.statusCode == 409 ? nil : try decode(DriveFile.self, from: data)
  }

  private func update(_ snapshot: Data, existing: DriveFile, deviceID: String, token: String) async throws {
    guard !matches(snapshot, existing) else { return }
    let uploaded: DriveFile
    if snapshot.count > Self.smallUploadLimit {
      guard let completed = try await uploadResumable(snapshot, id: existing.id, creationMetadata: nil, token: token) else {
        throw DriveError.http(409)
      }
      uploaded = completed
    } else {
      let (data, _) = try await drive("/upload/drive/v3/files/\(existing.id)", method: "PATCH", fields: [
        "uploadType": "media", "fields": Self.fileFields
      ], token: token, body: snapshot, contentType: "application/json")
      uploaded = try decode(DriveFile.self, from: data)
    }
    try validate(uploaded, deviceID: deviceID, expectedID: existing.id, snapshot: snapshot)
  }

  private func uploadResumable(_ snapshot: Data, id: String, creationMetadata: Data?, token: String) async throws -> DriveFile? {
    let root = "/upload/drive/v3/files"
    let path = creationMetadata == nil ? "\(root)/\(id)" : root
    let (_, response) = try await drive(path, method: creationMetadata == nil ? "PATCH" : "POST", fields: [
      "uploadType": "resumable", "fields": Self.fileFields
    ], token: token, body: creationMetadata, contentType: creationMetadata == nil ? nil : "application/json; charset=UTF-8",
       headers: ["X-Upload-Content-Type": "application/json", "X-Upload-Content-Length": String(snapshot.count)],
       accepted: [200, 201, 409])
    if response.statusCode == 409 { return nil }
    guard let location = response.value(forHTTPHeaderField: "Location"),
          let uploadURL = Self.resumableURL(location, id: id) else { throw DriveError.untrustedUploadURL }

    var offset = 0
    var recoveryAttempts = 0
    while offset < snapshot.count {
      try Task.checkCancellation()
      let end = min(offset + Self.uploadChunkSize, snapshot.count)
      let range = (snapshot.startIndex + offset)..<(snapshot.startIndex + end)
      let progress: DriveUploadProgress
      var recovered = false
      do {
        progress = try await putChunk(snapshot.subdata(in: range), to: uploadURL, token: token,
                                      range: "bytes \(offset)-\(end - 1)/\(snapshot.count)", total: snapshot.count)
      } catch let error as DriveError {
        guard error.isTransientUploadError, recoveryAttempts < 3 else { throw error }
        recoveryAttempts += 1
        recovered = true
        // Query the exact session before retrying: Drive may have committed the
        // last chunk even when this client never received the response.
        progress = try await putChunk(Data(), to: uploadURL, token: token,
                                      range: "bytes */\(snapshot.count)", total: snapshot.count)
      }
      switch progress {
      case .completed:
        guard let uploaded = try await readFile(id: id, token: token) else { throw DriveError.invalidResponse }
        return uploaded
      case .conflict: return nil
      case .partial(let next):
        guard (next > offset || (recovered && next == offset)), next <= end, next < snapshot.count else {
          throw DriveError.invalidUploadOffset
        }
        offset = next
      }
    }
    throw DriveError.invalidUploadOffset
  }

  private func putChunk(_ bytes: Data, to uploadURL: URL, token: String, range: String, total: Int) async throws -> DriveUploadProgress {
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "PUT"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
    request.setValue(range, forHTTPHeaderField: "Content-Range")
    request.httpBody = bytes
    let (_, response) = try await send(request)
    switch response.statusCode {
    case 200, 201: return .completed
    case 308:
      guard let received = response.value(forHTTPHeaderField: "Range") else { return .partial(0) }
      guard received.hasPrefix("bytes=0-"), let last = Int(received.dropFirst(8)), (0..<total).contains(last) else {
        throw DriveError.invalidUploadOffset
      }
      return .partial(last + 1)
    case 401: throw DriveError.needsSignIn
    case 404, 410: throw DriveError.expiredUpload
    case 409: return .conflict
    default: throw DriveError.http(response.statusCode)
    }
  }

  private static func resumableURL(_ location: String, id: String) -> URL? {
    let root = "/upload/drive/v3/files"
    guard location.utf8.count <= 8192, let parts = URLComponents(string: location),
          parts.scheme == "https", parts.host == "www.googleapis.com", parts.port == nil,
          parts.user == nil, parts.password == nil, parts.fragment == nil,
          [root, "\(root)/\(id)"].contains(parts.percentEncodedPath), let fields = parts.queryItems,
          !fields.contains(where: { ["access_token", "oauth_token", "token", "key"].contains($0.name.lowercased()) }) else {
      return nil
    }
    let uploadIDs = fields.filter { $0.name == "upload_id" }
    guard uploadIDs.count == 1, let uploadID = uploadIDs.first?.value, !uploadID.isEmpty else { return nil }
    return parts.url
  }

  private func validate(_ file: DriveFile, deviceID: String, expectedID: String? = nil, snapshot: Data? = nil) throws {
    guard Self.isFileID(file.id), expectedID == nil || file.id == expectedID,
          file.ownedByMe == true, file.shared == false, file.trashed == false,
          file.appProperties?[Self.deviceProperty] == deviceID,
          file.appProperties?[Self.schemaProperty] == "1" else { throw DriveError.invalidTarget }
    if let snapshot, !matches(snapshot, file) { throw DriveError.unverifiedUpload }
  }

  private func matches(_ snapshot: Data, _ file: DriveFile) -> Bool {
    guard file.size == String(snapshot.count) else { return false }
    let checksum = Insecure.MD5.hash(data: snapshot).map { String(format: "%02x", $0) }.joined()
    return file.md5Checksum == checksum
  }

  private func exchange(_ fields: [String: String]) async throws -> DriveToken {
    var request = URLRequest(url: Self.makeURL(host: "oauth2.googleapis.com", path: "/token"))
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
      "\(Self.formEncode(key))=\(Self.formEncode(value))"
    }.joined(separator: "&").utf8)
    let (data, response) = try await send(request)
    let status = response.statusCode
    if (status == 400 || status == 401),
       let error = try? JSONDecoder().decode(DriveOAuthFailure.self, from: data),
       ["invalid_grant", "invalid_client", "unauthorized_client"].contains(error.error) {
      throw DriveError.needsSignIn
    }
    guard status == 200 else { throw DriveError.http(status) }
    let token = try decode(DriveToken.self, from: data)
    guard !token.accessToken.isEmpty else { throw DriveError.invalidResponse }
    return token
  }

  private func drive(_ path: String, method: String = "GET", fields: [String: String] = [:], token: String,
                     body: Data? = nil, contentType: String? = nil, headers: [String: String] = [:],
                     accepted: Set<Int> = [200]) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: Self.makeURL(host: "www.googleapis.com", path: path, fields: fields))
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    for (header, value) in headers { request.setValue(value, forHTTPHeaderField: header) }
    request.httpBody = body
    let result = try await send(request)
    let status = result.1.statusCode
    if status == 401 { throw DriveError.needsSignIn }
    guard accepted.contains(status) else { throw DriveError.http(status) }
    return result
  }

  private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw DriveError.network((error as? URLError)?.errorCode)
    }
    guard let response = response as? HTTPURLResponse, response.url == request.url else {
      throw DriveError.invalidResponse
    }
    return (data, response)
  }

  private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw DriveError.invalidResponse
    }
  }

  private static func makeURL(host: String, path: String, fields: [String: String] = [:]) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = path
    if !fields.isEmpty {
      components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    return components.url!
  }

  private static func formEncode(_ value: String) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved)!
  }

  private static func randomNonce() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { throw DriveError.randomness }
    return base64URL(Data(bytes))
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  private static func isIdentifierByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
  }

  private static func isFileID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy(Self.isIdentifierByte)
  }
}

private struct DriveCredentials: Codable {
  let clientID: String
  let clientSecret: String
  var refreshToken: String
  var targets: [String: String] = [:]
}

private struct DriveToken: Decodable {
  let accessToken: String
  let refreshToken: String?

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
  }
}

private struct DriveOAuthFailure: Decodable {
  let error: String
}

private struct DriveFile: Decodable {
  let id: String
  let appProperties: [String: String]?
  let ownedByMe: Bool?
  let shared: Bool?
  let trashed: Bool?
  let size: String?
  let md5Checksum: String?
}

private struct DriveFileList: Decodable {
  let nextPageToken: String?
  let files: [DriveFile]
}

private struct DriveIDs: Decodable {
  let ids: [String]
}

private enum DriveUploadProgress {
  case completed
  case partial(Int)
  case conflict
}

private protocol DriveCredentialStorage {
  func load() throws -> DriveCredentials?
  func store(_ credentials: DriveCredentials) throws
  func remove() throws
}

private struct DriveKeychain: DriveCredentialStorage {
  private var identity: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "app.clipcontext.mac") + ".google-drive",
     kSecAttrAccount as String: "oauth-desktop"]
  }

  func load() throws -> DriveCredentials? {
    var query = identity
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw DriveError.keychain(status) }
    return try JSONDecoder().decode(DriveCredentials.self, from: data)
  }

  func store(_ credentials: DriveCredentials) throws {
    let data = try JSONEncoder().encode(credentials)
    let values = [kSecValueData as String: data]
    var status = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(identity.merging(values) { _, latest in latest } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw DriveError.keychain(status) }
  }

  func remove() throws {
    let status = SecItemDelete(identity as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw DriveError.keychain(status) }
  }
}

private final class DriveNoRedirect: NSObject, URLSessionTaskDelegate {
  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                              willPerformHTTPRedirection response: HTTPURLResponse,
                              newRequest request: URLRequest,
                              completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

@MainActor
private final class DriveOAuthCallback {
  struct Authorization {
    let code: String
    let redirect: String
  }

  private let state: String
  private let openBrowser: (URL) -> Bool
  private var listener: NWListener?
  private var timeout: Task<Void, Never>?
  private var continuation: CheckedContinuation<Authorization, Error>?
  private var redirect: String?
  private var connections: [ObjectIdentifier: NWConnection] = [:]

  init(state: String, openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
    self.state = state
    self.openBrowser = openBrowser
  }

  func authorize(url: @escaping @MainActor @Sendable (String) -> URL) async throws -> Authorization {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        do {
          let parameters = NWParameters.tcp
          parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
          let listener = try NWListener(using: parameters)
          self.listener = listener
          listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listenerChanged(state, url: url) }
          }
          listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
          }
          listener.start(queue: .main)
          timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(DriveError.authorizationTimedOut))
          }
        } catch {
          finish(.failure(DriveError.loopback))
        }
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }

  private func listenerChanged(_ state: NWListener.State, url: (String) -> URL) {
    switch state {
    case .ready:
      guard let port = listener?.port?.rawValue, redirect == nil else { return }
      let redirect = "http://127.0.0.1:\(port)/oauth/callback"
      self.redirect = redirect
      guard openBrowser(url(redirect)) else {
        finish(.failure(DriveError.browser))
        return
      }
    case .failed:
      finish(.failure(DriveError.loopback))
    default:
      break
    }
  }

  private func accept(_ connection: NWConnection) {
    guard continuation != nil, connections.count < 8 else {
      connection.cancel()
      return
    }
    connections[ObjectIdentifier(connection)] = connection
    connection.start(queue: .main)
    read(connection, prefix: Data())
  }

  private func read(_ connection: NWConnection, prefix: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - prefix.count) { [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
        let request = prefix + (data ?? Data())
        if request.range(of: Data("\r\n\r\n".utf8)) != nil {
          self.handle(request, on: connection)
        } else if request.count < 8192, !complete, error == nil {
          self.read(connection, prefix: request)
        } else {
          self.close(connection)
        }
      }
    }
  }

  private func handle(_ data: Data, on connection: NWConnection) {
    let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
    let fields = line.split(separator: " ")
    guard fields.count == 3, fields[0] == "GET", let redirect,
          let parts = URLComponents(string: String(fields[1])), parts.scheme == nil, parts.host == nil,
          parts.path == "/oauth/callback", parts.fragment == nil,
          let query = parts.queryItems,
          query.filter({ $0.name == "state" }).map(\.value) == [state] else {
      respond(to: connection, status: "400 Bad Request", message: "Invalid authorization response.")
      return
    }
    let codes = query.filter { $0.name == "code" }
    guard !query.contains(where: { $0.name == "error" }), codes.count == 1,
          let code = codes[0].value, !code.isEmpty, code.utf8.count <= 4096 else {
      respond(to: connection, status: "400 Bad Request", message: "Authorization did not complete. Return to ClipContext.",
              result: .failure(DriveError.authorizationDenied))
      return
    }
    respond(to: connection, status: "200 OK", message: "Authorization received. You can close this tab and return to ClipContext.",
            result: .success(Authorization(code: code, redirect: redirect)))
  }

  private func respond(to connection: NWConnection, status: String, message: String,
                       result: Result<Authorization, Error>? = nil) {
    let body = Data(message.utf8)
    let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)"
      + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
      Task { @MainActor in
        self?.close(connection)
        if let result { self?.finish(result) }
      }
    })
  }

  private func close(_ connection: NWConnection) {
    connections.removeValue(forKey: ObjectIdentifier(connection))
    connection.cancel()
  }

  private func finish(_ result: Result<Authorization, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timeout?.cancel()
    timeout = nil
    listener?.cancel()
    listener = nil
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
    continuation.resume(with: result)
  }
}

private enum DriveError: LocalizedError {
  case busy, configuration, disconnected, invalidDevice, needsSignIn, noRefreshToken
  case invalidResponse, targetUnavailable, duplicateTarget, invalidTarget, unverifiedUpload
  case untrustedUploadURL, invalidUploadOffset, expiredUpload
  case randomness, loopback, browser, authorizationTimedOut, authorizationDenied
  case keychain(OSStatus), http(Int), network(Int?)

  var isTransientUploadError: Bool {
    switch self {
    case .network: true
    case .http(let status): (500...599).contains(status)
    default: false
    }
  }

  var errorDescription: String? {
    switch self {
    case .busy: "Another Google Drive operation is in progress."
    case .configuration: "Enter the client ID and secret from a Google OAuth Desktop app configuration."
    case .disconnected: "Connect Google Drive before publishing."
    case .invalidDevice: "The clipboard archive has an invalid device identifier."
    case .needsSignIn: "Google rejected the authorization. Reconnect Google Drive."
    case .noRefreshToken: "Google did not return an offline credential. Reconnect and allow access."
    case .invalidResponse: "Google Drive returned an unexpected response."
    case .targetUnavailable: "The Drive snapshot is no longer available. Try syncing again to create a new one."
    case .duplicateTarget: "Drive contains multiple snapshots for this device. Keep one snapshot before syncing again."
    case .invalidTarget: "The Google Drive snapshot is shared or could not be verified as a private ClipContext file."
    case .unverifiedUpload: "Google Drive returned a checksum that did not match the clipboard snapshot."
    case .untrustedUploadURL: "Google Drive returned an unrecognized upload location."
    case .invalidUploadOffset: "Google Drive reported an invalid upload position."
    case .expiredUpload: "The Google Drive upload session expired. Sync again to restart it."
    case .randomness: "Could not prepare a secure Google sign-in request."
    case .loopback: "Could not open the local Google sign-in callback."
    case .browser: "Could not open the browser for Google sign-in."
    case .authorizationTimedOut: "Google sign-in timed out. Try connecting again."
    case .authorizationDenied: "Google sign-in was cancelled or declined."
    case let .keychain(status): "Could not access the ClipContext credential in Keychain (\(status))."
    case let .http(status): "Google Drive request failed (HTTP \(status))."
    case let .network(code): "Could not reach Google Drive (network error \(code.map(String.init) ?? "unknown"))."
    }
  }
}
