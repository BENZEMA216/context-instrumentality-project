import Foundation

// Presentation-only fixtures. They cannot reach storage, credentials or a provider.
struct Color: Equatable { let name: String }
enum RecordDesign {
    static let warning = Color(name: "warning")
    static let secondary = Color(name: "secondary")
    static let good = Color(name: "good")
}

@MainActor
final class GoogleDriveLibrary {
    var apiFailureReason: GoogleDriveAPIReason?

    var isRevocationPending = false
    var isConfigured = true
    var error: String?
    var isNetworkFailure = false
    var needsCredential = false
    var nextPlannedAttemptAt: Date?
    var isConnected = true
    var hasAuthorizationHistory = true
    var scope: String? = "existingAndFuture"
    var isEnabled = true
    var isBusy = false
    var hasPendingWork = false
    var isWaitingForWiFi = false
    var isWaitingForNewRecordings = false
    var isCurrentScopeSaved = false
    var activity = "合成最近结果"
}

struct DiagnosticSnapshot {
    enum Availability { case cached, unavailable, stale, invalidTimestamp, notObserved }
    enum Status { case observed, needsIdentityRevalidation }
    var availability = Availability.cached
    var status = Status.observed
}

@MainActor
final class ICloudDriveLibrary {
    var error: String?
    var hasBlockingError = false
    var isConnected = true
    var hasAuthorizationHistory = true
    var scope: String? = "existingAndFuture"
    var isEnabled = true
    var isBusy = false
    var busyMessage = "正在核对上传状态…"
    var isWaitingForNewRecordings = false
    var isCurrentScopeUploaded = false
    var isCurrentScopeWritten = false
    var pendingCloudFileCount = 0
    var hasPendingWork = false
    var activity = "合成最近结果"
    var snapshot = DiagnosticSnapshot()
    private(set) var snapshotReads = 0
    func diagnosticSnapshot() -> DiagnosticSnapshot { snapshotReads += 1; return snapshot }
}

// INSERT PRODUCTION PRESENTATION HERE

@main
struct PresentationProbe {
    @MainActor
    static func main() {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("Presentation assertion failed: " + name) }
            assertions += 1
        }
        do {
            let value = GoogleDriveLibrary()
            value.isRevocationPending = true; value.isEnabled = false; value.isBusy = true
            value.error = "这条旧错误不能掩盖撤销待确认"
            let status = GoogleDriveDetailStatus(drive: value)
            expect(status.title == "本机已停止 · 撤销待确认", "revocation priority")
            expect(status.summary == status.title, "Google row and detail same state")
            expect(status.authorizationSummary == "Google 撤销尚未确认", "remote revocation remains unknown")
            expect(status.synchronizationSummary == "本机已停止", "local stop distinct from remote revoke")
            expect(status.latestResult.contains("尚未确认"), "pending revoke result")
            expect(status.latestResult.contains(value.error!), "real revocation error retained")
            expect(!status.authorizationSummary.contains("已连接"), "no connected claim during pending revocation")
            expect(status.connectionDisabledReason != nil, "busy account action has reason")
        }
        do {
            let value = GoogleDriveLibrary()
            value.error = "原始未知错误"; value.isEnabled = false
            let status = GoogleDriveDetailStatus(drive: value)
            expect(status.title == "需处理", "Google current error visible")
            expect(status.authorizationSummary == "账户连接需要处理", "retained credential is not healthy auth")
            expect(status.latestResult == value.error, "unknown Google error preserved")
            expect(status.synchronizationSummary == "已关闭", "actual toggle state visible")
            expect(status.toggleDisabledReason == nil, "explicit retry remains possible through normal action")
        }
        do {
            let value = GoogleDriveLibrary(); value.isConfigured = false
            let status = GoogleDriveDetailStatus(drive: value)
            expect(status.title == "暂不可用", "unconfigured Google")
            expect(status.connectionDisabledReason?.contains("未配置") == true, "unconfigured action reason")
        }
        do {
            let value = GoogleDriveLibrary(); value.isConnected = false; value.isEnabled = false
            let status = GoogleDriveDetailStatus(drive: value)
            expect(status.title == "需重新连接", "original account retained")
            expect(status.toggleDisabledReason != nil, "disconnected toggle has reason")
            value.hasAuthorizationHistory = false; value.scope = nil
            expect(GoogleDriveDetailStatus(drive: value).title == "未连接", "first connection distinguished")
        }
        do {
            let value = GoogleDriveLibrary(); value.scope = nil; value.isEnabled = false
            expect(GoogleDriveDetailStatus(drive: value).title == "待选择范围", "account connection is not a recording grant")
            value.scope = "existingAndFuture"
            expect(GoogleDriveDetailStatus(drive: value).title == "已暂停同步", "connected but paused")
            value.isBusy = true
            expect(GoogleDriveDetailStatus(drive: value).toggleDisabledReason != nil, "busy cannot enable reason")
            value.isEnabled = true
            expect(GoogleDriveDetailStatus(drive: value).toggleDisabledReason == nil, "pause remains allowed while active")
        }
        do {
            let value = GoogleDriveLibrary(); value.hasPendingWork = true
            expect(GoogleDriveDetailStatus(drive: value).title == "同步未完成", "pending Google files")
            value.hasPendingWork = false; value.isWaitingForNewRecordings = true
            expect(GoogleDriveDetailStatus(drive: value).title == "等待新录音", "waiting Google recordings")
            value.isWaitingForNewRecordings = false; value.isCurrentScopeSaved = true
            let status = GoogleDriveDetailStatus(drive: value)
            expect(status.summary == "已保存", "Google completion not replaced with connected")
            expect(status.latestResult == value.activity, "real latest activity retained")
        }
        do {
            let value = GoogleDriveLibrary(); value.hasPendingWork = true; value.isWaitingForWiFi = true
            let waiting = GoogleDriveDetailStatus(drive: value)
            expect(waiting.title == "等待 Wi-Fi", "cellular policy wait is visible before generic pending state")
            expect(waiting.authorizationSummary == GoogleDriveDetailStatus(drive: GoogleDriveLibrary()).authorizationSummary,
                   "network wait does not revoke account")
            value.isEnabled = false
            expect(GoogleDriveDetailStatus(drive: value).title == "已暂停同步", "pause wins over stale Wi-Fi wait")
            value.isEnabled = true; value.error = "合成持久化失败"
            expect(GoogleDriveDetailStatus(drive: value).title == "需处理", "failure is not hidden by Wi-Fi wait")
        }
        do {
            let value = GoogleDriveLibrary()
            value.error = "untrusted raw network error"; value.isNetworkFailure = true
            value.nextPlannedAttemptAt = Date(timeIntervalSince1970: 1_800_000_000)
            let status = GoogleDriveDetailStatus(drive: value)
            expect(status.title == "Google 连接失败", "network failure distinct from credential")
            expect(status.authorizationSummary == "Google 凭据已保留", "network failure does not request reauthorization")
            expect(!status.latestResult.contains(value.error!), "network presentation uses fixed text")
            expect(status.note?.contains("等待重试") == true, "network backoff visible")
            value.isNetworkFailure = false
            expect(GoogleDriveDetailStatus(drive: value).title == "等待重试", "server backoff distinct from credentials")
            expect(GoogleDriveDetailStatus(drive: value).retryEstimate == value.nextPlannedAttemptAt, "automatic retry shows an estimate")
            expect(GoogleDriveDetailStatus(drive: value).latestResult.contains("将自动重试"), "server error retains the retry action")
            value.error = nil
            expect(GoogleDriveDetailStatus(drive: value).latestResult == "将自动重试，无需操作。",
                   "ordinary retry gives an action-free result instead of stale progress text")
            value.apiFailureReason = .storageQuotaExceeded
            value.error = GoogleDriveAPIReason.storageQuotaExceeded.explanation
            expect(GoogleDriveDetailStatus(drive: value).title == "云盘空间不足", "capacity action must win over future retry")
            expect(GoogleDriveDetailStatus(drive: value).retryEstimate == nil, "capacity blocker hides the old estimate")
            expect(GoogleDriveDetailStatus(drive: value).latestResult.contains("释放空间"), "capacity explains recovery")
            value.apiFailureReason = .userRateLimitExceeded
            expect(GoogleDriveDetailStatus(drive: value).title == "等待重试", "rate limit retains automatic retry")
            expect(GoogleDriveDetailStatus(drive: value).latestResult.contains("限制了请求频率"),
                   "known rate-limit reason replaces stale capacity guidance")
            value.apiFailureReason = nil
            value.needsCredential = true; value.isNetworkFailure = true
            expect(GoogleDriveDetailStatus(drive: value).latestResult.contains("Google 凭据需要处理"), "credential result wins over stale network failure")
            expect(GoogleDriveDetailStatus(drive: value).title == "需重新连接", "credential action wins over old deadline")
            value.isRevocationPending = true
            expect(GoogleDriveDetailStatus(drive: value).title == "本机已停止 · 撤销待确认", "revocation wins over old retry")
        }
        do {
            let value = ICloudDriveLibrary()
            value.error = "所选文件夹无法确认为原同步目录，已暂停写入。"
            value.hasBlockingError = true
            value.isEnabled = false
            let status = ICloudDriveDetailStatus(library: value)
            expect(status.title == "需处理", "iCloud directory error visible even if bookmark exists")
            expect(status.authorizationSummary == "文件夹连接需要处理", "no hardcoded connected header on directory error")
            expect(status.latestResult == value.error, "iCloud exact error retained")
            expect(status.synchronizationSummary == "已关闭", "iCloud actual enable state")
            expect(value.snapshotReads == 1, "status uses one in-memory diagnostic snapshot")
        }
        do {
            let value = ICloudDriveLibrary(); value.error = "某条源录音暂不可用，其他项目继续。"
            let status = ICloudDriveDetailStatus(library: value)
            expect(status.title == "需处理", "source warning remains visible")
            expect(status.authorizationSummary == "已授权访问所选文件夹", "source warning does not invalidate folder authorization")
            expect(status.synchronizationSummary == "已开启", "source warning does not silently pause other files")
            expect(status.latestResult == value.error, "source warning text is retained")
        }
        do {
            let value = ICloudDriveLibrary(); value.isConnected = false; value.isEnabled = false
            let status = ICloudDriveDetailStatus(library: value)
            expect(status.title == "需重选原目录", "iCloud same directory grant retained")
            expect(status.toggleDisabledReason != nil, "iCloud unavailable grant cannot enable")
            value.hasAuthorizationHistory = false; value.scope = nil
            expect(ICloudDriveDetailStatus(library: value).title == "未连接", "iCloud first selection")
        }
        do {
            let value = ICloudDriveLibrary(); value.scope = nil; value.isEnabled = false
            expect(ICloudDriveDetailStatus(library: value).title == "待选择范围", "directory access is not recording grant")
            value.scope = "existingAndFuture"
            expect(ICloudDriveDetailStatus(library: value).title == "已暂停写入", "iCloud connected paused")
            value.isBusy = true
            expect(ICloudDriveDetailStatus(library: value).toggleDisabledReason != nil, "busy paused reason")
            value.isEnabled = true
            expect(ICloudDriveDetailStatus(library: value).toggleDisabledReason == nil, "active pause permitted")
        }
        do {
            let value = ICloudDriveLibrary(); value.snapshot.availability = .unavailable
            expect(ICloudDriveDetailStatus(library: value).title == "状态暂不可用", "failed observation not success")
            for availability in [DiagnosticSnapshot.Availability.stale, .invalidTimestamp, .notObserved] {
                value.snapshot.availability = availability
                expect(ICloudDriveDetailStatus(library: value).title == "状态待核对", "unfresh observations remain unknown")
            }
            value.snapshot.availability = .cached; value.snapshot.status = .needsIdentityRevalidation
            expect(ICloudDriveDetailStatus(library: value).title == "需核对文件身份", "identity difference not hidden")
        }
        do {
            let value = ICloudDriveLibrary(); value.isCurrentScopeUploaded = true
            expect(ICloudDriveDetailStatus(library: value).summary == "系统已确认上传", "iCloud upload result not flattened to connection")
            value.isCurrentScopeUploaded = false; value.isCurrentScopeWritten = true; value.pendingCloudFileCount = 1
            expect(ICloudDriveDetailStatus(library: value).title == "上传待确认", "local write is not provider confirmation")
            value.pendingCloudFileCount = 0
            expect(ICloudDriveDetailStatus(library: value).summary == "已写入目录", "written result retained")
            value.isCurrentScopeWritten = false; value.hasPendingWork = true
            expect(ICloudDriveDetailStatus(library: value).title == "保存未完成", "pending iCloud write")
        }
        print("{\"assertions\":\(assertions),\"status\":\"passed\",\"networkAccess\":false,\"deviceAccess\":false}")
    }
}
