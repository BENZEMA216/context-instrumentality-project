import Foundation

/// A fixed vocabulary shared by UI and diagnostics. Never persist a transport's
/// localizedDescription, URL, hostname or userInfo alongside these values.
public enum AutomaticReceiverFailureCategory: String, Codable, CaseIterable, Sendable {
    case dns, timeout, cannotConnect, offline, networkRestricted, atsBlocked
    case certificate, unauthorized, unsupportedProbe, invalidResponse, server, cancelled, unknown
    case pairingRepairRequired, localState

    public var title: String {
        switch self {
        case .dns: return "无法解析电脑地址"
        case .timeout: return "连接电脑超时"
        case .cannotConnect: return "无法连接电脑"
        case .offline: return "当前网络不可用"
        case .networkRestricted: return "网络访问受限"
        case .atsBlocked: return "系统阻止了此连接"
        case .certificate: return "电脑证书核对失败"
        case .unauthorized: return "配对授权已失效"
        case .unsupportedProbe: return "已连接 · 建议升级电脑接收程序"
        case .invalidResponse: return "接收程序响应不匹配"
        case .server: return "接收程序暂时不可用"
        case .cancelled: return "连接检查或传输已取消"
        case .unknown: return "连接电脑失败"
        case .pairingRepairRequired: return "需重新配对"
        case .localState: return "本地同步准备失败"
        }
    }

    public var hint: String {
        switch self {
        case .dns: return "确认手机和电脑在同一局域网，电脑已唤醒且接收程序正在运行；检查手机本地网络权限及路由器是否隔离设备或阻止 Bonjour。"
        case .timeout, .cannotConnect: return "唤醒电脑并启动接收程序；确认设备在同一局域网，检查电脑防火墙及手机“设置 → 隐私与安全性 → 本地网络”中的应用权限，然后重新检查连接。"
        case .offline: return "连接可访问电脑的 Wi-Fi 后重新检查连接；若 Wi-Fi 已连接，检查手机“设置 → 隐私与安全性 → 本地网络”中的应用权限。"
        case .networkRestricted: return "检查手机“设置 → 隐私与安全性 → 本地网络”中的应用权限，以及 Wi-Fi、VPN 和网络限制；此结果不能单独证明是权限被拒绝。"
        case .atsBlocked: return "检查配对信息是否来自当前接收程序，更新接收程序后重新配对；不要关闭系统网络安全检查。"
        case .certificate: return "核对电脑上的接收程序和配对信息；确认是自己的电脑后重新配对。"
        case .unauthorized: return "在电脑接收程序中获取当前配对信息，并重新配对。"
        case .unsupportedProbe: return "已连接到配对证书对应的电脑，但当前接收程序不支持状态检查。建议升级电脑接收程序；此结果不代表录音已交付。"
        case .invalidResponse: return "确认接收程序版本及配对目标正确，更新接收程序后重新检查连接。"
        case .server: return "检查电脑接收程序是否正常运行，稍后重新检查连接或重试同步。"
        case .cancelled: return "需要时重新检查连接或重试同步。"
        case .unknown: return "确认接收程序正在运行，检查同一局域网及本地网络权限后重新检查连接。"
        case .pairingRepairRequired: return "当前配对已暂停交付，重试不会解除此状态。请核对自己的电脑和接收程序，在电脑上获取当前配对信息后重新配对。"
        case .localState: return "手机未能完成同步准备或登记传输。请查看本地错误提示，检查手机可用空间及文件访问状态后重试；原录音仍保留。"
        }
    }

    /// Classify only numeric error identities. Raw system messages can contain
    /// private endpoints and are neither interpreted nor returned.
    public static func classify(error: Error?, statusCode: Int? = nil) -> Self {
        if let error {
            return networkFailure(error: error) ?? .unknown
        }
        guard let statusCode else { return .unknown }
        switch statusCode {
        case 401, 403: return .unauthorized
        case 404, 405, 501: return .unsupportedProbe
        case 408: return .timeout
        case 429, 500...599: return .server
        default: return .invalidResponse
        }
    }

    /// Local filesystem and preparation failures must retain their own recovery
    /// path. URLSession also reports local file errors in NSURLErrorDomain, so
    /// the domain alone does not establish a network failure.
    public static func networkFailure(error: Error) -> Self? {
        if error is CancellationError { return .cancelled }
        var current = error as NSError
        var containsURLError = false
        for _ in 0..<4 {
            if current.domain == NSURLErrorDomain {
                containsURLError = true
                switch current.code {
                case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dns
                case NSURLErrorTimedOut: return .timeout
                case NSURLErrorCannotConnectToHost: return .cannotConnect
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return .offline
                case NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive:
                    return .networkRestricted
                case NSURLErrorAppTransportSecurityRequiresSecureConnection: return .atsBlocked
                case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                     NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                     NSURLErrorClientCertificateRequired: return .certificate
                case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: return .unauthorized
                case NSURLErrorCancelled: return .cancelled
                case NSURLErrorFileDoesNotExist, NSURLErrorFileIsDirectory,
                     NSURLErrorNoPermissionsToReadFile, NSURLErrorCannotCreateFile,
                     NSURLErrorCannotOpenFile, NSURLErrorCannotCloseFile,
                     NSURLErrorCannotWriteToFile, NSURLErrorCannotRemoveFile,
                     NSURLErrorCannotMoveFile: return nil
                case NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorBadServerResponse,
                     NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation,
                     NSURLErrorCannotParseResponse, NSURLErrorCannotDecodeContentData,
                     NSURLErrorCannotDecodeRawData: return .invalidResponse
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return containsURLError ? .unknown : nil
    }
}

public enum AutomaticReceiverProbeResult: Equatable, Sendable {
    case reachable
    /// The pinned endpoint responded, but its receiver version has no status
    /// contract. This is neither an unreachable result nor a transfer receipt.
    case unsupportedProbe
    case failed(AutomaticReceiverFailureCategory)

    public static let maximumResponseBytes = 4 * 1_024

    public static func httpFailure(statusCode: Int) -> Self {
        let category = AutomaticReceiverFailureCategory.classify(error: nil, statusCode: statusCode)
        return category == .unsupportedProbe ? .unsupportedProbe : .failed(category)
    }

    /// HTTP success alone does not establish receiver identity or availability.
    /// This status response is never a receipt for any transferred recording.
    public static func decodeStatus(_ data: Data, receiverID: UUID) -> Self {
        struct Response: Decodable {
            let schemaVersion: Int
            let receiverID: UUID
            let status: String
        }
        guard data.count <= maximumResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "receiverID", "status"],
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.schemaVersion == 1, response.receiverID == receiverID, response.status == "ready" else {
            return .failed(.invalidResponse)
        }
        return .reachable
    }
}
