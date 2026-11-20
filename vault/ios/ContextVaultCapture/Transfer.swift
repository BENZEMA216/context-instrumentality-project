import CryptoKit
import Foundation

enum IntakeError: LocalizedError {
    case invalidPairing, invalidDocument, invalidLabel, oversized, invalidType, tooManyPages

    var errorDescription: String? {
        switch self {
        case .invalidPairing: return "配对码无效。请从 Mac 上的 Context Vault 重新复制完整配对码。"
        case .invalidDocument: return "文件为空或与扩展名不符。请选择有效的 PDF、JPEG 或 PNG。"
        case .invalidLabel: return "请填写 1 至 120 个字符的资料名称。"
        case .oversized: return "文件超过 8 MiB，请减少扫描页数或选择较小的文件。"
        case .invalidType: return "请选择 PDF、JPEG 或 PNG 文件。"
        case .tooManyPages: return "每份资料最多扫描 16 页。请分成多份保存。"
        }
    }
}

struct VaultRecipient {
    let key: P256.KeyAgreement.PublicKey
    let code: String

    init(code input: String) throws {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("CV1."),
              let bytes = Data(base64Encoded: String(clean.dropFirst(4))),
              bytes.count == 65, bytes.first == 4,
              let key = try? P256.KeyAgreement.PublicKey(x963Representation: bytes)
        else { throw IntakeError.invalidPairing }
        self.key = key
        self.code = "CV1." + bytes.base64EncodedString()
    }

    var fingerprint: String {
        SHA256.hash(data: key.x963Representation).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

struct VaultDocument {
    static let maxBytes = 8 * 1024 * 1024
    let bytes: Data
    let mime: String

    init(bytes: Data, mime: String) throws {
        guard !bytes.isEmpty else { throw IntakeError.invalidDocument }
        guard bytes.count <= Self.maxBytes else { throw IntakeError.oversized }
        let prefix: [UInt8]
        switch mime {
        case "application/pdf": prefix = Array("%PDF-".utf8)
        case "image/jpeg": prefix = [0xff, 0xd8, 0xff]
        case "image/png": prefix = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        default: throw IntakeError.invalidType
        }
        guard bytes.starts(with: prefix) else { throw IntakeError.invalidDocument }
        self.bytes = bytes
        self.mime = mime
    }

    func seal(label: String, to recipient: VaultRecipient) throws -> Data {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 120,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw IntakeError.invalidLabel }
        let payload = try JSONEncoder().encode(Item(kind: "document", label: name, value: bytes, mime: mime))
        var sender = try HPKE.Sender(recipientKey: recipient.key, ciphersuite: .P256_SHA256_AES_GCM_256,
                                     info: Data("context-vault/inbox/v1".utf8))
        let ciphertext = try sender.seal(payload)
        return try JSONEncoder().encode(Envelope(v: 1, enc: sender.encapsulatedKey, ct: ciphertext))
    }
    private struct Item: Encodable { let kind, label: String; let value: Data; let mime: String }
    private struct Envelope: Encodable { let v: Int; let enc, ct: Data }
}
