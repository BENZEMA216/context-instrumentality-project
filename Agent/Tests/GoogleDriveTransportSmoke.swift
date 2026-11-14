private final class MemoryCredentials: DriveCredentialStorage {
  var value: DriveCredentials? = DriveCredentials(clientID: "fake.apps.googleusercontent.com", clientSecret: "fake", refreshToken: "fake")
  func load() throws -> DriveCredentials? { value }
  func store(_ credentials: DriveCredentials) throws { value = credentials }
  func remove() throws { value = nil }
}

private final class FakeDriveProtocol: URLProtocol, @unchecked Sendable {
  struct Step: Sendable {
    let method: String
    let path: String
    let status: Int
    let body: String
    var headers: [String: String] = [:]
    var contentRange: String?
    var expectedUpload: Data?
  }
  private static let lock = NSLock()
  nonisolated(unsafe) private static var steps: [Step] = []
  static func stage(_ value: [Step]) {
    lock.withLock {
      precondition(steps.isEmpty, "unconsumed network requests")
      steps = value
    }
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let step = Self.lock.withLock {
      precondition(!Self.steps.isEmpty, "Unexpected request to \(request.url?.path ?? "<missing path>")")
      return Self.steps.removeFirst()
    }
    precondition(request.httpMethod == step.method && request.url?.path == step.path,
                 "Expected \(step.method) \(step.path), received \(request.httpMethod ?? "") \(request.url?.path ?? "")")
    precondition(request.url?.scheme == "https")
    if step.path == "/token" {
      precondition(request.url?.host == "oauth2.googleapis.com")
      precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
    } else {
      precondition(request.url?.host == "www.googleapis.com")
      precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-access")
    }
    if let range = step.contentRange {
      precondition(request.value(forHTTPHeaderField: "Content-Range") == range, "Incorrect byte range")
      precondition(request.value(forHTTPHeaderField: "Content-Length") == String(step.expectedUpload?.count ?? 0))
    }
    if let bytes = step.expectedUpload {
      let received = Self.uploadedBytes(in: request)
      precondition(received == bytes,
                   "Uploaded bytes differ from synthetic snapshot for \(step.method) \(step.path): \(received.count) of \(bytes.count) bytes")
    }
    if step.status == 0 {
      client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
      return
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: "HTTP/1.1", headerFields: step.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(step.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { }

  private static func uploadedBytes(in request: URLRequest) -> Data {
    if let bytes = request.httpBody { return bytes }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      precondition(count >= 0, "Could not read the synthetic upload body")
      if count == 0 { return bytes }
      bytes.append(buffer, count: count)
    }
  }
}

@main
struct GoogleDriveTransportSmoke {
  @MainActor
  static func main() async throws {
    let callback = DriveOAuthCallback(state: "expected") { url in
      precondition(url.host == "127.0.0.1" && url.port != nil)
      Task { @MainActor in
        let wrong = URL(string: "\(url.absoluteString)?state=wrong&code=bad")!
        let duplicate = URL(string: "\(url.absoluteString)?state=expected&state=expected&code=bad")!
        let right = URL(string: "\(url.absoluteString)?state=expected&code=valid%2Fcode")!
        do {
          for malformed in [wrong, duplicate] {
            let (_, response) = try await URLSession.shared.data(from: malformed)
            precondition((response as? HTTPURLResponse)?.statusCode == 400)
          }
          let (_, response) = try await URLSession.shared.data(from: right)
          precondition((response as? HTTPURLResponse)?.statusCode == 200)
        } catch {
          preconditionFailure("Local OAuth callback request failed: \(error)")
        }
      }
      return true
    }
    let authorization = try await callback.authorize { URL(string: $0)! }
    precondition(authorization.code == "valid/code")
    print("Loopback OAuth: rejects invalid and duplicate state, accepts encoded valid code")

    try await ClipboardGoogleDrive.verifyFakeTransport()
    try await ClipboardGoogleDrive.verifyResumableTransport()
    let session = URLSession(configuration: .ephemeral, delegate: DriveNoRedirect(), delegateQueue: nil)
    let location = URL(string: CommandLine.arguments[1])!
    let (_, response) = try await session.data(from: location)
    precondition((response as? HTTPURLResponse)?.statusCode == 307)
    precondition(response.url == location)
    print("HTTP redirect: stopped at the original 307 response")
  }
}

private extension ClipboardGoogleDrive {
  static func verifyFakeTransport() async throws {
    let memory = MemoryCredentials()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeDriveProtocol.self]
    let drive = ClipboardGoogleDrive(session: URLSession(configuration: config), keychain: memory)
    typealias Step = FakeDriveProtocol.Step
    let token = Step(method: "POST", path: "/token", status: 200, body: #"{"access_token":"fake-access"}"#)
    func metadata(_ snapshot: String, shared: Bool = false) -> String {
      let digest = Insecure.MD5.hash(data: Data(snapshot.utf8)).map { String(format: "%02x", $0) }.joined()
      return #"{"id":"test-file","appProperties":{"clipContextDeviceID":"device-one","clipContextSchema":"1"},"ownedByMe":true,"shared":\#(shared),"trashed":false,"size":"\#(snapshot.utf8.count)","md5Checksum":"\#(digest)"}"#
    }
    FakeDriveProtocol.stage([
      token,
      Step(method: "GET", path: "/drive/v3/files", status: 200, body: #"{"files":[]}"#),
      Step(method: "GET", path: "/drive/v3/files/generateIds", status: 200, body: #"{"ids":["test-file"]}"#),
      Step(method: "POST", path: "/upload/drive/v3/files", status: 0, body: "")
    ])
    do {
      try await drive.publish(snapshot: Data("one".utf8), deviceID: "device-one")
      preconditionFailure("lost response should be reported")
    } catch DriveError.network { }
    precondition(memory.value?.targets["device-one"] == "test-file")
    FakeDriveProtocol.stage([token, Step(method: "GET", path: "/drive/v3/files/test-file", status: 200, body: metadata("one"))])
    try await drive.publish(snapshot: Data("one".utf8), deviceID: "device-one")
    precondition(drive.latestFileID == "test-file")
    FakeDriveProtocol.stage([
      token,
      Step(method: "GET", path: "/drive/v3/files/test-file", status: 200, body: metadata("one")),
      Step(method: "PATCH", path: "/upload/drive/v3/files/test-file", status: 200, body: metadata("two"),
           expectedUpload: Data("two".utf8))
    ])
    try await drive.publish(snapshot: Data("two".utf8), deviceID: "device-one")

    FakeDriveProtocol.stage([
      token,
      Step(method: "GET", path: "/drive/v3/files/test-file", status: 200, body: metadata("two")),
      Step(method: "PATCH", path: "/upload/drive/v3/files/test-file", status: 200, body: metadata("bad"),
           expectedUpload: Data("new".utf8))
    ])
    do {
      try await drive.publish(snapshot: Data("new".utf8), deviceID: "device-one")
      preconditionFailure("Mismatched checksum was accepted")
    } catch DriveError.unverifiedUpload { }

    FakeDriveProtocol.stage([token, Step(method: "GET", path: "/drive/v3/files/test-file", status: 200, body: metadata("two", shared: true))])
    do {
      try await drive.publish(snapshot: Data("three".utf8), deviceID: "device-one")
      preconditionFailure("shared target should be rejected")
    } catch DriveError.invalidTarget { }
    FakeDriveProtocol.stage([Step(method: "POST", path: "/token", status: 400, body: #"{"error":"invalid_grant"}"#)])
    do {
      try await drive.publish(snapshot: Data("three".utf8), deviceID: "device-one")
      preconditionFailure("Expired credential was accepted")
    } catch DriveError.needsSignIn { }
    FakeDriveProtocol.stage([])
    try drive.disconnect()
    precondition(!drive.isConnected && drive.latestFileID == nil && memory.value == nil)
    print("Small Drive uploads: reserved ID, lost create response recovery, exact update bytes, checksum rejection, shared target rejection, expired authorization and disconnect")
  }
}

private extension ClipboardGoogleDrive {
  static func verifyResumableTransport() async throws {
    let memory = MemoryCredentials()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeDriveProtocol.self]
    let drive = ClipboardGoogleDrive(session: URLSession(configuration: config), keychain: memory)
    typealias Step = FakeDriveProtocol.Step
    let token = Step(method: "POST", path: "/token", status: 200, body: #"{"access_token":"fake-access"}"#)
    let uploadPath = "/upload/drive/v3/files"
    let readPath = "/drive/v3/files/test-file"
    let count = 5_000_017
    let chunk = 1_048_576
    func fixture(startingWith byte: UInt8) -> Data {
      var snapshot = Data()
      for offset in stride(from: 0, to: count, by: chunk) {
        snapshot.append(Data(repeating: byte + UInt8(offset / chunk), count: min(chunk, count - offset)))
      }
      return snapshot
    }
    let contents = fixture(startingWith: 23)
    let prior = fixture(startingWith: 42)
    func metadata(_ snapshot: Data) -> String {
      let digest = Insecure.MD5.hash(data: snapshot).map { String(format: "%02x", $0) }.joined()
      return #"{"id":"test-file","appProperties":{"clipContextDeviceID":"device-one","clipContextSchema":"1"},"ownedByMe":true,"shared":false,"trashed":false,"size":"\#(snapshot.count)","md5Checksum":"\#(digest)"}"#
    }
    func write(path: String, snapshot: Data = contents, start: Int, end: Int, status: Int, headers: [String: String] = [:]) -> Step {
      Step(method: "PUT", path: path, status: status, body: "", headers: headers,
           contentRange: "bytes \(start)-\(end - 1)/\(count)", expectedUpload: snapshot.subdata(in: start..<end))
    }
    let signedURL = "https://www.googleapis.com\(uploadPath)?uploadType=resumable&upload_id=synthetic"
    FakeDriveProtocol.stage([
      token,
      Step(method: "GET", path: "/drive/v3/files", status: 200, body: #"{"files":[]}"#),
      Step(method: "GET", path: "/drive/v3/files/generateIds", status: 200, body: #"{"ids":["test-file"]}"#),
      Step(method: "POST", path: uploadPath, status: 200, body: "", headers: ["Location": signedURL]),
      write(path: uploadPath, start: 0, end: chunk, status: 308, headers: ["Range": "bytes=0-\(chunk - 1)"]),
      write(path: uploadPath, start: chunk, end: chunk * 2, status: 503),
      Step(method: "PUT", path: uploadPath, status: 308, body: "", headers: ["Range": "bytes=0-\(chunk * 2 - 1)"],
           contentRange: "bytes */\(count)", expectedUpload: Data()),
      write(path: uploadPath, start: chunk * 2, end: chunk * 3, status: 308, headers: ["Range": "bytes=0-\(chunk * 3 - 1)"]),
      write(path: uploadPath, start: chunk * 3, end: chunk * 4, status: 308, headers: ["Range": "bytes=0-\(chunk * 4 - 1)"]),
      write(path: uploadPath, start: chunk * 4, end: count, status: 201),
      Step(method: "GET", path: readPath, status: 200, body: metadata(contents))
    ])
    try await drive.publish(snapshot: contents, deviceID: "device-one")
    precondition(drive.latestFileID == "test-file")

    let updatePath = uploadPath + "/test-file"
    let updateURL = "https://www.googleapis.com\(updatePath)?uploadType=resumable&upload_id=synthetic"
    FakeDriveProtocol.stage([
      token,
      Step(method: "GET", path: readPath, status: 200, body: metadata(contents)),
      Step(method: "PATCH", path: updatePath, status: 200, body: "", headers: ["Location": updateURL]),
      write(path: updatePath, snapshot: prior, start: 0, end: chunk, status: 308, headers: ["Range": "bytes=0-\(chunk - 1)"]),
      write(path: updatePath, snapshot: prior, start: chunk, end: chunk * 2, status: 308, headers: ["Range": "bytes=0-\(chunk * 2 - 1)"]),
      write(path: updatePath, snapshot: prior, start: chunk * 2, end: chunk * 3, status: 308, headers: ["Range": "bytes=0-\(chunk * 3 - 1)"]),
      write(path: updatePath, snapshot: prior, start: chunk * 3, end: chunk * 4, status: 308, headers: ["Range": "bytes=0-\(chunk * 4 - 1)"]),
      write(path: updatePath, snapshot: prior, start: chunk * 4, end: count, status: 0),
      Step(method: "PUT", path: updatePath, status: 200, body: "", contentRange: "bytes */\(count)", expectedUpload: Data()),
      Step(method: "GET", path: readPath, status: 200, body: metadata(prior))
    ])
    try await drive.publish(snapshot: prior, deviceID: "device-one")

    FakeDriveProtocol.stage([
      token,
      Step(method: "GET", path: readPath, status: 200, body: metadata(prior)),
      Step(method: "PATCH", path: updatePath, status: 200, body: "", headers: ["Location": "https://bad.invalid\(updatePath)?upload_id=synthetic"])
    ])
    do {
      try await drive.publish(snapshot: contents, deviceID: "device-one")
      preconditionFailure("unexpected destination was accepted")
    } catch DriveError.untrustedUploadURL { }

    FakeDriveProtocol.stage([
      token,
      Step(method: "GET", path: readPath, status: 200, body: metadata(prior)),
      Step(method: "PATCH", path: updatePath, status: 200, body: "", headers: ["Location": updateURL]),
      write(path: updatePath, start: 0, end: chunk, status: 308, headers: ["Range": "bytes=0-\(chunk)"])
    ])
    do {
      try await drive.publish(snapshot: contents, deviceID: "device-one")
      preconditionFailure("Server acknowledged more bytes than were uploaded")
    } catch DriveError.invalidUploadOffset { }

    FakeDriveProtocol.stage([])
    precondition(Self.resumableURL(signedURL + "&upload_id=second", id: "test-file") == nil)
    precondition(Self.resumableURL(updateURL, id: "wrong-id") == nil)
    precondition(Self.resumableURL(signedURL + "&access_token=synthetic", id: "test-file") == nil)
    print("Resumable Drive: exact large create and update chunks, midstream and final response recovery, unexpected location and invalid range rejection")
  }
}
