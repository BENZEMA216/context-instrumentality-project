import AuthenticationServices
import CloudKit
import Combine
import CryptoKit
import Foundation
import RecordingCore

/// Dependency seam for synthetic tests. Production supplies the CloudKit ledger
/// and already-loaded transcripts; this layer has no audio repository or CAF API.
@MainActor
struct AgentLibraryAccess {
    let snapshot: () async throws -> CloudLibrarySnapshot?
    let boundScope: () async throws -> CloudLibraryScope?
    let savedReceipts: () async throws -> [CloudLibraryReceipt]
    let verifiedCurrentScope: () async throws -> CloudLibraryScope
    let transcripts: () -> [UUID: SegmentTranscript]
}

struct AgentRecordingChoice: Identifiable {
    let manifest: SegmentManifest
    var id: UUID { manifest.id }
}

@MainActor
final class AgentConnectionStore: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var appleSignInInProgress = false
    @Published private(set) var hasSavedSignIn = false
    @Published private(set) var serverSessionConfirmed = false
    @Published private(set) var challenge: AgentChallenge?
    @Published private(set) var pendingAuthorization: AgentAuthorizationRequest?
    @Published private(set) var authorizationRecordings: [AgentRecordingChoice] = []
    @Published private(set) var selectedRecordingIDs: Set<UUID> = []
    @Published private(set) var connections: [AgentConnection] = []
    @Published private(set) var lastConnectionRefresh: Date?
    @Published private(set) var eligibleCount = 0
    @Published private(set) var cachedCount = 0
    @Published private(set) var unavailableTranscriptCount = 0
    @Published private(set) var activity = ""
    @Published private(set) var error: String?
    @Published var authorizationCode = ""

    let baseURL: URL?
    let unavailableReason: String?
    private let client: any AgentGatewayServing
    private let access: AgentLibraryAccess
    private let vault: any AgentSessionVault
    private var deviceSession: AgentDeviceSession?
    private var preparedScope: CloudLibraryScope?
    private var requestChallenge: AgentChallenge?
    private var eligible: [UUID: Eligible] = [:]
    private var cached: [UUID: CacheReceipt] = [:]
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var accountObservation: NSObjectProtocol?

    private struct Eligible {
        let manifest: SegmentManifest
        let transcript: SegmentTranscript
        let receipt: CloudLibraryReceipt
        let transcriptSHA256: String
    }
    private struct CacheReceipt {
        let transcriptSHA256: String
        let revision: Int
    }

    convenience init(cloud: PrivateCloudLibrary,
                     transcriptProvider: @escaping @MainActor () -> [UUID: SegmentTranscript],
                     bundle: Bundle = .main) {
        self.init(access: AgentLibraryAccess(snapshot: { try await cloud.initialSnapshot() },
            boundScope: { try await cloud.boundScope() }, savedReceipts: { try await cloud.savedReceipts() },
            verifiedCurrentScope: { try await cloud.verifiedCurrentScope() }, transcripts: transcriptProvider),
            client: AgentGatewayClient(configuration: AgentGatewayConfiguration(bundle: bundle)))
    }

    init(access: AgentLibraryAccess, client: any AgentGatewayServing, vault: (any AgentSessionVault)? = nil) {
        self.access = access
        self.client = client
        self.vault = vault ?? AgentKeychainSessionVault()
        baseURL = client.baseURL
        unavailableReason = client.unavailableReason
        accountObservation = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.accountDidChange() }
        }
    }

    deinit {
        if let accountObservation { NotificationCenter.default.removeObserver(accountObservation) }
        operation?.cancel()
    }

    var isWorking: Bool { isBusy || appleSignInInProgress }
    var isConfigured: Bool { unavailableReason == nil && baseURL != nil }
    var mcpURL: URL? { baseURL?.appendingPathComponent("mcp") }
    var activeConnectionCount: Int { connections.filter(\.isActive).count }
    var canApprove: Bool {
        guard let request = pendingAuthorization else { return false }
        return !isWorking && request.expiresAt > Date() && !selectedRecordingIDs.isEmpty
    }
    var statusTitle: String {
        if !isConfigured { return "服务未就绪" }
        if !hasSavedSignIn { return "尚未登录" }
        if !serverSessionConfirmed { return "登录待核对" }
        if isBusy { return "正在处理" }
        if activeConnectionCount > 0 { return "已有 Agent 授权" }
        if cachedCount > 0 { return "转写已缓存" }
        return "已登录，待同步转写"
    }
    var statusMessage: String {
        if let unavailableReason { return unavailableReason }
        if !hasSavedSignIn { return "先使用 Apple 登录，再同步已保存到 iCloud 的首批转写。" }
        if !serverSessionConfirmed { return "本机保存了登录凭据。刷新连接后可核对服务端状态。" }
        if activeConnectionCount > 0 { return "最近确认有 \(activeConnectionCount) 项有效授权。Agent 是否完成连接，请回到对应应用查看。" }
        if cachedCount > 0 { return "本次已确认缓存 \(cachedCount) 段转写。输入 Agent 网页上的授权码后，由你批准读取。" }
        return "登录已确认。先同步转写，再选择接收方和录音范围。"
    }

    /// Local metadata only. Restoring a Keychain record is not a server login check.
    func refreshLocalState() async {
        guard !isWorking else { return }
        do {
            if isConfigured {
                let stored = try deviceSession ?? vault.load()
                if let stored {
                    guard stored.endpoint == baseURL?.absoluteString, stored.expiresAt > Date(),
                          Self.validToken(stored.deviceToken) else {
                        try clearLocalSession()
                        throw AgentGatewayError.unauthorized
                    }
                    guard let bound = try await access.boundScope(), bound.ownerHash == stored.cloudKitAccountFingerprint else {
                        try clearLocalSession()
                        throw AgentGatewayError.accountChanged
                    }
                    deviceSession = stored
                    hasSavedSignIn = true
                }
            }
            try await reloadEligible()
        } catch { show(error) }
    }

    func prepareAppleLogin() {
        run("正在核对 iCloud 账户并准备 Apple 登录。") {
            let scope = try await self.verifiedScope()
            let result = try await self.client.challenge()
            try Task.checkCancellation()
            guard result.expiresAt > Date(), result.expiresAt.timeIntervalSinceNow <= 6 * 60,
                  !result.nonce.isEmpty, result.nonce.utf8.count <= 512 else { throw AgentGatewayError.invalidResponse }
            self.preparedScope = scope
            self.challenge = result
            self.activity = "已准备好。点击下方“通过 Apple 登录”继续。"
        }
    }

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard !isWorking, let challenge, challenge.expiresAt > Date(), preparedScope != nil else {
            error = AgentGatewayError.challengeExpired.localizedDescription
            return
        }
        request.requestedScopes = []
        request.nonce = challenge.nonce
        request.state = challenge.challengeID.uuidString.lowercased()
        requestChallenge = challenge
        appleSignInInProgress = true
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        appleSignInInProgress = false
        let usedChallenge = requestChallenge
        let usedScope = preparedScope
        requestChallenge = nil
        challenge = nil
        preparedScope = nil
        switch result {
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code == .canceled { activity = "已取消 Apple 登录。" }
            else { error = "Apple 登录未完成，请重新准备后再试。" }
        case .success(let authorization):
            guard let usedChallenge, usedChallenge.expiresAt > Date(), let usedScope,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  credential.state == usedChallenge.challengeID.uuidString.lowercased(),
                  let identityData = credential.identityToken, identityData.count <= 16_384,
                  let identityToken = String(data: identityData, encoding: .utf8), !identityToken.isEmpty else {
                error = AgentGatewayError.challengeExpired.localizedDescription
                return
            }
            run("正在完成 Apple 登录。") {
                let current = try await self.verifiedScope()
                guard current == usedScope else { throw AgentGatewayError.accountChanged }
                let response = try await self.client.login(challengeID: usedChallenge.challengeID,
                    identityToken: identityToken, fingerprint: current.ownerHash)
                try Task.checkCancellation()
                let verifiedAgain = try await self.verifiedScope()
                guard verifiedAgain == current,
                      response.cloudKitAccountFingerprint == current.ownerHash,
                      Self.validToken(response.deviceToken), response.expiresAt > Date(),
                      response.expiresAt.timeIntervalSinceNow <= 30 * 24 * 60 * 60 + 60,
                      let endpoint = self.baseURL?.absoluteString else { throw AgentGatewayError.invalidResponse }
                let session = AgentDeviceSession(ownerID: response.ownerID, deviceToken: response.deviceToken,
                    expiresAt: response.expiresAt, endpoint: endpoint, cloudKitAccountFingerprint: current.ownerHash)
                try self.vault.save(session)
                self.deviceSession = session
                self.hasSavedSignIn = true
                self.serverSessionConfirmed = true
                self.cached = [:]
                self.cachedCount = 0
                self.connections = []
                self.lastConnectionRefresh = nil
                self.activity = "Apple 登录已完成。现在可以同步首批转写。"
            }
        }
    }

    func cacheTranscripts() {
        run("正在准备可同步的首批转写。") {
            _ = try await self.verifiedSession()
            try await self.reloadEligible()
            let values = self.eligible.values.sorted { $0.manifest.startedAt < $1.manifest.startedAt }
            guard !values.isEmpty else { throw AgentGatewayError.noEligibleRecordings }
            self.dismissAuthorization()
            for (index, value) in values.enumerated() {
                try Task.checkCancellation()
                let (session, scope) = try await self.verifiedSession()
                let revision = try await self.client.revision(recordingID: value.manifest.id, token: session.deviceToken)
                try Task.checkCancellation()
                if let revision {
                    guard revision.recordingID == value.manifest.id, revision.revision > 0 else {
                        throw AgentGatewayError.invalidResponse
                    }
                    if revision.deleted {
                        self.cached.removeValue(forKey: value.manifest.id)
                        self.cachedCount = self.cached.count
                        throw AgentGatewayError.cacheDeleted
                    }
                }
                let (currentSession, currentScope) = try await self.verifiedSession()
                guard currentScope == scope, currentSession.ownerID == session.ownerID else {
                    throw AgentGatewayError.accountChanged
                }
                // Recompute after the account check so edits cannot silently change
                // the payload selected at the start of this explicit sync operation.
                try await self.reloadEligible()
                guard self.eligible[value.manifest.id]?.transcriptSHA256 == value.transcriptSHA256 else {
                    throw AgentGatewayError.invalidRequest
                }
                self.activity = "正在同步第 \(index + 1) / \(values.count) 段转写。"
                let request = AgentUploadRequest(manifest: value.manifest, transcript: value.transcript,
                    clientReportedCloudKit: .init(accountFingerprint: scope.ownerHash,
                        containerIdentifier: scope.containerIdentifier, environment: scope.environment.lowercased(),
                        recordName: value.receipt.cloudRecordName, savedAt: value.receipt.metadataVerifiedAt),
                    expectedRevision: revision?.revision ?? 0)
                let response = try await self.client.upload(request, token: currentSession.deviceToken)
                try Task.checkCancellation()
                guard response.recordingID == value.manifest.id, response.revision > 0,
                      ["stored", "unchanged"].contains(response.status), response.transcriptStatus == "ready",
                      response.cloudMetadataVerification == "client_reported" else { throw AgentGatewayError.invalidResponse }
                self.cached[value.manifest.id] = CacheReceipt(transcriptSHA256: value.transcriptSHA256, revision: response.revision)
                self.cachedCount = self.cached.count
                self.serverSessionConfirmed = true
            }
            self.activity = "服务已确认缓存 \(self.cachedCount) 段转写。原音频未发送到 Agent 服务。"
        }
    }

    func lookupAuthorization() {
        let code = authorizationCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        run("正在查找待授权的 Agent。") {
            self.dismissAuthorization()
            guard code.count == 10, code.allSatisfy({ "23456789ABCDEFGHJKLMNPQRSTUVWXYZ".contains($0) }) else {
                throw AgentGatewayError.invalidRequest
            }
            let (session, _) = try await self.verifiedSession()
            try await self.reloadEligible()
            guard !self.cached.isEmpty, self.cached.count <= 500 else { throw AgentGatewayError.noCachedRecordings }
            let request = try await self.client.lookup(code: code, token: session.deviceToken)
            try Task.checkCancellation()
            guard request.expiresAt > Date(), request.expiresAt.timeIntervalSinceNow <= 11 * 60,
                  !request.clientID.isEmpty, !request.clientName.isEmpty, !request.redirectHost.isEmpty,
                  !request.requestedScopes.isEmpty, Set(request.requestedScopes).count == request.requestedScopes.count else {
                throw AgentGatewayError.invalidResponse
            }
            self.pendingAuthorization = request
            self.authorizationRecordings = self.cached.keys.compactMap { self.eligible[$0]?.manifest }
                .sorted { $0.startedAt < $1.startedAt }.map(AgentRecordingChoice.init)
            self.selectedRecordingIDs = Set(self.authorizationRecordings.map(\.id))
            self.serverSessionConfirmed = true
            self.activity = "请核对接收方、读取内容和 \(self.selectedRecordingIDs.count) 段录音，再决定是否批准。"
        }
    }

    func setSelected(_ id: UUID, selected: Bool) {
        guard !isWorking, authorizationRecordings.contains(where: { $0.id == id }) else { return }
        if selected { selectedRecordingIDs.insert(id) } else { selectedRecordingIDs.remove(id) }
    }

    func approveAuthorization() {
        guard let pending = pendingAuthorization else { return }
        let selected = selectedRecordingIDs
        run("正在提交你选择的录音授权。") {
            guard pending.expiresAt > Date() else { throw AgentGatewayError.authorizationExpired }
            let (session, _) = try await self.verifiedSession()
            try await self.reloadEligible()
            guard self.pendingAuthorization?.authorizationID == pending.authorizationID,
                  !selected.isEmpty, selected.count <= 500, selected.isSubset(of: Set(self.cached.keys)),
                  selected.isSubset(of: Set(self.authorizationRecordings.map(\.id))) else {
                self.dismissAuthorization()
                throw AgentGatewayError.noCachedRecordings
            }
            let response = try await self.client.approve(authorizationID: pending.authorizationID,
                recordingIDs: selected.sorted { $0.uuidString < $1.uuidString }, scopes: pending.requestedScopes,
                token: session.deviceToken)
            try Task.checkCancellation()
            guard response.isActive, response.clientID == pending.clientID,
                  Set(response.recordingIDs) == selected, Set(response.scopes) == Set(pending.requestedScopes) else {
                throw AgentGatewayError.invalidResponse
            }
            self.connections.removeAll { $0.id == response.id }
            self.connections.insert(response, at: 0)
            self.serverSessionConfirmed = true
            self.dismissAuthorization()
            self.authorizationCode = ""
            self.activity = "已批准 \(selected.count) 段。请回到 Agent 完成连接；之后新增录音不会自动加入。"
        }
    }

    func refreshConnections() {
        run("正在核对 Agent 授权。") {
            let (session, _) = try await self.verifiedSession()
            let values = try await self.client.connections(token: session.deviceToken)
            try Task.checkCancellation()
            guard values.count <= 200, Set(values.map(\.id)).count == values.count,
                  values.allSatisfy({ ["active", "revoked"].contains($0.status) }) else { throw AgentGatewayError.invalidResponse }
            self.connections = values
            self.serverSessionConfirmed = true
            self.lastConnectionRefresh = Date()
            self.activity = "授权状态已刷新。当前有效授权 \(self.activeConnectionCount) 项。"
        }
    }

    func revoke(_ connection: AgentConnection) {
        run("正在撤销这项 Agent 授权。") {
            let (session, _) = try await self.verifiedSession()
            let result = try await self.client.revoke(connectionID: connection.id, token: session.deviceToken)
            try Task.checkCancellation()
            guard result.id == connection.id, result.status == "revoked" else { throw AgentGatewayError.invalidResponse }
            self.connections.removeAll { $0.id == result.id }
            self.connections.insert(result, at: 0)
            self.serverSessionConfirmed = true
            self.activity = "已撤销这项授权。Agent 后续读取将被拒绝；已经读取的内容无法远程收回。"
        }
    }

    func signOut() {
        run("正在退出本机登录。") {
            let existing = self.deviceSession
            try self.clearLocalSession()
            guard let existing, existing.endpoint == self.baseURL?.absoluteString else {
                self.activity = "本机已退出。已授予 Agent 的独立授权仍保留。"
                return
            }
            do {
                try await self.client.logout(token: existing.deviceToken)
                self.activity = "本机登录已退出。已授予 Agent 的独立授权仍保留。"
            } catch AgentGatewayError.unauthorized {
                self.activity = "本机已退出，原登录已失效。Agent 的独立授权仍保留。"
            } catch {
                self.activity = "本机凭据已清除，但未能确认服务端退出。Agent 的独立授权仍保留。"
                self.error = "重新登录后可管理和撤销 Agent 授权。"
            }
        }
    }

    func dismissAuthorization() {
        pendingAuthorization = nil
        authorizationRecordings = []
        selectedRecordingIDs = []
    }

    func cancel() {
        operation?.cancel()
        operationID = nil
        operation = nil
        isBusy = false
        challenge = nil
        preparedScope = nil
        requestChallenge = nil
        appleSignInInProgress = false
        dismissAuthorization()
        activity = "已停止本机操作。已发出的请求可能已被服务接受，请刷新确认。"
    }

    private func verifiedScope() async throws -> CloudLibraryScope {
        guard let bound = try await access.boundScope() else { throw AgentGatewayError.scopeUnavailable }
        let current = try await access.verifiedCurrentScope()
        try Task.checkCancellation()
        guard current == bound else { throw AgentGatewayError.accountChanged }
        return bound
    }

    private func verifiedSession() async throws -> (AgentDeviceSession, CloudLibraryScope) {
        guard let session = deviceSession, session.expiresAt > Date(),
              session.endpoint == baseURL?.absoluteString else {
            try clearLocalSession()
            throw AgentGatewayError.unauthorized
        }
        let scope = try await verifiedScope()
        guard scope.ownerHash == session.cloudKitAccountFingerprint else {
            try clearLocalSession()
            throw AgentGatewayError.accountChanged
        }
        return (session, scope)
    }

    private func reloadEligible() async throws {
        guard let snapshot = try await access.snapshot() else {
            eligible = [:]; cached = [:]; eligibleCount = 0; cachedCount = 0
            return
        }
        let receipts = try await access.savedReceipts()
        let transcripts = access.transcripts()
        var values: [UUID: Eligible] = [:]
        var invalid = 0
        for manifest in snapshot.manifests {
            guard let receipt = receipts.first(where: { $0.segmentID == manifest.id }),
                  receipt.audioSHA256 == manifest.sha256, receipt.byteCount == manifest.byteCount,
                  receipt.cloudRecordName == CloudLibraryLedger.audioRecordName(for: manifest.id),
                  let transcript = transcripts[manifest.id] else { continue }
            do {
                try transcript.validate(against: manifest)
                let data = try TransportCodec.encode(transcript)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                values[manifest.id] = Eligible(manifest: manifest, transcript: transcript,
                    receipt: receipt, transcriptSHA256: hash)
            } catch { invalid += 1 }
        }
        try Task.checkCancellation()
        eligible = values
        cached = cached.filter { values[$0.key]?.transcriptSHA256 == $0.value.transcriptSHA256 }
        eligibleCount = values.count
        cachedCount = cached.count
        unavailableTranscriptCount = invalid
    }

    private func run(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        guard isConfigured else { error = unavailableReason ?? AgentGatewayError.unavailable.localizedDescription; return }
        let id = UUID()
        operationID = id
        isBusy = true
        error = nil
        activity = message
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == id { self.operation = nil; self.operationID = nil; self.isBusy = false }
            }
            do { try await action() }
            catch {
                guard self.operationID == id else { return }
                self.show(error)
            }
        }
    }

    private func show(_ failure: Error) {
        if failure is CancellationError { error = AgentGatewayError.cancelled.localizedDescription; return }
        if let failure = failure as? AgentGatewayError {
            if failure == .unauthorized || failure == .accountChanged {
                do { try clearLocalSession() } catch { self.error = AgentGatewayError.keychain.localizedDescription; return }
            }
            error = failure.localizedDescription
        } else if let failure = failure as? CloudLibraryLedgerError {
            if failure == .accountChanged || failure == .scopeChanged { try? clearLocalSession() }
            error = failure.localizedDescription
        } else {
            error = "暂时无法核对 iCloud 账户或录音记录，请回到个人录音库检查后重试。"
        }
    }

    private func clearLocalSession() throws {
        // Clear memory even if the Keychain is temporarily locked. No old token is
        // reused in this running controller after an account, origin or auth failure.
        deviceSession = nil
        hasSavedSignIn = false
        serverSessionConfirmed = false
        challenge = nil
        requestChallenge = nil
        preparedScope = nil
        cached = [:]
        cachedCount = 0
        connections = []
        lastConnectionRefresh = nil
        dismissAuthorization()
        try vault.clear()
    }

    private func accountDidChange() {
        cancel()
        do { try clearLocalSession() }
        catch { self.error = AgentGatewayError.keychain.localizedDescription }
        activity = "iCloud 账户状态已变化，已停止操作并清除本机登录。原授权不会自动转给其他账户。"
    }

    private static func validToken(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
