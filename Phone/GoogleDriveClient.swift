import Foundation
import RecordingCore

struct GoogleDriveAccount: Sendable {
    let id: String
    let label: String
}

/// Only creates private files in this installation's fixed library folder.
/// No permissions.create, vendor endpoint, sharing link or service account.
@MainActor
final class GoogleDriveClient {
    private let http: GoogleDriveHTTP
    private let oauth: any GoogleDriveTokenProvider
    private let accountID: String
    private let check: () throws -> Void
    private let requestTimeout: (() throws -> TimeInterval)?
    private var validatedToken: String?
    private let phaseHandler: (GoogleDrivePreflightPhase) -> Void
    private var currentPhase = GoogleDrivePreflightPhase.idle
    private func phase(_ value: GoogleDrivePreflightPhase) { currentPhase = value; phaseHandler(value) }
    private static let fields = "id,name,mimeType,size,sha256Checksum,parents,ownedByMe,shared,trashed,appProperties,permissions(id,type,role,deleted)"
    init(http: GoogleDriveHTTP, oauth: any GoogleDriveTokenProvider, accountID: String, check: @escaping () throws -> Void,
         requestTimeout: (() throws -> TimeInterval)? = nil,
         phase: @escaping (GoogleDrivePreflightPhase) -> Void = { _ in }) {
        self.http = http; self.oauth = oauth; self.accountID = accountID; self.check = check; self.requestTimeout = requestTimeout; phaseHandler = phase
    }
    static func account(http: GoogleDriveHTTP, token: String, timeout: TimeInterval? = nil,
                        recoveryBudget: GoogleDriveHTTP.RecoveryBudget? = nil) async throws -> GoogleDriveAccount {
        struct About: Decodable { struct User: Decodable { let permissionId: String; let emailAddress: String?; let displayName: String? }; let user: User }
        var parts = URLComponents(string: "https://www.googleapis.com/drive/v3/about")!
        parts.queryItems = [.init(name: "fields", value: "user(permissionId,emailAddress,displayName)")]
        var request = URLRequest(url: parts.url!); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.send(request, timeout: timeout, recoveryBudget: recoveryBudget)
        if response.statusCode == 401 { throw GoogleDriveError.needsSignIn }
        guard response.statusCode == 200 else { throw GoogleDriveError.response(status: response.statusCode, data: data) }
        let value = try JSONDecoder().decode(About.self, from: data).user
        guard !value.permissionId.isEmpty, value.permissionId.utf8.count <= 256 else { throw GoogleDriveError.invalidResponse }
        let label = value.emailAddress ?? value.displayName ?? "已连接的 Google 账户"
        guard label.utf8.count <= 512 else { throw GoogleDriveError.invalidResponse }
        return .init(id: value.permissionId, label: label)
    }
    func validateAccount() async throws {
        phase(.tokenAccess)
        do {
            try check()
            let token = try await oauth.accessToken(for: accountID, timeout: requestTimeout?())
            try check()
            phase(.accountGet)
            let account = try await Self.account(http: http, token: token, timeout: requestTimeout?(), recoveryBudget: currentRecoveryBudget)
            try check()
            guard account.id == accountID else { throw GoogleDriveLibraryError.changedAccount }
            validatedToken = token
        } catch {
            // A failed await must still honor a parent/deadline cancellation.
            try check()
            throw error
        }
    }
    func generateID() async throws -> String {
        phase(.allocate)
        struct IDs: Decodable { let ids: [String] }
        let (data, _) = try await request(path: "/drive/v3/files/generateIds", query: ["count": "1", "space": "drive", "type": "files"])
        let values = try JSONDecoder().decode(IDs.self, from: data).ids
        guard values.count == 1, GoogleDriveLibraryLedger.validFileID(values[0]) else { throw GoogleDriveError.invalidResponse }
        return values[0]
    }
    func metadata(_ id: String, purpose: GoogleDrivePreflightPhase = .fileLookup) async throws -> GoogleDriveRemoteFile? {
        phase(purpose)
        guard GoogleDriveLibraryLedger.validFileID(id) else { throw GoogleDriveError.invalidResponse }
        let (data, response) = try await request(path: "/drive/v3/files/" + id, query: ["fields": Self.fields], accepted: [200, 404])
        if response.statusCode == 404 { return nil }
        return try JSONDecoder().decode(GoogleDriveRemoteFile.self, from: data)
    }
    func ensureFolder(id: String, libraryID: UUID) async throws {
        let properties = ["rfaLibraryID": libraryID.uuidString.lowercased(), "rfaSchema": "1"]
        if let existing = try await metadata(id, purpose: .folder) {
            try validateFolder(existing, id: id, libraryID: libraryID)
            return
        } else {
            let body = try JSONSerialization.data(withJSONObject: ["id": id, "name": "Record for Agent — " + libraryID.uuidString.lowercased().prefix(8),
                "mimeType": "application/vnd.google-apps.folder", "appProperties": properties] as [String: Any])
            // A lost successful response may return 409 next time. Only a
            // deterministic readback of the original ID can make it success.
            _ = try await request(path: "/drive/v3/files", query: ["fields": Self.fields], method: "POST", body: body, accepted: [200, 201, 409])
        }
        try await verifyFolder(id: id, libraryID: libraryID)
    }
    func verifyFolder(id: String, libraryID: UUID) async throws {
        guard let folder = try await metadata(id, purpose: .folder) else { throw GoogleDriveLibraryError.invalidRemoteFolder }
        try validateFolder(folder, id: id, libraryID: libraryID)
    }
    private func validateFolder(_ folder: GoogleDriveRemoteFile, id: String, libraryID: UUID) throws {
        guard folder.id == id, folder.mimeType == "application/vnd.google-apps.folder",
              GoogleDriveLibraryLedger.isOwnerOnly(folder, accountID: accountID),
              folder.appProperties?["rfaLibraryID"] == libraryID.uuidString.lowercased(),
              folder.appProperties?["rfaSchema"] == "1" else { throw GoogleDriveLibraryError.invalidRemoteFolder }
    }

    /// Resolve an uncertain native completion without opening local content or
    /// creating a new upload session. The caller still commits only the normal
    /// strict ledger verification, after checking its current source/grant.
    /// A 404 or 410 drops the dead session URL; it is not a remote receipt.
    func readBackCompletedUpload(artifact: GoogleDriveArtifact, manifest: SegmentManifest) async throws -> GoogleDriveCompletedReadBack {
        let correlation = GoogleDriveUploadCorrelation(segmentID: manifest.id, kind: artifact.kind, manifestSHA256: manifest.sha256)
        return try await GoogleDriveUploadTrace.$current.withValue(correlation) {
            try await readBackCompletedUploadBody(artifact: artifact)
        }
    }

    private func readBackCompletedUploadBody(artifact: GoogleDriveArtifact) async throws -> GoogleDriveCompletedReadBack {
        try check()
        guard let fileID = artifact.fileID else { throw GoogleDriveError.invalidResponse }
        if let remote = try await metadata(fileID) { return .remote(remote) }
        guard let stored = artifact.uploadURL else { return .pending }
        phase(.sessionQuery)
        let (_, response) = try await request(uploadURL: stored, method: "PUT",
            headers: ["Content-Range": "bytes */\(artifact.byteCount)"], accepted: [200, 201, 308, 404, 410])
        switch GoogleDriveResumableReadBack.classify(status: response.statusCode) {
        case .needsMetadata:
            guard let remote = try await metadata(fileID) else { throw GoogleDriveError.invalidResponse }
            return .remote(remote)
        case .pending:
            if response.statusCode == 308 { _ = try Self.nextOffset(response, total: artifact.byteCount) }
            return .pending
        case .sessionExpired:
            return .sessionExpired
        }
    }

    /// The caller has fingerprinted immutable local bytes and durably assigned
    /// fileID. Every upload session URL is persisted BEFORE its first byte PUT.
    func upload(file: URL, artifact: GoogleDriveArtifact, manifest: SegmentManifest, folderID: String,
                libraryID: UUID, backgroundHandoff: ((URLRequest, URL, Int64) async throws -> Void)? = nil,
                saveSession: (String?) throws -> Void) async throws -> GoogleDriveRemoteFile {
        let correlation = GoogleDriveUploadCorrelation(segmentID: manifest.id, kind: artifact.kind, manifestSHA256: manifest.sha256)
        return try await GoogleDriveUploadTrace.$current.withValue(correlation) {
            try await uploadBody(file: file, artifact: artifact, manifest: manifest, folderID: folderID,
                libraryID: libraryID, backgroundHandoff: backgroundHandoff, saveSession: saveSession)
        }
    }

    private func uploadBody(file: URL, artifact: GoogleDriveArtifact, manifest: SegmentManifest, folderID: String,
                            libraryID: UUID, backgroundHandoff: ((URLRequest, URL, Int64) async throws -> Void)?,
                            saveSession: (String?) throws -> Void) async throws -> GoogleDriveRemoteFile {
        try check()
        guard let fileID = artifact.fileID else { throw GoogleDriveError.invalidResponse }
        if let existing = try await metadata(fileID) { return existing }
        var sessionURL = artifact.uploadURL
        var offset: Int64 = 0
        if let stored = sessionURL {
            phase(.sessionQuery)
            let (_, response) = try await request(uploadURL: stored, method: "PUT", headers: ["Content-Range": "bytes */\(artifact.byteCount)"], accepted: [200, 201, 308, 404, 410])
            if response.statusCode == 200 || response.statusCode == 201 {
                guard let remote = try await metadata(fileID) else { throw GoogleDriveError.invalidResponse }
                return remote
            }
            if response.statusCode == 404 || response.statusCode == 410 {
                try check(); try saveSession(nil); sessionURL = nil
            } else { offset = try Self.nextOffset(response, total: artifact.byteCount) }
        }
        if sessionURL == nil {
            let properties = ["rfaSchema": "1", "rfaLibraryID": libraryID.uuidString.lowercased(),
                "rfaSegmentID": manifest.id.uuidString.lowercased(), "rfaKind": artifact.kind.rawValue,
                "rfaAudioSHA256": manifest.sha256, "rfaContentSHA256": artifact.sha256]
            let mime = Self.mimeType(artifact.kind)
            let body = try JSONSerialization.data(withJSONObject: ["id": fileID, "name": Self.fileName(artifact, manifest: manifest),
                "parents": [folderID], "mimeType": mime, "appProperties": properties] as [String: Any])
            phase(.sessionCreate)
            let (_, response) = try await request(path: "/upload/drive/v3/files", query: ["uploadType": "resumable", "fields": "id"],
                method: "POST", body: body, headers: ["X-Upload-Content-Type": mime, "X-Upload-Content-Length": String(artifact.byteCount)], accepted: [200, 201, 409])
            if response.statusCode == 409 {
                guard let remote = try await metadata(fileID) else { throw GoogleDriveError.http(409) }
                return remote
            }
            guard let location = response.value(forHTTPHeaderField: "Location"), GoogleDriveLibraryLedger.validUploadURL(location) else { throw GoogleDriveError.invalidResponse }
            try check(); try saveSession(location); sessionURL = location
        }
        guard let sessionURL else { throw GoogleDriveError.invalidResponse }
        if let backgroundHandoff, offset < artifact.byteCount {
            try check()
            let previousPhase = currentPhase
            let token: String
            do {
                phase(.tokenAccess)
                token = try await oauth.accessToken(for: accountID, timeout: requestTimeout?())
                try check()
                if token != validatedToken {
                    phase(.accountGet)
                    let account = try await Self.account(http: http, token: token, timeout: requestTimeout?(), recoveryBudget: currentRecoveryBudget)
                    try check()
                    guard account.id == accountID else { throw GoogleDriveLibraryError.changedAccount }
                    validatedToken = token
                }
                phase(previousPhase)
            } catch {
                // Match ordinary requests: an awaited failure must not escape
                // its cancelled parent or spent lease as a fresh network error.
                try check()
                throw error
            }
            guard GoogleDriveLibraryLedger.validUploadURL(sessionURL), let url = URL(string: sessionURL) else {
                throw GoogleDriveError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(Self.mimeType(artifact.kind), forHTTPHeaderField: "Content-Type")
            request.setValue(String(artifact.byteCount - offset), forHTTPHeaderField: "Content-Length")
            request.setValue("bytes \(offset)-\(artifact.byteCount - 1)/\(artifact.byteCount)", forHTTPHeaderField: "Content-Range")
            try check()
            phase(.nativeStage)
            try await backgroundHandoff(request, file, offset)
            throw GoogleDriveUploadHandoff()
        }
        while offset < artifact.byteCount {
            try check()
            let position = offset, count = Int(min(1_048_576, artifact.byteCount - offset))
            let read = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(position))
                guard let bytes = try handle.read(upToCount: count), bytes.count == count else { throw GoogleDriveError.invalidResponse }
                return bytes
            }
            let bytes = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
            try check()
            let (_, response) = try await request(uploadURL: sessionURL, method: "PUT", body: bytes,
                contentType: Self.mimeType(artifact.kind), headers: ["Content-Range": "bytes \(offset)-\(offset + Int64(count) - 1)/\(artifact.byteCount)"],
                accepted: [200, 201, 308, 404, 410])
            if response.statusCode == 404 || response.statusCode == 410 {
                try check(); try saveSession(nil); throw GoogleDriveError.expiredSession
            }
            if response.statusCode == 200 || response.statusCode == 201 {
                offset = artifact.byteCount
            } else {
                let next = try Self.nextOffset(response, total: artifact.byteCount)
                guard next > offset, next <= offset + Int64(count) else { throw GoogleDriveError.invalidResumableOffset }
                offset = next
            }
        }
        try check()
        guard let remote = try await metadata(fileID) else { throw GoogleDriveError.invalidResponse }
        return remote
    }
    static func nextOffset(_ response: HTTPURLResponse, total: Int64) throws -> Int64 {
        guard let range = response.value(forHTTPHeaderField: "Range") else { return 0 }
        guard range.hasPrefix("bytes=0-"), let last = Int64(range.dropFirst(8)), last >= 0, last < total else { throw GoogleDriveError.invalidResumableOffset }
        return last + 1
    }
    static func mimeType(_ kind: GoogleDriveArtifact.Kind) -> String {
        switch kind { case .audio: return "audio/x-caf"; case .manifest, .transcriptJSON: return "application/json"; case .transcriptText: return "text/plain" }
    }
    static func fileName(_ artifact: GoogleDriveArtifact, manifest: SegmentManifest) -> String {
        let prefix: String
        if let group = manifest.recordingGroup, let audioName = manifest.groupedAudioFileName {
            prefix = group.cloudName + "__" + audioName.dropLast(".caf".count)
        } else {
            prefix = manifest.id.uuidString.lowercased()
        }
        switch artifact.kind {
        case .audio: return prefix + ".caf"
        case .manifest: return prefix + ".manifest.json"
        case .transcriptJSON: return prefix + ".transcript-" + artifact.sha256.prefix(16) + ".json"
        case .transcriptText: return prefix + ".transcript-" + artifact.sha256.prefix(16) + ".txt"
        }
    }
    private func request(path: String? = nil, query: [String: String] = [:], uploadURL: String? = nil,
                         method: String = "GET", body: Data? = nil, contentType: String = "application/json",
                         headers: [String: String] = [:], accepted: Set<Int> = [200]) async throws -> (Data, HTTPURLResponse) {
        do {
            try check()
            let previousPhase = currentPhase
            phase(.tokenAccess)
            let token = try await oauth.accessToken(for: accountID, timeout: requestTimeout?())
            try check()
            // A refreshed access token is verified before it can receive file bytes.
            if token != validatedToken {
                phase(.accountGet)
                let account = try await Self.account(http: http, token: token, timeout: requestTimeout?(), recoveryBudget: currentRecoveryBudget)
                try check()
                guard account.id == accountID else { throw GoogleDriveLibraryError.changedAccount }
                validatedToken = token
            }
            phase(previousPhase)
            var url: URL
            if let uploadURL, GoogleDriveLibraryLedger.validUploadURL(uploadURL), let parsed = URL(string: uploadURL) { url = parsed }
            else if let path {
                var parts = URLComponents(string: "https://www.googleapis.com" + path)!
                parts.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }; url = parts.url!
            } else { throw GoogleDriveError.invalidResponse }
            var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            if method == "PUT" || method == "POST" { request.setValue(String(body?.count ?? 0), forHTTPHeaderField: "Content-Length") }
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            try check()
            let acceptsMissing = method == "GET" && accepted.contains(404) && path?.hasPrefix("/drive/v3/files/") == true
            let result = try await http.send(request, timeout: requestTimeout?(), recoveryBudget: currentRecoveryBudget,
                acceptsMissingMetadata: acceptsMissing)
            try check()
            if result.1.statusCode == 401 { throw GoogleDriveError.needsSignIn }
            guard accepted.contains(result.1.statusCode) else { throw GoogleDriveError.response(status: result.1.statusCode, data: result.0) }
            return result
        } catch {
            // A failed await must still honor a parent/deadline cancellation.
            try check()
            throw error
        }
    }

    private var currentRecoveryBudget: GoogleDriveHTTP.RecoveryBudget {
        { [self] in
            try check()
            return try requestTimeout?() ?? 30
        }
    }
}
